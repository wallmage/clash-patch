require "json"
require "minitest/autorun"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
PATCHER_PATH = File.join(ROOT, "clash-patch/scripts/macos/patch_profiles.rb")
POLICY_PATH = File.join(ROOT, "clash-patch/references/policy.json")
MAIN_GROUP_FIXTURES = File.join(ROOT, "tests/fixtures/main_group_cases.json")
PATCHER_AVAILABLE = File.file?(PATCHER_PATH) && File.file?(POLICY_PATH)

require PATCHER_PATH if PATCHER_AVAILABLE

class MacosPatcherTest < Minitest::Test
  def setup
    skip "patcher not implemented" unless PATCHER_AVAILABLE || name == "test_patcher_files_exist"
    @policy = JSON.parse(File.read(POLICY_PATH)) if PATCHER_AVAILABLE
  end

  def test_patcher_files_exist
    assert File.file?(PATCHER_PATH), "macOS patcher is missing"
    assert File.file?(POLICY_PATH), "canonical policy is missing"
  end

  def test_unknown_policy_version_is_rejected_without_mutating_config
    config = base_config
    snapshot = Marshal.load(Marshal.dump(config))
    policy = Marshal.load(Marshal.dump(@policy))
    policy["version"] = 2

    result = ClashPatch.patch(config, policy)

    assert_equal :invalid_policy, result.fetch(:status)
    assert_equal snapshot, config
    assert_equal snapshot, result.fetch(:config)
  end

  def test_applies_dns_tun_ai_and_webrtc_policy
    result = ClashPatch.patch(base_config, @policy)
    patched = result.fetch(:config)

    assert result.fetch(:changed)
    assert_equal "Main", result.fetch(:main_group)
    assert_equal "🤖 AI · Clash Patch", result.fetch(:ai_group)
    assert_equal "台湾家宽 01", result.fetch(:selected_home)
    assert_equal false, patched["ipv6"]
    assert_equal false, patched.dig("dns", "ipv6")
    assert_equal true, patched.dig("tun", "strict-route")
    assert_equal ["any:53", "tcp://any:53"], patched.dig("tun", "dns-hijack")
    assert patched.dig("dns", "nameserver").all? { |value| value.end_with?("##{result.fetch(:safe_group)}") }
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? { |value| value.end_with?("##{result.fetch(:safe_group)}") }

    ai_group = patched.fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01"], ai_group.fetch("proxies")
    udp = "NETWORK,UDP,#{result.fetch(:safe_group)}"
    assert_includes patched.fetch("rules"), udp
    assert_equal "NETWORK,UDP,REJECT", patched.fetch("rules")[patched.fetch("rules").index(udp) + 1]
    assert_operator patched.fetch("rules").index(udp), :<, patched.fetch("rules").index("GEOSITE,CN,DIRECT")
    assert_includes patched.fetch("rules"), "DOMAIN,raw.githubusercontent.com,AI"
    assert_includes patched.fetch("rules"), "DOMAIN,storage.googleapis.com,AI"
  end

  def test_prefers_japan_when_taiwan_home_is_absent
    config = base_config
    config["proxies"].reject! { |proxy| proxy["name"].include?("台湾") }
    config["proxy-groups"].each { |group| group["proxies"]&.delete("台湾家宽 01") }
    result = ClashPatch.patch(config, @policy)

    assert_equal "日本家宽 01", result.fetch(:selected_home)
  end

  def test_does_not_select_other_country_home_node
    config = base_config
    config["proxies"].select! { |proxy| proxy["name"] == "美国家宽 01" }
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"] = ["美国家宽 01"]
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    result = ClashPatch.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "🤖 AI · Clash Patch" }

    assert_nil result.fetch(:selected_home)
    assert_equal ["Main"], ai_group.fetch("proxies")
  end

  def test_preserves_unmanaged_narrow_rules
    original = base_config.fetch("rules").select { |rule| rule.include?("friend.example") || rule.include?("static.example.net") }
    patched = ClashPatch.patch(base_config, @policy).fetch(:config)
    after = patched.fetch("rules").select { |rule| rule.include?("friend.example") || rule.include?("static.example.net") }

    assert_equal original, after
  end

  def test_places_udp_guard_before_narrow_rule_set
    config = base_config
    config["rules"].insert(2, "RULE-SET,private-special,DIRECT")
    rules = ClashPatch.patch(config, @policy).fetch(:config).fetch("rules")

    udp_index = rules.index { |rule| rule.start_with?("NETWORK,UDP,") && rule != "NETWORK,UDP,REJECT" }
    assert_equal 0, udp_index
    assert_equal "NETWORK,UDP,REJECT", rules[udp_index + 1]
    assert_operator udp_index, :<, rules.index("GEOSITE,CN,DIRECT")
    assert_operator udp_index, :<, rules.index("RULE-SET,private-special,DIRECT")
  end

  def test_preserves_user_ai_target_ahead_of_managed_rule
    config = base_config
    config["proxy-groups"] << { "name" => "MyGroup", "type" => "select", "proxies" => ["台湾家宽 01"] }
    user_rule = "DOMAIN-SUFFIX,openai.com,MyGroup"
    config["rules"].insert(0, user_rule)

    result = ClashPatch.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    managed_rule = "DOMAIN-SUFFIX,openai.com,#{result.fetch(:ai_group)}"

    assert_equal 1, rules.count(user_rule)
    assert_operator rules.index(user_rule), :<, rules.index(managed_rule)
  end

  def test_udp_guard_precedes_leaking_rules_without_deleting_them
    config = base_config
    user_rules = [
      "NETWORK,udp,DIRECT",
      "NETWORK, UDP, DIRECT",
      "DST-PORT,3478,DIRECT",
      "PROCESS-NAME,chrome,DIRECT"
    ]
    config["rules"] = user_rules + config.fetch("rules")

    result = ClashPatch.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    guard = "NETWORK,UDP,#{result.fetch(:safe_group)}"

    assert_equal 0, rules.index(guard)
    assert_equal "NETWORK,UDP,REJECT", rules[1]
    user_rules.each do |rule|
      assert_includes rules, rule
      assert_operator rules.index(guard), :<, rules.index(rule)
    end
  end

  def test_managed_ai_rules_precede_every_rule_set
    config = base_config
    config["rules"] = ["RULE-SET,gfw,DIRECT", "RULE-SET,geolocation-!cn,Main", "MATCH,Main"]

    result = ClashPatch.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    managed = "DOMAIN-SUFFIX,openai.com,#{result.fetch(:ai_group)}"

    assert_operator rules.index(managed), :<, rules.index("RULE-SET,gfw,DIRECT")
    assert_operator rules.index(managed), :<, rules.index("RULE-SET,geolocation-!cn,Main")
  end

  def test_is_idempotent
    first = ClashPatch.patch(base_config, @policy)
    second = ClashPatch.patch(first.fetch(:config), @policy)

    assert first.fetch(:changed)
    refute second.fetch(:changed)
    assert_equal first.fetch(:config), second.fetch(:config)
  end

  def test_skips_invalid_provider_response
    result = ClashPatch.patch({ "message" => "401 unauthorized" }, @policy)

    refute result.fetch(:changed)
    assert_equal :invalid, result.fetch(:status)
  end

  def test_preserves_reality_short_id_as_text
    config = base_config
    config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
    patched = ClashPatch.patch(config, @policy).fetch(:config)

    assert_equal "0906152e4", patched.fetch("proxies").first.dig("reality-opts", "short-id")
  end

  def test_load_yaml_preserves_every_bare_reality_short_id_as_text
    %w[0906152e4 12345678 0].each do |short_id|
      parsed = ClashPatch.load_yaml("reality-opts:\n  short-id: #{short_id}\n")
      assert_instance_of String, parsed.dig("reality-opts", "short-id"), short_id
      assert_equal short_id, parsed.dig("reality-opts", "short-id")
    end
    assert_instance_of Float, ClashPatch.load_yaml("ordinary-number: 1e4\n").fetch("ordinary-number")
  end

  def test_short_id_protection_does_not_rewrite_block_scalar_content
    source = "script: |\n  short-id: 12345678\nreality-opts:\n  short-id: 12345678\n"
    parsed = ClashPatch.load_yaml(source)

    assert_equal "short-id: 12345678\n", parsed.fetch("script")
    assert_equal "12345678", parsed.dig("reality-opts", "short-id")
  end

  def test_file_patch_preserves_bare_exponent_shaped_reality_short_id
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "bare-short-id.yaml")
      config = base_config
      config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
      source = YAML.dump(config).sub(/short-id: ['"]0906152e4['"]/, "short-id: 0906152e4")
      assert_includes source, "short-id: 0906152e4"
      File.write(profile, source)

      result = ClashPatch.patch_path(profile, @policy)
      reparsed = ClashPatch.load_yaml(File.read(profile))

      assert result.fetch(:changed)
      assert_equal "0906152e4", reparsed.fetch("proxies").first.dig("reality-opts", "short-id")
    end
  end

  def test_file_patch_is_atomic_quoted_backed_up_and_idempotent
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup = File.join(directory, "private-backups")
      config = base_config
      config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
      File.write(profile, YAML.dump(config))

      first = ClashPatch.patch_path(profile, @policy, backup_root: backup)
      first_text = File.read(profile)
      second = ClashPatch.patch_path(profile, @policy, backup_root: backup)

      assert first.fetch(:changed)
      assert_match(/short-id: ['"]0906152e4['"]/, first_text)
      assert_equal 1, Dir.glob(File.join(backup, "*.backup")).length
      refute second.fetch(:changed)
      assert_equal first_text, File.read(profile)
    end
  end

  def test_refresh_during_validation_is_reloaded_before_write
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      calls = 0
      validator = lambda do |_candidate|
        calls += 1
        if calls == 1
          refreshed = base_config
          refreshed["friend-marker"] = "new subscription content"
          File.write(profile, YAML.dump(refreshed))
        end
        true
      end

      result = ClashPatch.patch_path(profile, @policy, backup_root: backup_root, validator: validator)
      written = ClashPatch.load_yaml(File.read(profile))
      backup = ClashPatch.load_yaml(File.read(Dir.glob(File.join(backup_root, "*.backup")).fetch(0)))

      assert_equal :updated, result.fetch(:status)
      assert_equal "new subscription content", written.fetch("friend-marker")
      assert_equal "new subscription content", backup.fetch("friend-marker")
      assert_operator calls, :>=, 2
    end
  end

  def test_repeated_refreshes_leave_latest_subscription_untouched
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      calls = 0
      validator = lambda do |_candidate|
        calls += 1
        refreshed = base_config
        refreshed["friend-marker"] = "refresh-#{calls}"
        File.write(profile, YAML.dump(refreshed))
        true
      end

      result = ClashPatch.patch_path(profile, @policy, validator: validator)
      latest = ClashPatch.load_yaml(File.read(profile))

      assert_equal :concurrent_change, result.fetch(:status)
      assert_equal "refresh-#{calls}", latest.fetch("friend-marker")
      refute latest.key?("ipv6")
    end
  end

  def test_refresh_while_backup_is_created_is_not_overwritten
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      refreshed = base_config
      refreshed["friend-marker"] = "refresh-during-backup"
      original_backup = ClashPatch.method(:backup_once)
      injected = false
      backup_with_refresh = lambda do |path, root, content: nil|
        original_backup.call(path, root, content: content)
        next if injected

        injected = true
        File.write(profile, YAML.dump(refreshed))
      end

      result = ClashPatch.stub(:backup_once, backup_with_refresh) do
        ClashPatch.patch_path(profile, @policy, backup_root: backup_root, validator: ->(_candidate) { true })
      end
      written = ClashPatch.load_yaml(File.read(profile))

      assert_equal :updated, result.fetch(:status)
      assert_equal "refresh-during-backup", written.fetch("friend-marker")
      assert_equal false, written.fetch("ipv6")
    end
  end

  def test_profile_scan_excludes_runtime_and_backup_files
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), "rules: []\n")
      File.write(File.join(directory, "config.yaml"), "rules: []\n")
      File.write(File.join(directory, "UPPER.YML"), "rules: []\n")
      File.write(File.join(directory, "friend.yaml.backup"), "rules: []\n")
      File.write(File.join(directory, "friend.backup.yaml"), "rules: []\n")
      File.write(File.join(directory, "friend.bak.yml"), "rules: []\n")
      File.write(File.join(directory, "friend.clash-patch.yaml"), "rules: []\n")
      FileUtils.mkdir_p(File.join(directory, "providers"))
      File.write(File.join(directory, "providers", "cache.yaml"), "rules: []\n")

      expected = %w[UPPER.YML config.yaml friend.yaml].map { |name| File.join(directory, name) }
      assert_equal expected, ClashPatch.profile_paths(directory)
    end
  end

  def test_multi_document_yaml_is_skipped_without_rewrite
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "multi.yaml")
      original = YAML.dump(base_config) + "---\nfriend: second-document\n"
      File.write(profile, original)

      result = ClashPatch.patch_path(profile, @policy)

      assert_equal :invalid, result.fetch(:status)
      assert_equal original, File.read(profile)
    end
  end

  def test_yaml_alias_cycle_is_skipped_without_crashing_run
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "cycle.yaml")
      original = <<~YAML
        proxies:
          - { name: node, type: ss, server: example.com }
        proxy-groups:
          - { name: Main, type: select, proxies: [node] }
        rules: [MATCH,Main]
        cycle: &cycle
          self: *cycle
      YAML
      File.write(profile, original)

      result = ClashPatch.patch_path(profile, @policy)

      assert_equal :invalid, result.fetch(:status)
      assert_equal original, File.read(profile)
    end
  end

  def test_shared_main_group_fixtures
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("cases")
    fixtures.each do |fixture|
      config = fixture.fetch("config")
      snapshot = JSON.parse(JSON.generate(config))
      expected = fixture["expected_main_group"]

      detected = ClashPatch.detect_main_group(config, @policy)
      if expected.nil?
        assert_nil detected, fixture.fetch("name")
      else
        assert_equal expected, detected, fixture.fetch("name")
      end
      next unless expected.nil?

      result = ClashPatch.patch(config, @policy)
      refute result.fetch(:changed), fixture.fetch("name")
      assert_equal :no_main_group, result.fetch(:status), fixture.fetch("name")
      assert_equal snapshot, config, fixture.fetch("name")
    end
  end

  def test_ai_named_non_select_group_is_preserved
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-groups"] << { "name" => "AI", "type" => "url-test", "proxies" => ["台湾家宽 01"], "url" => "https://example.invalid", "interval" => 300 }
    result = ClashPatch.patch(config, @policy)
    patched = result.fetch(:config)

    original_ai = patched.fetch("proxy-groups").find { |group| group["name"] == "AI" }
    assert_equal "url-test", original_ai.fetch("type")
    created = patched.fetch("proxy-groups").find { |group| group["name"] == "🤖 AI · Clash Patch" }
    refute_nil created
    assert_equal "select", created.fetch("type")
    assert_equal "🤖 AI · Clash Patch", result.fetch(:ai_group)
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch"
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:safe_group)}"
    refute_self_reference(patched)
  end

  def test_ai_only_group_leaves_config_unchanged
    config = {
      "proxies" => [{ "name" => "台湾家宽 01", "type" => "ss", "server" => "tw.example" }],
      "proxy-groups" => [{ "name" => "AI", "type" => "select", "proxies" => ["台湾家宽 01"] }],
      "rules" => ["MATCH,AI"]
    }
    result = ClashPatch.patch(config, @policy)

    refute result.fetch(:changed)
    assert_equal :no_main_group, result.fetch(:status)
    assert_nil result.fetch(:main_group)
  end

  def test_provider_only_profile_is_patched_and_preserved
    providers = { "provider1" => { "type" => "http", "url" => "https://example.invalid/sub", "interval" => 3600 } }
    config = {
      "proxy-providers" => providers,
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "use" => ["provider1"] },
        { "name" => "AI", "type" => "select", "use" => ["provider1"] }
      ],
      "rules" => ["MATCH,Main"]
    }
    result = ClashPatch.patch(config, @policy)
    patched = result.fetch(:config)

    assert result.fetch(:changed)
    assert_equal "Main", result.fetch(:main_group)
    assert_equal providers, patched.fetch("proxy-providers")
    assert_equal ["provider1"], patched.fetch("proxy-groups").find { |group| group["name"] == "Main" }.fetch("use")
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:safe_group)}"
    refute_self_reference(patched)
  end

  def test_existing_backup_is_hardened_not_replaced
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      backup = File.join(directory, "backups")
      FileUtils.mkdir_p(backup)
      key = Digest::SHA256.hexdigest(File.expand_path(profile))[0, 16]
      existing = File.join(backup, "#{key}-friend.yaml.backup")
      File.write(existing, "first-backup")
      File.chmod(0o644, existing)

      ClashPatch.patch_path(profile, @policy, backup_root: backup)

      assert_equal "first-backup", File.read(existing)
      assert_equal "600", format("%o", File.stat(existing).mode & 0o777)
      assert_equal 1, Dir.glob(File.join(backup, "*.backup")).length
    end
  end

  def test_dry_run_reports_preview_without_writing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.write(profile, original)

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, dry_run: true,
                               backup_root: File.join(directory, "backups"),
                               reloader: ->(_path) { raise "reload must not run during a dry run" },
                               selected_name: "friend")
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      status = ClashPatch.chinese_status(active)

      assert_includes status, "演练"
      refute_includes status, "已更新"
      assert_equal original, File.read(profile)
      refute Dir.exist?(File.join(directory, "backups"))
    end
  end

  def test_invalid_reality_short_ids_are_not_guessed
    config = base_config
    config["proxies"][0]["reality-opts"] = { "short-id" => 83 }
    config["proxies"][1]["reality-opts"] = { "short-id" => "not-hex!!" }
    config["proxies"][2]["reality-opts"] = { "short-id" => "0123456789abcdef00" }
    patched = ClashPatch.patch(config, @policy).fetch(:config)

    assert_equal 83, patched.fetch("proxies")[0].dig("reality-opts", "short-id")
    assert_equal "not-hex!!", patched.fetch("proxies")[1].dig("reality-opts", "short-id")
    assert_equal "0123456789abcdef00", patched.fetch("proxies")[2].dig("reality-opts", "short-id")
  end

  def test_comma_joined_nameserver_policy_keys_are_split
    config = base_config
    config["dns"]["nameserver-policy"] = {
      "+.example.com,+.example.org" => ["223.5.5.5"],
      "+.keep.example" => ["https://1.1.1.1/dns-query#OtherGroup"]
    }
    policy_out = ClashPatch.patch(config, @policy).fetch(:config).dig("dns", "nameserver-policy")

    refute policy_out.key?("+.example.com,+.example.org")
    safe_group = ClashPatch.patch(config, @policy).fetch(:safe_group)
    assert policy_out.fetch("+.example.com").all? { |value| value.end_with?("##{safe_group}") }
    assert policy_out.fetch("+.example.org").all? { |value| value.end_with?("##{safe_group}") }
    assert policy_out.fetch("+.keep.example").all? { |value| value.end_with?("##{safe_group}") }
  end

  def test_chinese_status_covers_all_update_states
    base = { path: "/profiles/friend.yaml", status: :updated, selected_home: nil }

    assert_includes ClashPatch.chinese_status(base.merge(active: true, reloaded: true)), "已更新并生效"
    assert_includes ClashPatch.chinese_status(base.merge(active: true, reloaded: false)), "已更新，等待重新加载"
    assert_includes ClashPatch.chinese_status(base.merge(active: false)), "已更新，选择该订阅时生效"
    assert_includes ClashPatch.chinese_status(base.merge(status: :unchanged)), "无需修改"
  end

  def test_run_reports_reload_success_and_failure
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      File.write(File.join(directory, "other.yaml"), YAML.dump(base_config))

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               reloader: ->(_path) { true }, selected_name: "friend")
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      inactive = results.find { |entry| File.basename(entry[:path]) == "other.yaml" }
      assert_equal true, active[:reloaded]
      assert_includes ClashPatch.chinese_status(active), "已更新并生效"
      assert_nil inactive[:reloaded]
      assert_includes ClashPatch.chinese_status(inactive), "已更新，选择该订阅时生效"
    end

    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               reloader: ->(_path) { false }, selected_name: "friend")
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      assert_equal false, active[:reloaded]
      status = ClashPatch.chinese_status(active)
      assert_includes status, "已更新，等待重新加载"
      refute_includes status, "已更新并生效"
    end
  end

  def test_status_output_contains_no_secrets
    Dir.mktmpdir do |directory|
      config = base_config
      config["proxies"].first.merge!(
        "server" => "secret-server.internal.example",
        "password" => "secret-password-123",
        "uuid" => "11111111-2222-3333-4444-555555555555"
      )
      File.write(File.join(directory, "friend.yaml"), YAML.dump(config))

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               reloader: ->(_path) { true }, selected_name: "friend")
      output = results.map { |entry| ClashPatch.chinese_status(entry) }.join("\n")
      ["secret-server.internal.example", "secret-password-123", "11111111-2222-3333-4444-555555555555"].each do |secret|
        refute_includes output, secret
      end
    end
  end

  def test_status_labels_remove_terminal_controls_and_secret_shapes
    result = {
      path: "/profiles/\e[31m11111111-2222-3333-4444-555555555555.yaml",
      status: :updated,
      active: false,
      selected_home: "node\e]0;owned\a password=secret-value 11111111-2222-3333-4444-555555555555"
    }

    output = ClashPatch.chinese_status(result)

    refute_includes output, "\e"
    refute_includes output, "\a"
    refute_includes output, "11111111-2222-3333-4444-555555555555"
    refute_includes output, "secret-value"
  end

  def test_backup_directory_and_files_use_private_permissions
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      File.chmod(0o644, profile)
      backup = File.join(directory, "backups")

      ClashPatch.patch_path(profile, @policy, backup_root: backup)

      assert_equal "700", format("%o", File.stat(backup).mode & 0o777)
      backup_file = Dir.glob(File.join(backup, "*.backup")).first
      refute_nil backup_file
      assert_equal "600", format("%o", File.stat(backup_file).mode & 0o777)
      assert_equal "644", format("%o", File.stat(profile).mode & 0o777)
    end
  end

  def test_yaml_12_plain_strings_survive_round_trip
    text = <<~YAML
      proxies:
        - name: node
          type: socks5
          server: example.com
          port: 443
          username: yes
          password: on
          sni: 0123
          client-fingerprint: 1:20
      proxy-groups:
        - name: Main
          type: select
          proxies: [node]
      rules: [MATCH,Main]
      expire: 2026-07-21
    YAML

    loaded = ClashPatch.load_yaml(text)
    proxy = loaded.fetch("proxies").first
    assert_equal "yes", proxy.fetch("username")
    assert_equal "on", proxy.fetch("password")
    assert_equal "0123", proxy.fetch("sni")
    assert_equal "1:20", proxy.fetch("client-fingerprint")
    assert_equal "2026-07-21", loaded.fetch("expire")

    Dir.mktmpdir do |directory|
      path = File.join(directory, "config.yaml")
      File.write(path, text)
      result = ClashPatch.patch_path(path, @policy)
      assert_equal :updated, result.fetch(:status)
      round_trip = ClashPatch.load_yaml(File.read(path))
      values = %w[username password sni client-fingerprint].map { |key| round_trip.fetch("proxies").first.fetch(key) }
      assert_equal ["yes", "on", "0123", "1:20"], values
      assert_equal "2026-07-21", round_trip.fetch("expire")
    end
  end

  def test_dns_policy_preserves_only_verified_non_direct_targets
    config = base_config
    config["proxy-groups"] << { "name" => "SafeExisting", "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << { "name" => "CanDirect", "type" => "select", "proxies" => ["台湾家宽 01", "DIRECT"] }
    config["dns"]["nameserver-policy"] = {
      "+.proxy.example" => ["https://1.1.1.1/dns-query#台湾家宽 01"],
      "+.group.example" => ["https://1.1.1.1/dns-query#SafeExisting"],
      "+.direct.example" => ["https://1.1.1.1/dns-query#CanDirect"],
      "+.option.example" => ["https://1.1.1.1/dns-query#h3=true"],
      "+.interface.example" => ["https://1.1.1.1/dns-query#en0"]
    }
    result = ClashPatch.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")

    assert_equal ["https://1.1.1.1/dns-query#台湾家宽 01"], policies.fetch("+.proxy.example")
    assert_equal ["https://1.1.1.1/dns-query#SafeExisting"], policies.fetch("+.group.example")
    %w[+.direct.example +.option.example +.interface.example].each do |pattern|
      assert policies.fetch(pattern).all? { |value| value.end_with?("##{result.fetch(:safe_group)}") }, pattern
    end
  end

  def test_dns_policy_rejects_plaintext_and_dynamic_group_targets
    config = base_config
    config["proxy-providers"] = { "provider1" => { "type" => "http", "url" => "https://example.invalid/sub" } }
    config["proxy-groups"] << { "name" => "ProviderGroup", "type" => "select", "use" => ["provider1"] }
    config["proxy-groups"] << {
      "name" => "IncludeAllGroup", "type" => "select", "include-all" => true,
      "exclude-type" => "Indirect"
    }
    config["dns"]["nameserver-policy"] = {
      "+.encrypted.example" => ["https://1.1.1.1/dns-query#台湾家宽 01"],
      "+.plaintext.example" => ["1.1.1.1#台湾家宽 01"],
      "+.provider.example" => ["https://1.1.1.1/dns-query#ProviderGroup"],
      "+.include-all.example" => ["https://1.1.1.1/dns-query#IncludeAllGroup"]
    }

    result = ClashPatch.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:safe_group)}"

    assert_equal ["https://1.1.1.1/dns-query#台湾家宽 01"], policies.fetch("+.encrypted.example")
    %w[+.plaintext.example +.provider.example +.include-all.example].each do |pattern|
      assert policies.fetch(pattern).all? { |endpoint| endpoint.end_with?(safe_suffix) }, pattern
    end
  end

  def test_null_proxy_providers_do_not_crash_dns_validation
    config = base_config
    config["proxy-providers"] = nil
    config["proxy-groups"] << { "name" => "NullProviderGroup", "type" => "select", "use" => ["missing"] }
    config["dns"]["nameserver-policy"] = {
      "+.null-provider.example" => ["https://1.1.1.1/dns-query#NullProviderGroup"]
    }

    result = ClashPatch.patch(config, @policy)

    assert_equal :updated, result.fetch(:status)
    assert result.fetch(:config).dig("dns", "nameserver-policy", "+.null-provider.example").all? do |endpoint|
      endpoint.end_with?("##{result.fetch(:safe_group)}")
    end
  end

  def test_direct_and_rematch_home_names_are_never_selected
    config = base_config
    config["proxies"].unshift(
      { "name" => "台湾家宽 DIRECT", "type" => "direct" },
      { "name" => "台湾家宽 REMATCH", "type" => "rematch", "target-rematch-name" => "again" }
    )
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"].unshift(
      "台湾家宽 DIRECT", "台湾家宽 REMATCH"
    )

    result = ClashPatch.patch(config, @policy)
    safe = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:safe_group) }

    assert_equal "台湾家宽 01", result.fetch(:selected_home)
    refute_includes safe.fetch("proxies"), "台湾家宽 DIRECT"
    refute_includes safe.fetch("proxies"), "台湾家宽 REMATCH"
    assert_includes safe.fetch("exclude-type"), "Rematch"
  end

  def test_owned_ai_group_is_single_member_and_collision_safe
    config = base_config
    config["proxy-groups"] << { "name" => "🤖 AI · Clash Patch", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << { "name" => "🤖 AI · Clash Patch 2", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    result = ClashPatch.patch(config, @policy)
    names = result.fetch(:config).fetch("proxy-groups").map { |group| group["name"] }

    assert_equal names.uniq, names
    assert_equal "🤖 AI · Clash Patch 3", result.fetch(:ai_group)
    managed = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01"], managed.fetch("proxies")
  end

  def test_user_owned_branded_select_group_is_preserved
    config = base_config
    user_group = {
      "name" => "🤖 AI · Clash Patch",
      "type" => "select",
      "proxies" => ["Main", "日本家宽 01"],
      "icon" => "https://example.invalid/user-icon.png"
    }
    config["proxy-groups"] << user_group

    first = ClashPatch.patch(config, @policy)
    second = ClashPatch.patch(first.fetch(:config), @policy)
    preserved = first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }

    assert_equal user_group, preserved
    assert_equal "🤖 AI · Clash Patch 2", first.fetch(:ai_group)
    refute second.fetch(:changed)
  end

  def test_branded_user_group_with_ai_rules_is_not_mistaken_for_patch_ownership
    config = base_config
    user_group = {
      "name" => "🤖 AI · Clash Patch",
      "type" => "select",
      "proxies" => ["Main", "日本家宽 01"],
      "icon" => "https://example.invalid/user-icon.png"
    }
    config["proxy-groups"] << user_group
    config["rules"].unshift(
      "DOMAIN-SUFFIX,anthropic.com,🤖 AI · Clash Patch",
      "DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch"
    )

    result = ClashPatch.patch(config, @policy)

    assert_equal user_group, result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal "🤖 AI · Clash Patch 2", result.fetch(:ai_group)
  end

  def test_managed_suffix_ten_is_idempotent
    config = base_config
    base = "🤖 AI · Clash Patch"
    config["proxy-groups"] << { "name" => base, "type" => "select", "proxies" => ["Main"] }
    (2..9).each do |suffix|
      config["proxy-groups"] << { "name" => "#{base} #{suffix}", "type" => "select", "proxies" => ["Main"] }
    end

    first = ClashPatch.patch(config, @policy)
    second = ClashPatch.patch(first.fetch(:config), @policy)

    assert_equal "#{base} 10", first.fetch(:ai_group)
    refute second.fetch(:changed)
    assert_equal first.fetch(:config), second.fetch(:config)
  end

  def test_rule_template_inserts_group_name_literally
    rendered = ClashPatch.render_ai_rules(@policy, 'AI \\1')
    assert_includes rendered, 'DOMAIN-SUFFIX,openai.com,AI \\1'
  end

  def test_symlinked_profile_is_preserved
    Dir.mktmpdir do |directory|
      target = File.join(directory, "actual.yaml")
      link = File.join(directory, "friend.yaml")
      File.write(target, YAML.dump(base_config))
      File.symlink(target, link)

      result = ClashPatch.patch_path(link, @policy)

      assert result.fetch(:changed)
      assert File.symlink?(link)
      assert_equal :updated, result.fetch(:status)
      assert_equal false, ClashPatch.load_yaml(File.read(target)).fetch("ipv6")
    end
  end

  def test_io_errors_are_not_reported_as_invalid_content
    Dir.mktmpdir do |directory|
      result = ClashPatch.patch_path(directory, @policy)
      assert_equal :io_error, result.fetch(:status)
      assert_includes ClashPatch.chinese_status(result), "读取或写入失败"
    end
  end

  def test_validator_failure_preserves_original_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.write(path, original)

      result = ClashPatch.patch_path(path, @policy, validator: ->(_candidate) { false })

      assert_equal :validation_failed, result.fetch(:status)
      assert_equal original, File.read(path)
    end
  end

  def test_active_profile_matching_accepts_extension_and_case
    assert ClashPatch.active_profile?("/profiles/Config.YAML", "config.yaml")
    assert ClashPatch.active_profile?("/profiles/config.yaml", "CONFIG")
    assert ClashPatch.active_profile?("/profiles/config.yaml", "")
    refute ClashPatch.active_profile?("/profiles/other.yaml", "config")
  end

  def test_reload_requires_http_204
    requester_401 = ->(*_args) { [401, ""] }
    requester_204 = ->(*_args) { [204, ""] }
    assert_equal false, ClashPatch.reload("/profiles/config.yaml", socket: "/tmp/fake.sock", requester: requester_401)
    assert_equal true, ClashPatch.reload("/profiles/config.yaml", socket: "/tmp/fake.sock", requester: requester_204)
  end

  def test_ai_runtime_selection_is_verified
    calls = []
    requester = lambda do |method, path, body|
      calls << [method, path, body]
      method == "PUT" ? [204, ""] : [200, JSON.generate("now" => "台湾家宽 01")]
    end
    assert ClashPatch.select_proxy("🤖 AI · Clash Patch", "台湾家宽 01", socket: "/tmp/fake.sock", requester: requester)
    assert_equal %w[PUT GET], calls.map(&:first)
    expected_path = "/proxies/%F0%9F%A4%96%20AI%20%C2%B7%20Clash%20Patch"
    assert_equal [expected_path, expected_path], calls.map { |call| call[1] }
    refute calls.any? { |call| call[1].include?("+") }

    wrong_shape = ->(method, *_args) { method == "PUT" ? [204, ""] : [200, "[]"] }
    assert_equal false, ClashPatch.select_proxy("group", "node", socket: "/tmp/fake.sock", requester: wrong_shape)
  end

  def test_controller_socket_ignores_disappearing_cache_files
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      File.symlink(File.join(cache, "missing-target"), File.join(cache, "vanished.yaml"))

      assert_nil ClashPatch.controller_socket
    ensure
      ENV["HOME"] = old_home
    end
  end

  def test_tun_state_uses_authoritative_runtime_config
    assert_respond_to ClashPatch, :tun_state
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }
    disabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => false })] }
    unavailable = ->(*_args) { [503, ""] }
    malformed = ->(*_args) { [200, "not json"] }
    wrong_shape = ->(*_args) { [200, "[]"] }

    assert_equal :enabled, ClashPatch.tun_state(socket: "/tmp/fake.sock", requester: enabled)
    assert_equal :disabled, ClashPatch.tun_state(socket: "/tmp/fake.sock", requester: disabled)
    assert_equal :unknown, ClashPatch.tun_state(socket: "/tmp/fake.sock", requester: unavailable)
    assert_equal :unknown, ClashPatch.tun_state(socket: "/tmp/fake.sock", requester: malformed)
    assert_equal :unknown, ClashPatch.tun_state(socket: "/tmp/fake.sock", requester: wrong_shape)
  end

  def test_icloud_profile_discovery_includes_current_and_legacy_containers
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [local, current, legacy].each { |path| FileUtils.mkdir_p(path) }

      directories = ClashPatch.default_profile_directories(home: home, app_paths: [])
      assert_equal [local, current, legacy], directories
      watch_paths = ClashPatch.default_watch_paths(home: home, app_paths: [])
      assert_includes watch_paths, File.dirname(current)
      assert_includes watch_paths, current
      assert_includes watch_paths, File.dirname(legacy)
      assert_includes watch_paths, legacy
    end
  end

  def test_mihomo_validation_uses_the_profile_directory
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |icloud|
        old_home = ENV["HOME"]
        ENV["HOME"] = home
        FileUtils.mkdir_p(File.join(home, ".config", "clash.meta"))
        profile = File.join(icloud, "friend.yaml")
        File.write(profile, "rules: []\n")

        assert_equal icloud, ClashPatch.mihomo_validation_directory(profile)
      ensure
        ENV["HOME"] = old_home
      end
    end
  end

  def test_mihomo_version_gate_and_missing_core_fail_closed
    assert ClashPatch.mihomo_version_supported?("Mihomo Meta v1.19.27 linux amd64")
    assert ClashPatch.mihomo_version_supported?("mihomo v1.20.0")
    refute ClashPatch.mihomo_version_supported?("Mihomo Meta v1.19.26")
    refute ClashPatch.mihomo_version_supported?("unknown")
    refute ClashPatch.validate_with_mihomo("/tmp/missing.yaml", core_path: nil)
  end

  def test_cli_default_policy_path_works_from_the_repository
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))

      output, error, status = Open3.capture3(
        RbConfig.ruby, PATCHER_PATH, "--profile-dir", directory, "--dry-run"
      )

      assert status.success?, "stdout=#{output.inspect} stderr=#{error.inspect}"
      assert_includes output, "演练"
    end
  end

  def test_generated_profile_passes_installed_mihomo_validation
    core = ClashPatch.mihomo_core_path
    skip "ClashX Meta Mihomo core is not installed" unless core

    text = <<~YAML
      mixed-port: 7890
      proxies:
        - name: node
          type: socks5
          server: 127.0.0.1
          port: 1080
          username: yes
          password: on
          udp: true
      proxy-groups:
        - name: Main
          type: select
          proxies: [node]
      rules:
        - MATCH,Main
    YAML
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "config.yaml")
      File.write(profile, text)
      core_args = [core, "-d", ClashPatch.mihomo_validation_directory(profile), "-t", "-f", profile]
      assert system(*core_args, out: File::NULL, err: File::NULL), "baseline fixture must be valid"
      result = ClashPatch.patch_path(profile, @policy, validator: ClashPatch.method(:validate_with_mihomo))
      assert_equal :updated, result.fetch(:status)
      assert system(*core_args, out: File::NULL, err: File::NULL), "patched fixture must stay valid"
    end
  end

  def test_every_profile_status_is_documented
    policy_document = File.read(File.join(ROOT, "clash-patch/references/patch-policy.md"))
    line = policy_document[/订阅状态只能是：(.*?)。当前订阅/m, 1]
    documented = line.split("、")
    examples = [
      { path: "/profiles/friend.yaml", status: :updated, active: true, reloaded: true, selected_home: nil },
      { path: "/profiles/friend.yaml", status: :updated, active: true, reloaded: false, selected_home: nil },
      { path: "/profiles/friend.yaml", status: :updated, active: false, selected_home: nil },
      { path: "/profiles/friend.yaml", status: :unchanged },
      { path: "/profiles/friend.yaml", status: :no_main_group },
      { path: "/profiles/friend.yaml", status: :invalid },
      { path: "/profiles/friend.yaml", status: :validation_failed },
      { path: "/profiles/friend.yaml", status: :io_error },
      { path: "/profiles/friend.yaml", status: :error }
    ]
    examples.each do |example|
      message = ClashPatch.chinese_status(example).split("：", 2).last
      assert documented.any? { |status| message.start_with?(status) }, message
    end
  end

  private

  def refute_self_reference(config)
    config.fetch("proxy-groups").each do |group|
      refute_includes Array(group["proxies"]), group["name"], "group #{group['name']} references itself"
    end
  end

  def base_config
    {
      "proxies" => [
        { "name" => "台湾家宽 01", "type" => "ss", "server" => "tw.example", "password" => "fixture-secret" },
        { "name" => "日本家宽 01", "type" => "ss", "server" => "jp.example", "password" => "fixture-secret" },
        { "name" => "美国家宽 01", "type" => "ss", "server" => "us.example", "password" => "fixture-secret" }
      ],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"] },
        { "name" => "AI", "type" => "select", "proxies" => ["Main"] }
      ],
      "dns" => {
        "enable" => true,
        "nameserver" => ["223.5.5.5"],
        "nameserver-policy" => { "+.example.com,+.example.org" => ["223.5.5.5"] }
      },
      "rules" => [
        "DOMAIN,raw.githubusercontent.com,AI",
        "DOMAIN,storage.googleapis.com,AI",
        "DOMAIN-SUFFIX,friend.example,DIRECT",
        "DOMAIN,static.example.net,DIRECT",
        "GEOSITE,CN,DIRECT",
        "MATCH,Main"
      ]
    }
  end
end
