require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
PATCHER_PATH = File.join(ROOT, "clash-patch/scripts/macos/patch_profiles.rb")
ROUTE_VERIFIER_PATH = File.join(ROOT, "clash-patch/scripts/macos/verify_routes.rb")
RESULT_CONTRACT_PATH = File.join(ROOT, "clash-patch/scripts/macos/result_contract.rb")
POLICY_PATH = File.join(ROOT, "clash-patch/references/policy.json")
MAIN_GROUP_FIXTURES = File.join(ROOT, "tests/fixtures/main_group_cases.json")
PATCHER_AVAILABLE = File.file?(PATCHER_PATH) && File.file?(POLICY_PATH)

require PATCHER_PATH if PATCHER_AVAILABLE
require ROUTE_VERIFIER_PATH if File.file?(ROUTE_VERIFIER_PATH)

class MacosPatcherTest < Minitest::Test
  def setup
    skip "patcher not implemented" unless PATCHER_AVAILABLE || name == "test_patcher_files_exist"
    @policy = JSON.parse(File.read(POLICY_PATH)) if PATCHER_AVAILABLE
  end

  def require_production_probe!
    skip "set CLASH_PATCH_RUN_PRODUCTION_PROBES=1 to run known production-failure probes" unless
      ENV["CLASH_PATCH_RUN_PRODUCTION_PROBES"] == "1"
  end

  def fixture_process?(process_id, marker)
    return false unless process_id

    output, status = Open3.capture2(
      "/bin/ps", "-p", process_id.to_s, "-o", "command="
    )
    status.success? && output.include?(marker)
  rescue SystemCallError
    false
  end

  def test_production_probe_normal_batch_restores_a_commit_when_bookkeeping_raises
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first.yaml z-second.yaml].map do |name|
        path = File.join(directory, name)
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => name)))
        path
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      real_replace = ClashPatch.method(:atomic_replace_locked)
      commits = 0
      injected = false
      faulty_replace = lambda do |*arguments|
        result = real_replace.call(*arguments)
        commits += 1 if result
        if result && commits == 2 && !injected
          injected = true
          raise IOError, "injected after the second durable commit"
        end
        result
      end

      results = ClashPatch.stub(:atomic_replace_locked, faulty_replace) do
        ClashPatch.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "none",
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
        )
      end

      assert injected
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      originals.each do |path, bytes|
        assert File.binread(path) == bytes, "failed batch left committed bytes in #{File.basename(path)}"
      end
    end
  end

  def test_production_probe_safe_update_restores_a_swap_when_bookkeeping_raises
    require_production_probe!
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      canonical = File.realpath(path)
      real_stat = File.method(:stat)
      injected = false
      faulty_stat = lambda do |candidate|
        if !injected && candidate.to_s == canonical && File.binread(path) != original.b
          injected = true
          raise IOError, "injected after the safe-update swap"
        end
        real_stat.call(candidate)
      end

      result = File.stub(:stat, faulty_stat) do
        ClashPatch.safe_update_all(
          targets: [{ name: "friend", path: path, url: "https://fixture.invalid/friend" }],
          policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true },
          activation: ->(_items) { flunk "failed transaction must not activate" }
        )
      end

      assert injected
      refute_equal :updated, result.fetch(:status)
      assert File.binread(path) == original.b, "failed safe update left committed bytes"
    end
  end

  def test_production_probe_normal_batch_rejects_duplicate_file_aliases
    require_production_probe!
    Dir.mktmpdir do |directory|
      profiles = File.join(directory, "profiles")
      FileUtils.mkdir_p(profiles)
      target = File.join(directory, "real.yaml")
      original = YAML.dump(base_config)
      File.write(target, original)
      aliases = %w[a-alias.yaml z-active.yaml].map do |name|
        path = File.join(profiles, name)
        File.symlink(target, path)
        path
      end
      activations = []

      results = ClashPatch.stub(
        :activate_updated_profile,
        lambda { |result, **_options|
          activations << result
          result.merge(reloaded: true)
        }
      ) do
        ClashPatch.run(
          directory: profiles, active_directory: profiles, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "z-active",
          validator: ->(_path) { true }, auto_reload: true, usage_profile: 1
        )
      end

      safely_rejected = !results.all? do |result|
        %i[updated unchanged].include?(result.fetch(:status))
      end
      violations = []
      violations << "accepted duplicate aliases" unless safely_rejected
      violations << "changed the shared target" unless File.binread(target) == original.b
      violations << "activated a duplicate target" unless activations.empty?
      assert_empty violations, violations.join("; ")
      aliases.each { |path| assert File.symlink?(path), path }
    end
  end

  def test_production_probe_next_run_recovers_batch_killed_after_first_commit
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first.yaml z-second.yaml].map do |name|
        path = File.join(directory, name)
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => name)))
        path
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          real_replace = ClashPatch.method(:atomic_replace_locked)
          commits = 0
          gated_replace = lambda do |*arguments|
            result = real_replace.call(*arguments)
            commits += 1 if result
            if result && commits == 1
              ready_writer.write(".")
              ready_writer.flush
              gate_reader.read(1)
            end
            result
          end
          ClashPatch.stub(:atomic_replace_locked, gated_replace) do
            ClashPatch.run(
              directory: directory, policy_path: POLICY_PATH,
              backup_root: File.join(directory, "backups"), selected_name: "none",
              validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
            )
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never reached the first durable commit"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig

        ClashPatch.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "none",
          validator: ->(_path) { false }, auto_reload: false, usage_profile: 1
        )
        originals.each do |path, bytes|
          assert File.binread(path) == bytes, "next run did not recover #{File.basename(path)}"
        end
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_production_probe_next_safe_update_recovers_batch_killed_after_first_swap
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first z-second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        path
      end
      targets = paths.map do |path|
        name = File.basename(path, ".yaml")
        { name: name, path: path, url: "https://fixture.invalid/#{name}" }
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          real_swap = ClashPatch.method(:atomic_swap_paths)
          swaps = 0
          gated_swap = lambda do |*arguments|
            result = real_swap.call(*arguments)
            swaps += 1
            if swaps == 1
              ready_writer.write(".")
              ready_writer.flush
              gate_reader.read(1)
            end
            result
          end
          ClashPatch.stub(:atomic_swap_paths, gated_swap) do
            ClashPatch.safe_update_all(
              targets: targets, policy: @policy,
              backup_root: File.join(directory, "backups"), usage_profile: 1,
              fetcher: lambda { |target|
                YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
              },
              validator: ->(_path) { true }, activation: ->(_items) { true }
            )
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never reached the first safe-update swap"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        Process.waitpid(child_id)
        child_id = nil

        ClashPatch.safe_update_all(
          targets: targets, policy: @policy,
          backup_root: File.join(directory, "backups"), usage_profile: 1,
          fetcher: ->(_target) { raise IOError, "injected preflight failure" },
          validator: ->(_path) { true }, activation: ->(_items) { true }
        )
        originals.each do |path, bytes|
          assert File.binread(path) == bytes, "next safe-update entry did not recover #{File.basename(path)}"
        end
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_production_probe_mihomo_does_not_survive_a_killed_validator
    require_production_probe!
    Dir.mktmpdir do |directory|
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.ip_port
      core = File.join(directory, "mihomo")
      File.write(core, <<~RUBY)
        #!#{RbConfig.ruby}
        require "socket"
        socket = TCPSocket.new("127.0.0.1", ENV.fetch("CLASH_PATCH_READY_PORT").to_i)
        socket.puts(Process.pid)
        socket.close
        sleep 60
      RUBY
      File.chmod(0o700, core)
      worker_id = nil
      core_id = nil
      connection = nil
      core_alive = nil
      leftovers = nil
      begin
        worker_id = fork do
          ENV["CLASH_PATCH_READY_PORT"] = port.to_s
          ENV["TMPDIR"] = directory
          ClashPatch.mihomo_core_status(core, timeout_seconds: 30)
          exit! 0
        end
        assert IO.select([listener], nil, nil, 10), "fake Mihomo never started"
        connection = listener.accept
        core_id = Integer(connection.gets)
        Process.kill("KILL", worker_id)
        Process.waitpid(worker_id)
        worker_id = nil

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        loop do
          core_alive = begin
            Process.kill(0, core_id)
            true
          rescue Errno::ESRCH
            false
          end
          leftovers = Dir.glob(File.join(directory, "clash-patch-command*"))
          break if !core_alive && leftovers.empty?
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.02
        end
      ensure
        Process.kill("KILL", worker_id) rescue nil
        Process.waitpid(worker_id) rescue nil
        if fixture_process?(core_id, core)
          Process.kill("KILL", -core_id) rescue nil
          Process.kill("KILL", core_id) rescue nil
        end
        connection&.close rescue nil
        listener.close rescue nil
        Dir.glob(File.join(directory, "clash-patch-command*")).each { |path| FileUtils.rm_f(path) }
      end

      violations = []
      violations << "Mihomo child survived" if core_alive
      violations << "command output tempfile remained" unless leftovers.empty?
      assert_empty violations, violations.join("; ")
    end
  end

  def test_patcher_files_exist
    assert File.file?(PATCHER_PATH), "macOS patcher is missing"
    assert File.file?(RESULT_CONTRACT_PATH), "macOS result contract is missing"
    assert File.file?(POLICY_PATH), "canonical policy is missing"
  end

  def test_common_china_domain_baseline_applies_to_lightweight_profiles
    original = base_config
    original["ipv6"] = true
    original["tun"] = { "enable" => false }

    [1, 2].each do |usage_profile|
      patched = ClashPatch.patch(original, @policy, usage_profile: usage_profile).fetch(:config)
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      provider = patched.fetch("rule-providers").fetch(provider_name)

      assert_equal "http", provider.fetch("type")
      assert_equal "domain", provider.fetch("behavior")
      assert_equal "mrs", provider.fetch("format")
      assert_equal @policy.fetch("cn_domain_provider").fetch("url"), provider.fetch("url")
      assert_equal "Main", provider.fetch("proxy")
      assert_equal @policy.fetch("direct_resolvers"),
                   patched.dig("dns", "nameserver-policy", "rule-set:#{provider_name}")
      cn_index = patched.fetch("rules").index("RULE-SET,#{provider_name},DIRECT")
      broad_index = patched.fetch("rules").index("GEOSITE,CN,DIRECT")
      assert_operator cn_index, :<, broad_index
      assert_equal true, patched.fetch("ipv6")
      assert_equal({ "enable" => false }, patched.fetch("tun"))
      refute patched.fetch("rules").any? { |rule| rule.start_with?("NETWORK,UDP,") }
      assert_equal patched, ClashPatch.patch(patched, @policy, usage_profile: usage_profile).fetch(:config)
    end
  end

  def test_common_china_domain_baseline_does_not_overwrite_user_provider_name
    config = base_config
    base_name = @policy.fetch("cn_domain_provider").fetch("name")
    config["rule-providers"] = {
      base_name => { "type" => "file", "behavior" => "domain", "path" => "./user-owned.yaml" }
    }

    patched = ClashPatch.patch(config, @policy, usage_profile: 1).fetch(:config)

    assert_equal "./user-owned.yaml", patched.fetch("rule-providers").fetch(base_name).fetch("path")
    assert patched.fetch("rule-providers").key?("#{base_name}-2")
    assert_includes patched.fetch("rules"), "RULE-SET,#{base_name}-2,DIRECT"
  end

  def test_common_china_domain_baseline_does_not_reuse_user_provider_path
    config = base_config
    provider_policy = @policy.fetch("cn_domain_provider")
    base_name = provider_policy.fetch("name")
    config["rule-providers"] = {
      "user-cn" => { "type" => "file", "behavior" => "domain", "path" => provider_policy.fetch("path") }
    }

    patched = ClashPatch.patch(config, @policy, usage_profile: 1).fetch(:config)

    assert_equal provider_policy.fetch("path"), patched.fetch("rule-providers").fetch("user-cn").fetch("path")
    assert_equal "./ruleset/#{base_name}-2.mrs",
                 patched.fetch("rule-providers").fetch("#{base_name}-2").fetch("path")
    assert_includes patched.fetch("rules"), "RULE-SET,#{base_name}-2,DIRECT"
  end

  def test_result_contract_rejects_unstable_command_names
    assert_raises(ArgumentError) do
      ClashPatchResult.build(
        command: "patch_profiles.rb", operation: "test", ok: true, status: "ok",
        code: "ok", exit_code: 0, summary_zh: "完成"
      )
    end
  end

  def test_result_contract_cli_emits_valid_json_and_rejects_bad_arguments
    output, error = capture_io do
      assert_equal 0, ClashPatchResult.cli(%w[
        --command patch --operation test --ok true --status ok --code completed
        --exit-code 0 --summary 完成 --profile 3 --message done --warning check
      ])
    end
    assert_empty error
    result = JSON.parse(output)
    assert_equal "patch", result.fetch("command")
    assert_equal 3, result.fetch("profile")
    assert_equal ["done"], result.fetch("messages")
    assert_equal ["check"], result.fetch("warnings")

    output, error = capture_io do
      assert_equal 0, ClashPatchResult.cli(%w[
        --command patch --operation test --ok true --status ok --code completed
        --exit-code 0 --summary 完成 --profile 4
      ])
    end
    assert_empty error
    assert_nil JSON.parse(output).fetch("profile")

    output, error = capture_io do
      assert_equal 64, ClashPatchResult.cli(%w[--command unknown])
    end
    assert_empty error
    result = JSON.parse(output)
    assert_equal "patch", result.fetch("command")
    assert_equal "invalid_request", result.fetch("status")
  end

  def test_result_contract_normalizes_unknown_status_and_value_types
    result = ClashPatchResult.build(
      command: :install, operation: :test, ok: false, status: :unknown, code: :failed,
      exit_code: "1", summary_zh: "完成", changes: [nil, true, 3, :symbol]
    )
    assert_equal "failed", result.fetch("status")
    assert_equal 1, result.fetch("exit_code")
    assert_equal [nil, true, 3, "symbol"], result.fetch("changes")
  end

  def test_result_contract_has_required_fields_and_recursively_redacts_sensitive_text
    output = StringIO.new
    ClashPatchResult.write(
      output: output, command: "patch", operation: "test", ok: true, status: "ok", code: "ok",
      exit_code: 0, summary_zh: "password=private https://secret.invalid /Users/private/config.yaml",
      checks: [{ "detail" => "uuid=11111111-2222-3333-4444-555555555555" }]
    )

    result = JSON.parse(output.string)
    assert_equal %w[
      schema version command platform client operation ok status code exit_code summary_zh
      profile changes checks items messages warnings
    ].sort, result.keys.sort
    refute_includes output.string, "private"
    refute_includes output.string, "secret.invalid"
    refute_includes output.string, "11111111-2222-3333-4444-555555555555"
  end

  def test_patcher_json_mode_emits_one_redacted_contract_object
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      config = base_config
      config["proxies"].first["name"] = "PRIVATE-NODE-NAME"
      File.write(profile, YAML.dump(config))

      output, error, status = Open3.capture3(
        RbConfig.ruby, PATCHER_PATH, "--json", "--profile-dir", directory, "--dry-run"
      )

      assert status.success?, error
      assert_empty error
      result = JSON.parse(output)
      assert_equal "clash-patch.result", result.fetch("schema")
      assert_equal status.exitstatus, result.fetch("exit_code")
      assert_equal "patch", result.fetch("command")
      assert_equal "macos", result.fetch("platform")
      assert_equal "clashx-meta", result.fetch("client")
      refute_includes output, directory
      refute_includes output, "PRIVATE-NODE-NAME"
      refute_includes output, "fixture-secret"
    end
  end

  def test_patcher_json_mode_structures_argument_errors_regardless_of_argument_order
    output, error, status = Open3.capture3(RbConfig.ruby, PATCHER_PATH, "--unknown", "--json")

    assert_equal 64, status.exitstatus
    assert_empty error
    result = JSON.parse(output)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal 64, result.fetch("exit_code")
  end

  def test_json_mode_reports_an_incomplete_ruby_package_as_one_object
    Dir.mktmpdir do |directory|
      patcher_dir = File.join(directory, "patcher")
      verifier_dir = File.join(directory, "verifier")
      FileUtils.mkdir_p([patcher_dir, verifier_dir])
      patcher = File.join(patcher_dir, "patch_profiles.rb")
      verifier = File.join(verifier_dir, "verify_routes.rb")
      FileUtils.cp(PATCHER_PATH, patcher)
      FileUtils.cp(ROUTE_VERIFIER_PATH, verifier)

      [[patcher, "patch"], [verifier, "verify_routes"]].each do |path, command|
        output, error, status = Open3.capture3(RbConfig.ruby, path, "--json")
        assert_equal 1, status.exitstatus
        assert_empty error
        result = JSON.parse(output)
        assert_equal command, result.fetch("command")
        assert_equal "incomplete_package", result.fetch("code")
        assert_equal status.exitstatus, result.fetch("exit_code")
      end
    end
  end

  def test_ruby_bootstrap_fails_closed_in_json_and_text_modes
    [[ClashPatchBootstrap, "patch"], [ClashRouteBootstrap, "verify_routes"]].each do |bootstrap, command|
      output = StringIO.new
      loaded = bootstrap.load_dependencies(
        loader: ->(_path) { raise LoadError, "fixture" }, argv: ["--json"], output: output
      )
      refute loaded
      result = JSON.parse(output.string)
      assert_equal command, result.fetch("command")
      assert_equal "incomplete_package", result.fetch("code")
      assert_raises(LoadError) do
        bootstrap.load_dependencies(
          loader: ->(_path) { raise LoadError, "fixture" }, argv: [], output: StringIO.new
        )
      end
    end
  end

  def test_route_verifier_json_mode_emits_one_contract_object_on_business_failure
    output = StringIO.new
    ClashRouteVerifier.stub(:run, false) do
      assert_equal 1, ClashRouteVerifier.cli(["--json"], output: output)
    end

    result = JSON.parse(output.string)
    assert_equal "verify_routes", result.fetch("command")
    assert_equal "failed", result.fetch("status")
    assert_equal 1, result.fetch("exit_code")
    refute_includes output.string, Dir.home
  end

  def test_route_verifier_cli_json_does_not_forward_human_output
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:) { output.puts("PRIVATE-NODE"); details[:checks] << { "name" => "google", "ok" => true }; true }) do
      assert_equal 0, ClashRouteVerifier.cli(["--json"], output: output)
    end

    result = JSON.parse(output.string)
    assert_equal "ok", result.fetch("status")
    assert_equal [{ "name" => "google", "ok" => true }], result.fetch("checks")
    refute_includes output.string, "PRIVATE-NODE"
  end

  def test_route_verifier_cli_keeps_default_human_output
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:) { output.puts("中文结果"); false }) do
      assert_equal 1, ClashRouteVerifier.cli([], output: output)
    end
    assert_equal "中文结果\n", output.string
  end

  def test_route_verifier_rejects_unknown_arguments_before_running
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "invalid arguments reached route verification" }) do
      assert_equal 64, ClashRouteVerifier.cli(["--typo", "--json"], output: output)
    end
    result = JSON.parse(output.string)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal "invalid_arguments", result.fetch("code")
  end

  def test_route_target_patterns_require_real_domain_boundaries
    patterns = ClashRouteVerifier::TARGETS.to_h { |label, _url, _kind, pattern| [label, pattern] }

    assert_match patterns.fetch("Google"), "www.google.com"
    refute_match patterns.fetch("Google"), "notgoogle.com"
    refute_match patterns.fetch("Google"), "google.com.attacker.invalid"
    assert_match patterns.fetch("OpenAI"), "api.openai.com"
    refute_match patterns.fetch("OpenAI"), "openai.com.attacker.invalid"
    assert_match patterns.fetch("Claude"), "claude.ai"
    refute_match patterns.fetch("Claude"), "notclaude.ai"
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

  def test_locked_write_restores_original_bytes_after_a_partial_write_error
    fake = Class.new do
      attr_reader :bytes

      def initialize(original)
        @bytes = original.dup
        @position = 0
        @writes = 0
      end

      def rewind
        @position = 0
      end

      def write(value)
        @writes += 1
        if @writes == 1
          half = [value.bytesize / 2, 1].max
          @bytes[0, half] = value.byteslice(0, half)
          @position = half
          raise Errno::ENOSPC
        end
        @bytes = value.dup
        @position = value.bytesize
        value.bytesize
      end

      def truncate(length)
        @bytes = @bytes.byteslice(0, length)
      end

      def flush; end
      def fsync; end
    end.new("original configuration")

    assert_raises(Errno::ENOSPC) do
      ClashPatch.write_locked_bytes(fake, "replacement configuration", "original configuration")
    end
    assert_equal "original configuration", fake.bytes
  end

  def test_applies_dns_tun_ai_and_webrtc_policy
    result = ClashPatch.patch(base_config, @policy)
    patched = result.fetch(:config)

    assert result.fetch(:changed)
    assert_equal "Main", result.fetch(:main_group)
    assert_equal "AI", result.fetch(:ai_group)
    refute result.key?(:selected_home)
    assert_equal false, patched["ipv6"]
    assert_equal false, patched.dig("dns", "ipv6")
    assert_equal true, patched.dig("tun", "strict-route")
    assert_equal ["any:53", "tcp://any:53"], patched.dig("tun", "dns-hijack")
    assert patched.dig("dns", "nameserver").all? { |value| value.end_with?("##{result.fetch(:route_group)}") }
    assert_equal @policy.fetch("direct_resolvers"), patched.dig("dns", "direct-nameserver")
    assert_equal false, patched.dig("dns", "direct-nameserver-follow-policy")
    assert_equal @policy.fetch("direct_resolvers"), patched.dig("dns", "nameserver-policy", "geosite:cn")
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? { |value| value.end_with?("##{result.fetch(:ai_group)}") }

    ai_group = patched.fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["Main"], ai_group.fetch("proxies")
    udp = "NETWORK,UDP,#{result.fetch(:ai_group)}"
    assert_includes patched.fetch("rules"), udp
    assert_equal "NETWORK,UDP,REJECT", patched.fetch("rules")[patched.fetch("rules").index(udp) + 1]
    assert_equal 0, patched.fetch("rules").index(udp)
    assert_operator patched.fetch("rules").index(udp), :<, patched.fetch("rules").index("GEOSITE,CN,DIRECT")
    assert_includes patched.fetch("rules"), "DOMAIN,raw.githubusercontent.com,AI"
    assert_includes patched.fetch("rules"), "DOMAIN,storage.googleapis.com,AI"
  end

  def test_reuses_existing_ai_group_without_creating_visible_groups
    config = base_config
    original_ai = Marshal.load(Marshal.dump(config.fetch("proxy-groups").find { |group| group["name"] == "AI" }))

    result = ClashPatch.patch(config, @policy)
    patched = result.fetch(:config)

    assert_equal "AI", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    assert_equal original_ai, patched.fetch("proxy-groups").find { |group| group["name"] == "AI" }
    refute patched.fetch("proxy-groups").any? { |group| ClashPatch.managed_group_name?(group["name"]) }
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,AI"
    assert_equal ["NETWORK,UDP,AI", "NETWORK,UDP,REJECT"], patched.fetch("rules").first(2)
    assert patched.dig("dns", "nameserver").all? { |value| value.end_with?("#Main") }
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? { |value| value.end_with?("#AI") }
  end

  def test_creates_ai_group_with_all_inline_nodes_when_subscription_has_none
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }

    result = ClashPatch.patch(config, @policy)
    patched = result.fetch(:config)

    assert_equal "🤖 AI · Clash Patch", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    ai_group = patched.fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    refute ai_group.key?("use")
    refute patched.fetch("proxy-groups").any? { |group| ClashPatch.managed_name?(group["name"], ClashPatch::SAFE_GROUP_BASE) }
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch"
    assert_equal "NETWORK,UDP,🤖 AI · Clash Patch", patched.fetch("rules")[0]
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? do |value|
      value.end_with?("#🤖 AI · Clash Patch")
    end
  end

  def test_new_ai_group_includes_every_proxy_provider
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-providers"] = {
      "airport-a" => { "type" => "http", "url" => "https://example.invalid/a" },
      "airport-b" => { "type" => "file", "path" => "./providers/b.yaml" }
    }

    result = ClashPatch.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }

    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    assert_equal ["airport-a", "airport-b"], ai_group.fetch("use")
  end

  def test_new_ai_group_supports_provider_only_subscriptions
    config = base_config
    config["proxies"] = []
    config["proxy-groups"] = [{ "name" => "Main", "type" => "select", "use" => ["airport-a"] }]
    config["proxy-providers"] = {
      "airport-a" => { "type" => "http", "url" => "https://example.invalid/a" }
    }
    config["rules"] = ["MATCH,Main"]

    first = ClashPatch.patch(config, @policy)
    ai_group = first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == first.fetch(:ai_group) }

    assert_empty ai_group.fetch("proxies")
    assert_equal ["airport-a"], ai_group.fetch("use")
    assert_equal first.fetch(:config), ClashPatch.patch(first.fetch(:config), @policy).fetch(:config)
  end

  def test_does_not_create_ai_group_without_nodes_or_providers
    config = base_config
    config["proxies"] = []
    config.delete("proxy-providers")
    config["proxy-groups"] = [{ "name" => "Main", "type" => "select", "proxies" => ["Ghost"] }]
    config["rules"] = ["MATCH,Main"]

    result = ClashPatch.patch(config, @policy)

    assert_equal :no_ai_nodes, result.fetch(:status)
    assert_equal config, result.fetch(:config)
  end

  def test_migrates_owned_single_main_ai_group_to_independent_node_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    ai_name = "🤖 AI · Clash Patch"
    config["proxy-groups"] << { "name" => ai_name, "type" => "select", "proxies" => ["Main"] }
    config["rules"] = ClashPatch.render_ai_rules(@policy, ai_name) + config.fetch("rules")

    result = ClashPatch.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == ai_name }

    assert result.fetch(:ai_group_reset)
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    refute_includes ai_group.fetch("proxies"), "Main"
  end

  def test_removes_groups_created_by_an_older_patch
    config = base_config
    ai_name = ClashPatch::AI_GROUP_BASE
    safe_name = ClashPatch::SAFE_GROUP_BASE
    config["proxy-groups"] << { "name" => ai_name, "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << {
      "name" => safe_name, "type" => "select", "proxies" => ["台湾家宽 01", "日本家宽 01"],
      "include-all" => true, "exclude-type" => ClashPatch::EXCLUDED_SAFE_TYPES, "empty-fallback" => "REJECT"
    }
    config["dns"]["nameserver"] = ["https://dns.alidns.com/dns-query##{safe_name}"]
    config["dns"]["nameserver-policy"] = { "+.openai.com" => ["https://dns.alidns.com/dns-query##{safe_name}"] }
    config["rules"] = ["NETWORK,UDP,#{safe_name}", "NETWORK,UDP,REJECT"] +
      ClashPatch.render_ai_rules(@policy, ai_name) + config.fetch("rules")

    patched = ClashPatch.patch(config, @policy).fetch(:config)

    refute patched.fetch("proxy-groups").any? { |group| [ai_name, safe_name].include?(group["name"]) }
    refute patched.fetch("rules").any? { |rule| rule.include?(ai_name) || rule.include?(safe_name) }
    refute JSON.generate(patched.fetch("dns")).include?(safe_name)
    assert_equal ["NETWORK,UDP,AI", "NETWORK,UDP,REJECT"], patched.fetch("rules").first(2)
  end

  def test_preserves_bootstrap_and_replaces_direct_resolvers_with_managed_mainland_doh
    config = base_config
    config["dns"]["default-nameserver"] = ["223.5.5.5", "119.29.29.29"]
    config["dns"]["proxy-server-nameserver"] = ["223.5.5.5", "120.53.53.53"]
    config["dns"]["direct-nameserver"] = ["system"]

    patched = ClashPatch.patch(config, @policy).fetch(:config).fetch("dns")

    assert_equal ["223.5.5.5", "119.29.29.29"], patched.fetch("default-nameserver")
    assert_equal ["223.5.5.5", "120.53.53.53"], patched.fetch("proxy-server-nameserver")
    assert_equal @policy.fetch("direct_resolvers"), patched.fetch("direct-nameserver")
    assert_equal false, patched.fetch("direct-nameserver-follow-policy")
  end

  def test_managed_dns_uses_bootstrap_free_ip_doh_and_rewrites_other_endpoints
    expected_resolvers = [
      "https://94.140.14.140/dns-query",
      "https://94.140.14.141/dns-query",
      "https://101.101.101.101/dns-query"
    ]
    assert_equal expected_resolvers, @policy.fetch("resolvers")
    assert_equal [
      "https://223.5.5.5/dns-query#DIRECT",
      "https://1.12.12.12/dns-query#DIRECT"
    ], @policy.fetch("direct_resolvers")

    config = base_config
    config["dns"]["proxy-server-nameserver"] = ["223.5.5.5", "120.53.53.53"]
    config["dns"]["nameserver-policy"] = {
      "+.hostname-resolver.example" => ["https://dns.alidns.com/dns-query#台湾家宽 01"],
      "+.blocked-prone.example" => ["https://8.8.8.8/dns-query#台湾家宽 01"],
      "+.managed.example" => ["https://94.140.14.140/dns-query#台湾家宽 01"]
    }

    result = ClashPatch.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    managed = expected_resolvers.map { |resolver| "#{resolver}#台湾家宽 01" }

    assert_equal managed, policies.fetch("+.hostname-resolver.example")
    assert_equal managed, policies.fetch("+.blocked-prone.example")
    assert_equal managed, policies.fetch("+.managed.example")
    assert_equal ["223.5.5.5", "120.53.53.53"], result.fetch(:config).dig("dns", "proxy-server-nameserver")
  end

  def test_uses_system_only_when_proxy_bootstrap_is_missing
    patched = ClashPatch.patch(base_config, @policy).fetch(:config).fetch("dns")

    refute patched.key?("default-nameserver")
    assert_equal ["system"], patched.fetch("proxy-server-nameserver")
    assert_equal @policy.fetch("direct_resolvers"), patched.fetch("direct-nameserver")
    assert_equal false, patched.fetch("direct-nameserver-follow-policy")
  end

  def test_migrates_the_old_unsafe_bootstrap_signature_to_system
    config = base_config
    config["dns"]["default-nameserver"] = ["1.1.1.1", "8.8.8.8"]
    config["dns"]["proxy-server-nameserver"] = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    patched = ClashPatch.patch(config, @policy).fetch(:config).fetch("dns")

    assert_equal ["system"], patched.fetch("default-nameserver")
    assert_equal ["system"], patched.fetch("proxy-server-nameserver")
  end

  def test_does_not_select_japan_home_automatically
    config = base_config
    config["proxies"].reject! { |proxy| proxy["name"].include?("台湾") }
    config["proxy-groups"].each { |group| group["proxies"]&.delete("台湾家宽 01") }
    result = ClashPatch.patch(config, @policy)

    refute result.key?(:selected_home)
    assert_equal ["Main"], result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "AI" }.fetch("proxies")
  end

  def test_new_ai_group_lists_other_country_nodes_without_auto_selecting
    config = base_config
    config["proxies"].select! { |proxy| proxy["name"] == "美国家宽 01" }
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"] = ["美国家宽 01"]
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    result = ClashPatch.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "🤖 AI · Clash Patch" }

    refute result.key?(:selected_home)
    assert_equal ["美国家宽 01"], ai_group.fetch("proxies")
    refute ai_group.key?("now")
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

  def test_main_group_ai_rules_do_not_bypass_the_ai_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    provider_rules = [
      "DOMAIN-SUFFIX,openai.com,Main",
      "DOMAIN-SUFFIX,claude.ai,Main",
      "DOMAIN-KEYWORD,openai,Main"
    ]
    config["rules"] = provider_rules + config.fetch("rules")

    result = ClashPatch.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    ai_group = result.fetch(:ai_group)

    provider_rules.each { |rule| refute_includes rules, rule }
    assert_includes rules, "DOMAIN-SUFFIX,openai.com,#{ai_group}"
    assert_includes rules, "DOMAIN-SUFFIX,claude.ai,#{ai_group}"
    assert_includes rules, "DOMAIN-KEYWORD,openai,#{ai_group}"
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
    guard = "NETWORK,UDP,#{result.fetch(:ai_group)}"

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

  def test_dump_config_quotes_every_valid_reality_short_id
    short_ids = %w[abcdef12 12ab34cd 0906152e4 12345678]
    config = {
      "proxies" => short_ids.map do |short_id|
        { "reality-opts" => { "short-id" => short_id } }
      end
    }

    dumped = ClashPatch.dump_config(config)

    short_ids.each do |short_id|
      assert_match(/short-id: ["']#{Regexp.escape(short_id)}["']/, dumped)
    end
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

  def test_every_write_creates_a_dated_versioned_backup
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)

      first = ClashPatch.patch_path(profile, @policy, backup_root: backup_root)
      changed_again = ClashPatch.load_yaml(File.read(profile))
      changed_again["ipv6"] = true
      changed_again["friend-marker"] = "before-second-write"
      second_source = YAML.dump(changed_again)
      File.write(profile, second_source)
      second = ClashPatch.patch_path(profile, @policy, backup_root: backup_root)

      backups = Dir.glob(File.join(backup_root, "*.backup")).sort
      assert first.fetch(:changed)
      assert second.fetch(:changed)
      assert_equal 2, backups.length
      backups.each do |path|
        assert_match(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4}--prewrite--[0-9a-f]{16}--friend\.yaml\.backup\z/, File.basename(path))
      end
      assert_includes backups.map { |path| File.binread(path) }, original.b
      assert_includes backups.map { |path| File.binread(path) }, second_source.b
    end
  end

  def test_initial_snapshot_is_created_once_without_modifying_profiles
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)

      first = ClashPatch.snapshot_initial_profiles([directory], backup_root)
      second = ClashPatch.snapshot_initial_profiles([directory], backup_root)
      backups = Dir.glob(File.join(backup_root, "*.backup"))

      assert_equal 1, first.length
      assert_empty second
      assert_equal 1, backups.length
      assert_includes File.basename(backups.first), "--initial--"
      assert_equal original.b, File.binread(backups.first)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_list_backups_returns_only_safe_dated_backup_ids_newest_first
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      older = ClashPatch.create_versioned_backup(profile, backup_root, reason: "initial")
      newer = ClashPatch.create_versioned_backup(profile, backup_root, reason: "prewrite")
      File.write(File.join(backup_root, "not-a-backup.txt"), "ignore")
      File.symlink(older, File.join(backup_root, "2099-01-01_00-00-00.000000000+0000--prewrite--fake--friend.yaml.backup"))

      listed = ClashPatch.list_backups(backup_root)

      assert_equal [File.basename(newer), File.basename(older)].sort.reverse, listed
      assert listed.all? { |name| name.match?(/\A\d{4}-\d{2}-\d{2}_/) }
    end
  end

  def test_backup_compare_and_restore_are_redacted_reversible_and_hash_guarded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)
      backup = ClashPatch.create_versioned_backup(profile, backup_root, content: original, reason: "prewrite")
      changed = base_config
      changed["dns"] = { "nameserver" => ["https://secret.example/dns-query"] }
      changed["rules"] = ["DOMAIN-SUFFIX,private.example,DIRECT", "MATCH,Main"]
      File.write(profile, YAML.dump(changed))

      comparison = ClashPatch.compare_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root
      )
      assert_equal false, comparison.fetch(:same)
      assert comparison.fetch(:changes).any? { |path| path == "dns" || path.start_with?("dns.") }
      assert_includes comparison.fetch(:changes), "rules"
      refute_includes JSON.generate(comparison), "secret.example"
      refute_includes JSON.generate(comparison), "private.example"

      wrong = ClashPatch.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: "0" * 64, validator: ->(_candidate) { true }
      )
      assert_equal :restore_conflict, wrong.fetch(:status)

      current_sha = Digest::SHA256.hexdigest(File.binread(profile))
      restored = ClashPatch.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: current_sha, validator: ->(_candidate) { true }
      )
      assert_equal :updated, restored.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, Dir.glob(File.join(backup_root, "*.backup")).length
      assert Dir.glob(File.join(backup_root, "*--pre-restore--*.backup")).any?

      already_restored = ClashPatch.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(original.b), validator: ->(_candidate) { true }
      )
      assert_equal :no_change, already_restored.fetch(:status)
      assert_equal original.b, already_restored[:rollback_bytes]
      assert_equal Digest::SHA256.hexdigest(original.b), already_restored[:patched_digest]
    end
  end

  def test_subscription_auto_update_state_is_explicit
    assert_equal :disabled, ClashPatch.subscription_auto_update_state("0")
    assert_equal :disabled, ClashPatch.subscription_auto_update_state("false")
    assert_equal :enabled, ClashPatch.subscription_auto_update_state("1")
    assert_equal :enabled, ClashPatch.subscription_auto_update_state("true")
    assert_equal :unknown, ClashPatch.subscription_auto_update_state(nil)
  end

  def test_backup_helpers_tolerate_owned_file_permission_errors_and_cleanup_failed_creates
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(backup_root)
      existing = File.join(backup_root, "existing.backup")
      File.write(existing, "old")
      original_chmod = FileUtils.method(:chmod)
      chmod_with_owned_failure = lambda do |mode, path|
        raise Errno::EPERM if path == existing

        original_chmod.call(mode, path)
      end
      FileUtils.stub(:chmod, chmod_with_owned_failure) do
        assert_equal backup_root, ClashPatch.secure_backup_root!(backup_root)
      end

      source = File.join(directory, "friend.yaml")
      File.write(source, "original")
      chmod_with_new_failure = lambda do |mode, path|
        raise Errno::EPERM if path.end_with?(".backup")

        original_chmod.call(mode, path)
      end
      FileUtils.stub(:chmod, chmod_with_new_failure) do
        assert_raises(Errno::EPERM) do
          ClashPatch.create_versioned_backup(source, backup_root)
        end
      end
      assert_empty Dir.glob(File.join(backup_root, "*--prewrite--*.backup"))
      assert_equal "old", File.read(existing)
    end
  end

  def test_versioned_backup_retries_an_exclusive_name_collision
    Dir.mktmpdir do |directory|
      source = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(source, "original")
      original_open = File.method(:open)
      attempts = 0
      colliding_open = lambda do |path, *arguments, &block|
        if path.to_s.end_with?(".backup")
          attempts += 1
          raise Errno::EEXIST if attempts == 1
        end
        original_open.call(path, *arguments, &block)
      end

      backup = File.stub(:open, colliding_open) do
        ClashPatch.create_versioned_backup(source, backup_root)
      end

      assert_equal 2, attempts
      assert_equal "original", File.read(backup)
    end
  end

  def test_backup_boundaries_reject_unsafe_roots_ids_and_collision_exhaustion
    assert_empty ClashPatch.profile_paths("/path/that/does/not/exist")
    assert_empty ClashPatch.list_backups("/path/that/does/not/exist")
    Dir.mktmpdir do |directory|
      real_root = File.join(directory, "real-backups")
      FileUtils.mkdir_p(real_root)
      linked_root = File.join(directory, "linked-backups")
      File.symlink(real_root, linked_root)
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.secure_backup_root!(linked_root)
      end
      assert_empty ClashPatch.list_backups(linked_root)

      file_root = File.join(directory, "not-a-directory")
      File.write(file_root, "fixture")
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.secure_backup_root!(file_root)
      end

      source = File.join(directory, "friend.yaml")
      File.write(source, "original")
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.create_versioned_backup(source, real_root, reason: "../unsafe")
      end
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.resolve_backup_id("../friend.backup", real_root)
      end

      symlinked_backup = File.join(real_root, "fixture.backup")
      File.symlink(source, symlinked_backup)
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.resolve_backup_id(File.basename(symlinked_backup), real_root)
      end

      attempts = 0
      collision = lambda do |path, *_arguments, &_block|
        if path.to_s.end_with?(".backup")
          attempts += 1
          raise Errno::EEXIST
        end
        raise "unexpected open target"
      end
      File.stub(:open, collision) do
        assert_raises(IOError) do
          ClashPatch.create_versioned_backup(source, real_root)
        end
      end
      assert_equal 100, attempts
      assert_empty Dir.glob(File.join(real_root, "*--prewrite--*.backup"))
    end
  end

  def test_restore_backup_rejects_invalid_bytes_validation_failures_and_commit_conflicts
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      changed = YAML.dump(base_config.merge("subscription-marker" => "changed"))
      File.write(profile, changed)
      valid_backup = ClashPatch.create_versioned_backup(
        profile, backup_root, content: original, reason: "prewrite"
      )
      expected_hash = Digest::SHA256.hexdigest(changed.b)

      timeout = ClashPatch.restore_backup(
        File.basename(valid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { :timeout }
      )
      assert_equal :validation_timeout, timeout.fetch(:status)
      assert_equal changed.b, File.binread(profile)

      rejected = ClashPatch.restore_backup(
        File.basename(valid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { false }
      )
      assert_equal :validation_failed, rejected.fetch(:status)
      assert_equal changed.b, File.binread(profile)

      ClashPatch.stub(:atomic_compare_and_swap_bytes, false) do
        conflict = ClashPatch.restore_backup(
          File.basename(valid_backup), directories: [directory], backup_root: backup_root,
          expected_current_sha256: expected_hash, validator: ->(_path) { true }
        )
        assert_equal :restore_conflict, conflict.fetch(:status)
      end
      assert_equal changed.b, File.binread(profile)

      invalid_backup = ClashPatch.create_versioned_backup(
        profile, backup_root, content: "\xFF".b, reason: "prewrite"
      )
      invalid = ClashPatch.restore_backup(
        File.basename(invalid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { true }
      )
      assert_equal :invalid_backup, invalid.fetch(:status)
      assert_equal changed.b, File.binread(profile)
    end
  end

  def test_restore_backup_classifies_invalid_and_io_failures
    ClashPatch.stub(:resolve_backup_id, ->(*_args) { raise ClashPatch::InvalidConfigError }) do
      result = ClashPatch.restore_backup(
        "bad.backup", directories: [], backup_root: Dir.tmpdir,
        expected_current_sha256: "0" * 64, validator: ->(_path) { true }
      )
      assert_equal :invalid_backup, result.fetch(:status)
    end
    ClashPatch.stub(:resolve_backup_id, ->(*_args) { raise IOError }) do
      result = ClashPatch.restore_backup(
        "bad.backup", directories: [], backup_root: Dir.tmpdir,
        expected_current_sha256: "0" * 64, validator: ->(_path) { true }
      )
      assert_equal :io_error, result.fetch(:status)
    end
  end

  def test_disables_subscription_auto_update_through_defaults_and_verifies_it
    Dir.mktmpdir do |directory|
      calls = []
      values = ["1", "1", "0"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :disabled, result.fetch(:status)
      assert_equal "com.metacubex.ClashX.meta", result.fetch(:domain)
      assert_includes calls, [
        "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
        "kAutoUpdateEnable", "-bool", "false"
      ]
      backups = Dir.glob(File.join(directory, "*--preference--*.json.backup"))
      assert_equal 1, backups.length
      assert_equal 0, File.stat(backups.first).mode & 0o077
      backup = JSON.parse(File.read(backups.first))
      assert_equal "kAutoUpdateEnable", backup.fetch("Key")
      assert_equal "1", backup.fetch("Value")
      refute_includes File.read(backups.first), "kRemoteConfigs"
      state = JSON.parse(File.read(File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")))
      assert_equal(
        {
          "Version" => 2,
          "Domain" => "com.metacubex.ClashX.meta",
          "Key" => "kAutoUpdateEnable",
          "OriginalValue" => "1",
          "Phase" => "installed"
        },
        state
      )
    end
  end

  def test_auto_update_disable_is_idempotent_and_does_not_create_backup_when_already_off
    Dir.mktmpdir do |directory|
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["0", "", Struct.new(:success?).new(true)]
        else
          flunk("automatic update was already disabled but tried to write: #{arguments.inspect}")
        end
      end

      result = ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :already_disabled, result.fetch(:status)
      assert_empty Dir.glob(File.join(directory, "*.backup"))
      refute File.exist?(File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json"))
    end
  end

  def test_auto_update_disable_recovers_a_prepared_operation_before_retrying
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 2,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalValue" => "1",
        "Phase" => "prepared"
      ))
      values = %w[0 0 1 1 1 0]
      writes = []
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          writes << arguments.last
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :disabled, result.fetch(:status)
      assert_equal %w[true false], writes
      assert_empty values
      state = JSON.parse(File.read(state_path))
      assert_equal "installed", state.fetch("Phase")
    end
  end

  def test_auto_update_disable_rejects_a_change_before_the_preference_write
    Dir.mktmpdir do |directory|
      values = %w[1 0]
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("changed preference reached a write: #{arguments.inspect}")
        end
      end

      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)
      end
      refute File.exist?(File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json"))
      assert_empty values
    end
  end

  def test_auto_update_helpers_fail_closed_on_malformed_state_and_runner_errors
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.binwrite(state_path, "\xFF".b)
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.auto_update_ownership_state(directory)
      end
    end

    failing_runner = ->(*_arguments, **_options) { raise IOError, "injected runner failure" }
    assert_nil ClashPatch.defaults_export_domain(runner: failing_runner)
    assert_nil ClashPatch.defaults_export_named_domain("com.metacubex.ClashX.meta", runner: failing_runner)
    assert_equal "", ClashPatch.plist_raw_value("plist", "key", runner: failing_runner)
  end

  def test_stale_auto_update_ownership_cannot_be_deleted
    Dir.mktmpdir do |directory|
      ownership = ClashPatch.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      path = ownership.fetch("Path")
      File.write(path, JSON.generate(
        "Version" => 2,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalValue" => "different",
        "Phase" => "prepared"
      ))

      assert_raises(IOError) { ClashPatch.delete_auto_update_ownership_state(ownership) }
      assert File.file?(path)
      assert_includes File.read(path), "different"
    end
  end

  def test_installed_auto_update_ownership_is_idempotent
    Dir.mktmpdir do |directory|
      ClashPatch.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "installed"
      )
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["0", "", Struct.new(:success?).new(true)]
        else
          flunk("idempotent disable tried to write: #{arguments.inspect}")
        end
      end

      result = ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :already_disabled, result.fetch(:status)
    end
  end

  def test_auto_update_disable_compensation_reports_each_failure_stage
    status = Struct.new(:success?)
    run_case = lambda do |values, write_success:, installed_state_failure:, restore_failure:, &assertion|
      Dir.mktmpdir do |directory|
        runner = lambda do |*arguments, **_options|
          if arguments[1] == "export"
            ["plist", "", status.new(true)]
          elsif arguments[1] == "write"
            ["", "injected defaults failure", status.new(write_success)]
          elsif arguments[0] == "/usr/bin/plutil"
            [values.shift, "", status.new(true)]
          else
            flunk("unexpected command: #{arguments.inspect}")
          end
        end
        restore = restore_failure ? ->(**_args) { raise IOError, "injected restore failure" } : { status: :enabled }
        original_writer = ClashPatch.method(:write_auto_update_ownership_state)
        state_writer = lambda do |root, domain, original, phase, existing: nil|
          raise IOError, "injected installed-state failure" if installed_state_failure && phase == "installed"

          original_writer.call(root, domain, original, phase, existing: existing)
        end
        ClashPatch.stub(:enable_subscription_auto_update, restore) do
          ClashPatch.stub(:write_auto_update_ownership_state, state_writer) do
            assertion.call(directory, runner)
          end
        end
      end
    end

    [
      [%w[1 1], false, false, false, "无法关闭 ClashX Meta"],
      [%w[1 1], false, false, true, "恢复原值失败"],
      [%w[1 1 1], true, false, false, "回读失败，已经恢复原值"],
      [%w[1 1 1], true, false, true, "回读失败，且恢复原值失败"],
      [%w[1 1 0], true, true, false, "无法记录订阅自动更新所有权，已经恢复原值"],
      [%w[1 1 0], true, true, true, "无法记录订阅自动更新所有权，且恢复原值失败"]
    ].each do |values, write_success, state_failure, restore_failure, message|
      run_case.call(
        values, write_success: write_success,
        installed_state_failure: state_failure, restore_failure: restore_failure
      ) do |directory, runner|
        error = assert_raises(IOError) do
          ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)
        end
        assert_includes error.message, message
      end
    end
  end

  def test_owned_auto_update_restore_rejects_an_unknown_live_value
    Dir.mktmpdir do |directory|
      ClashPatch.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "installed"
      )
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["mystery", "", Struct.new(:success?).new(true)]
        else
          flunk("unknown value reached a write: #{arguments.inspect}")
        end
      end

      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)
      end
    end
  end

  def test_restores_only_owned_subscription_auto_update_state
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 1,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalState" => "enabled",
        "InstalledState" => "disabled"
      ))
      calls = []
      values = ["0", "1"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClashPatch.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :restored, result.fetch(:status)
      assert_includes calls, [
        "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
        "kAutoUpdateEnable", "-bool", "true"
      ]
      refute File.exist?(state_path)
    end
  end

  def test_owned_auto_update_restore_accepts_a_user_already_restored_value
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 1,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalState" => "enabled",
        "InstalledState" => "disabled"
      ))
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["1", "", Struct.new(:success?).new(true)]
        else
          flunk("already restored preference was overwritten: #{arguments.inspect}")
        end
      end

      result = ClashPatch.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :already_restored, result.fetch(:status)
      refute File.exist?(state_path)
    end
  end

  def test_owned_auto_update_restore_does_nothing_without_an_ownership_state
    Dir.mktmpdir do |directory|
      result = ClashPatch.restore_owned_subscription_auto_update(
        backup_root: directory,
        runner: ->(*arguments, **_options) { flunk("unexpected preference access: #{arguments.inspect}") }
      )

      assert_equal :not_owned, result.fetch(:status)
    end
  end

  def test_owned_auto_update_restore_rejects_an_invalid_state_before_reading_preferences
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, '{"Version":1,"Domain":"attacker.invalid","Key":"kAutoUpdateEnable"}')

      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.restore_owned_subscription_auto_update(
          backup_root: directory,
          runner: ->(*arguments, **_options) { flunk("invalid state reached preferences: #{arguments.inspect}") }
        )
      end
      assert File.file?(state_path)
    end
  end

  def test_auto_update_disable_restores_the_preference_when_ownership_state_cannot_be_recorded
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, '{"Version":1,"Domain":"attacker.invalid"}')
      calls = []
      values = ["1", "0", "0", "1"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.disable_subscription_auto_update(backup_root: directory, runner: runner)
      end
      refute calls.any? { |arguments| arguments[1] == "write" }
      assert File.file?(state_path)
    end
  end

  def test_enables_subscription_auto_update_and_verifies_the_result
    calls = []
    values = ["0", "1"]
    runner = lambda do |*arguments, **_options|
      calls << arguments
      if arguments[1] == "export"
        ["plist", "", Struct.new(:success?).new(true)]
      elsif arguments[1] == "write"
        ["", "", Struct.new(:success?).new(true)]
      elsif arguments[0] == "/usr/bin/plutil"
        [values.shift, "", Struct.new(:success?).new(true)]
      else
        flunk("unexpected command: #{arguments.inspect}")
      end
    end

    result = ClashPatch.enable_subscription_auto_update(runner: runner)

    assert_equal :enabled, result.fetch(:status)
    assert_includes calls, [
      "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
      "kAutoUpdateEnable", "-bool", "true"
    ]
  end

  def test_remote_subscription_records_map_every_client_entry_without_exposing_urls
    Dir.mktmpdir do |directory|
      %w[MESL Yue Express].each { |name| File.write(File.join(directory, "#{name}.yaml"), YAML.dump(base_config)) }
      records = %w[MESL Yue Express].map.with_index do |name, index|
        { "name" => name, "url" => "https://subscriptions.invalid/private-#{index}", "updateTime" => 100 + index }
      end
      raw = Base64.strict_encode64(JSON.generate(records))

      parsed = ClashPatch.remote_subscription_records(raw)
      targets = ClashPatch.remote_subscription_targets([directory], parsed)

      assert_equal 3, targets.length
      assert_equal %w[Express MESL Yue], targets.map { |target| File.basename(target.fetch(:path), ".yaml") }.sort
      refute_includes JSON.generate(targets.map { |target| target.reject { |key, _value| key == :url } }), "subscriptions.invalid"
    end
  end

  def test_remote_subscription_and_identity_helpers_fail_closed_on_bad_inputs
    assert_raises(ClashPatch::InvalidConfigError) do
      ClashPatch.remote_subscription_records("not-base64")
    end
    assert_raises(ClashPatch::InvalidConfigError) do
      ClashPatch.fetch_remote_subscription({})
    end

    missing = File.join(Dir.tmpdir, "missing-clash-patch-subscription")
    handle = Object.new
    handle.define_singleton_method(:stat) { raise IOError }
    refute ClashPatch.locked_profile_current?(handle, missing)
    refute ClashPatch.safe_update_item_committed?(
      path: missing, write_path: missing, committed_identity: [1, 1], candidate: "candidate"
    )
    assert_equal ["friend"], ClashPatch.rollback_safe_update_items([
      {
        name: "friend", path: missing, original: "old", candidate: "new",
        committed_identity: [1, 1], write_path: missing
      }
    ])
  end

  def test_remote_subscription_url_is_passed_to_curl_over_stdin_not_process_arguments
    url = "https://subscriptions.invalid/private-token"
    status = Struct.new(:success?).new(true)
    capture = lambda do |*arguments, **options|
      refute arguments.join(" ").include?(url)
      assert_includes options.fetch(:stdin_data), url
      [YAML.dump(base_config), "", status]
    end

    body = Open3.stub(:capture3, capture) do
      ClashPatch.fetch_remote_subscription({ name: "private", url: url })
    end

    assert_includes body, "proxy-groups"
  end

  def test_safe_update_all_is_transactional_and_reapplies_profile_three_patch
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[MESL Yue Express].map.with_index do |name, index|
        path = File.join(directory, "#{name}.yaml")
        source = base_config
        source["subscription-marker"] = "old-#{index}"
        File.write(path, YAML.dump(source))
        { name: name, path: path, url: "https://subscriptions.invalid/#{index}" }
      end
      fetcher = lambda do |target|
        source = base_config
        source["subscription-marker"] = "new-#{target.fetch(:name)}"
        YAML.dump(source)
      end
      activated = false

      result = ClashPatch.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { activated = true; true }
      )

      assert_equal :updated, result.fetch(:status)
      assert_equal 3, result.fetch(:count)
      assert activated
      targets.each do |target|
        config = ClashPatch.load_yaml(File.read(target.fetch(:path)))
        assert_equal "new-#{target.fetch(:name)}", config.fetch("subscription-marker")
        assert_equal false, config.fetch("ipv6")
        assert_equal true, config.dig("tun", "enable")
      end
      assert_equal 3, Dir.glob(File.join(backup_root, "*--pre-update--*.backup")).length
    end
  end

  def test_safe_update_all_preserves_an_atomic_refresh_during_backup
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "external-refresh"))
      original_backup = ClashPatch.method(:create_versioned_backup)
      backup_calls = 0
      backup_with_refresh = lambda do |path, root, content: nil, reason: "prewrite"|
        result = original_backup.call(path, root, content: content, reason: reason)
        backup_calls += 1
        if backup_calls == 2
          replacement = File.join(directory, "replacement.yaml")
          File.binwrite(replacement, refreshed)
          File.rename(replacement, targets.fetch(1).fetch(:path))
        end
        result
      end

      result = ClashPatch.stub(:create_versioned_backup, backup_with_refresh) do
        ClashPatch.safe_update_all(
          targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
          fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
          validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" }
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal originals.fetch(targets.fetch(0).fetch(:path)), File.binread(targets.fetch(0).fetch(:path))
      assert_equal refreshed.b, File.binread(targets.fetch(1).fetch(:path))
    end
  end

  def test_safe_update_all_restores_every_profile_when_a_later_write_fails
    Dir.mktmpdir do |directory|
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      original_swap = ClashPatch.method(:atomic_swap_paths)
      swaps = 0
      failing_swap = lambda do |first, second|
        swaps += 1
        raise IOError, "injected second commit failure" if swaps == 2

        original_swap.call(first, second)
      end

      result = ClashPatch.stub(:atomic_swap_paths, failing_swap) do
        ClashPatch.safe_update_all(
          targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
          fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
          validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" }
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :write_failed, result.fetch(:reason)
      assert_operator swaps, :>=, 3
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
    end
  end

  def test_safe_update_all_leaves_every_profile_untouched_when_one_download_is_invalid
    Dir.mktmpdir do |directory|
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      fetcher = lambda do |target|
        target.fetch(:name) == "second" ? "<html>expired</html>" : YAML.dump(base_config)
      end

      result = ClashPatch.safe_update_all(
        targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" }
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal "second", result.fetch(:failed_profile)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
      refute Dir.exist?(File.join(directory, "backups"))
      refute_includes JSON.generate(result), "subscriptions.invalid"
    end
  end

  def test_safe_update_all_does_not_add_profile_three_patch_to_lightweight_profiles
    Dir.mktmpdir do |directory|
      path = File.join(directory, "ordinary.yaml")
      File.write(path, YAML.dump(base_config))
      downloaded = base_config.merge("subscription-marker" => "fresh")

      result = ClashPatch.safe_update_all(
        targets: [{ name: "ordinary", path: path, url: "https://subscriptions.invalid/ordinary" }],
        policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 2,
        fetcher: ->(_target) { YAML.dump(downloaded) }, validator: ->(_path) { true },
        activation: ->(_items) { true }
      )

      assert_equal :updated, result.fetch(:status)
      config = ClashPatch.load_yaml(File.read(path))
      assert_equal "fresh", config.fetch("subscription-marker")
      refute config.key?("tun")
      refute config.key?("ipv6")
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      assert config.fetch("rule-providers").key?(provider_name)
      assert_includes config.fetch("rules"), "RULE-SET,#{provider_name},DIRECT"
      assert_equal @policy.fetch("direct_resolvers"),
                   config.dig("dns", "nameserver-policy", "rule-set:#{provider_name}")
    end
  end

  def test_safe_update_all_rolls_back_every_profile_when_runtime_activation_fails
    Dir.mktmpdir do |directory|
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.map { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }.to_h

      result = ClashPatch.safe_update_all(
        targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
        validator: ->(_path) { true }, activation: ->(_items) { raise "controller failed" }
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
    end
  end

  def test_default_safe_update_activation_preserves_runtime_recovery_status
    item = {
      path: "/profiles/friend.yaml", original: "original", candidate: "candidate"
    }
    activation_result = {
      path: item.fetch(:path), status: :reload_failed_restore_pending
    }

    ClashPatch.stub(:active_profile?, true) do
      ClashPatch.stub(:activate_updated_profile, activation_result) do
        result = ClashPatch.default_safe_update_activation([item], 3, "friend")

        assert_equal activation_result, result
      end
    end
  end

  def test_safe_update_reports_when_files_are_restored_but_runtime_is_not
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(profile, original)
      target = { name: "friend", path: profile, url: "https://subscriptions.invalid/friend" }

      result = ClashPatch.safe_update_all(
        targets: [target], policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_path) { true },
        activation: ->(_items) { { status: :reload_failed_restore_pending } }
      )

      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :reload_failed_restore_pending, result.fetch(:runtime_status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_safe_update_tries_to_restore_every_profile_when_one_rollback_conflicts
    Dir.mktmpdir do |directory|
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      restore = lambda do |path, bytes, **_options|
        next false if File.basename(path) == "second.yaml"

        File.binwrite(path, bytes)
        true
      end

      result = ClashPatch.stub(:replace_profile_bytes, restore) do
        ClashPatch.safe_update_all(
          targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
          fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
          validator: ->(_path) { true }, activation: ->(_items) { false }
        )
      end

      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal originals.fetch(targets[0].fetch(:path)), File.binread(targets[0].fetch(:path))
      assert_equal originals.fetch(targets[2].fetch(:path)), File.binread(targets[2].fetch(:path))
      refute_equal originals.fetch(targets[1].fetch(:path)), File.binread(targets[1].fetch(:path))
    end
  end

  def test_safe_update_reports_lock_time_identity_and_rollback_failures
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }
      arguments = {
        targets: [target],
        policy: @policy,
        backup_root: File.join(directory, "backups"),
        usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_candidate) { true },
        activation: ->(_items) { true }
      }

      ClashPatch.stub(:locked_profile_current?, false) do
        result = ClashPatch.safe_update_all(**arguments)
        assert_equal :aborted, result.fetch(:status)
        assert_equal :concurrent_change, result.fetch(:reason)
      end

      File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      original_swap = ClashPatch.method(:atomic_swap_paths)
      failing_swap = lambda do |first, second|
        raise IOError, "injected commit failure" if File.basename(first).start_with?(".clash-patch-update-swap-")

        original_swap.call(first, second)
      end
      ClashPatch.stub(:atomic_swap_paths, failing_swap) do
        ClashPatch.stub(:rollback_safe_update_items, ["friend"]) do
          result = ClashPatch.safe_update_all(**arguments)
          assert_equal :rollback_failed, result.fetch(:status)
          assert_equal :write_failed, result.fetch(:reason)
          assert_equal "friend", result.fetch(:failed_profile)
        end
      end
    end
  end

  def test_safe_update_post_commit_verification_rolls_back_before_reporting
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }

      ClashPatch.stub(:safe_update_item_committed?, false) do
        result = ClashPatch.safe_update_all(
          targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 3,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_candidate) { true }, activation: ->(_items) { flunk "must not activate" }
        )
        assert_equal :aborted, result.fetch(:status)
        assert_equal :concurrent_change, result.fetch(:reason)
        assert_equal original.b, File.binread(path)
      end
    end
  end

  def test_safe_update_distinguishes_invalid_requests_from_unexpected_setup_failures
    assert_raises(ClashPatch::InvalidConfigError) do
      ClashPatch.safe_update_all(
        targets: [], policy: @policy, backup_root: Dir.tmpdir, usage_profile: 0
      )
    end

    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }
      ClashPatch.stub(:build_update_candidate, YAML.dump(base_config)) do
        File.stub(:stat, ->(_candidate) { raise IOError, "injected identity failure" }) do
          result = ClashPatch.safe_update_all(
            targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
            usage_profile: 3, fetcher: ->(_target) { YAML.dump(base_config) },
            validator: ->(_candidate) { true }
          )
          assert_equal :aborted, result.fetch(:status)
          assert_equal :unexpected_error, result.fetch(:reason)
        end
      end
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
      original_backup = ClashPatch.method(:create_versioned_backup)
      injected = false
      backup_with_refresh = lambda do |path, root, content: nil, reason: "prewrite"|
        result = original_backup.call(path, root, content: content, reason: reason)
        next if injected

        injected = true
        File.write(profile, YAML.dump(refreshed))
        result
      end

      result = ClashPatch.stub(:create_versioned_backup, backup_with_refresh) do
        ClashPatch.patch_path(profile, @policy, backup_root: backup_root, validator: ->(_candidate) { true })
      end
      written = ClashPatch.load_yaml(File.read(profile))

      assert_equal :updated, result.fetch(:status)
      assert_equal "refresh-during-backup", written.fetch("friend-marker")
      assert_equal false, written.fetch("ipv6")
    end
  end

  def test_atomic_refresh_after_final_identity_check_is_not_overwritten
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      refreshed_path = File.join(directory, "refreshed.yaml")
      File.write(profile, YAML.dump(base_config))
      refreshed = base_config
      refreshed["friend-marker"] = "latest atomic refresh"
      File.write(refreshed_path, YAML.dump(refreshed))
      original_check = ClashPatch.method(:locked_source_current?)
      checks = 0
      checker = lambda do |source, logical_path, write_path|
        checks += 1
        if checks == 2
          File.rename(refreshed_path, write_path)
          true
        else
          original_check.call(source, logical_path, write_path)
        end
      end

      result = ClashPatch.stub(:locked_source_current?, checker) do
        ClashPatch.patch_path(profile, @policy)
      end
      written = ClashPatch.load_yaml(File.read(profile))

      assert_equal :updated, result.fetch(:status)
      assert_equal "latest atomic refresh", written.fetch("friend-marker")
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

  def test_deep_yaml_aborts_the_batch_before_other_profiles_are_written
    Dir.mktmpdir do |directory|
      deep_path = File.join(directory, "deep.yaml")
      good_path = File.join(directory, "good.yaml")
      depth = 1_600
      lines = (0...depth).map { |index| "#{'  ' * index}level#{index}:" }
      lines << "#{'  ' * depth}leaf: value"
      File.write(deep_path, lines.join("\n") + "\n")
      good_original = YAML.dump(base_config)
      File.write(good_path, good_original)

      results = ClashPatch.run(directories: [directory], policy_path: POLICY_PATH,
                               selected_name: "good")
      by_name = results.each_with_object({}) { |result, memo| memo[File.basename(result.fetch(:path))] = result }

      assert_includes %i[invalid error], by_name.fetch("deep.yaml").fetch(:status)
      assert_equal :batch_aborted, by_name.fetch("good.yaml").fetch(:status)
      assert_equal good_original, File.read(good_path)
    end
  end

  def test_shared_main_group_fixtures
    shared = JSON.parse(File.read(MAIN_GROUP_FIXTURES))
    assert_equal 1, shared.fetch("schema_version")
    fixtures = shared.fetch("cases")
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

  def test_shared_full_transform_fixtures
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("transform_cases")
    fixtures.each do |fixture|
      input = fixture.fetch("input")
      snapshot = JSON.parse(JSON.generate(input))
      result = ClashPatch.patch(input, @policy)

      assert_equal fixture.fetch("expected_changed"), result.fetch(:changed), fixture.fetch("name")
      expected_main = fixture.fetch("expected_main_group")
      expected_ai = fixture.fetch("expected_ai_group")
      expected_main.nil? ? assert_nil(result.fetch(:main_group), fixture.fetch("name")) :
        assert_equal(expected_main, result.fetch(:main_group), fixture.fetch("name"))
      expected_ai.nil? ? assert_nil(result.fetch(:ai_group), fixture.fetch("name")) :
        assert_equal(expected_ai, result.fetch(:ai_group), fixture.fetch("name"))
      assert_equal fixture.fetch("expected_status").to_sym, result.fetch(:status), fixture.fetch("name")
      assert_equal snapshot, input, "#{fixture.fetch('name')}: input mutated"
      serialized = JSON.generate(result.fetch(:config))
      assert_equal fixture.fetch("expected_config_sha256"), Digest::SHA256.hexdigest(serialized), "#{fixture.fetch('name')}: output drift"
      Array(fixture["expected_absent_strings"]).each do |value|
        refute_includes serialized, value, "#{fixture.fetch('name')}: retained #{value}"
      end
      Array(fixture["expected_present_strings"]).each do |value|
        assert_includes serialized, value, "#{fixture.fetch('name')}: missing #{value}"
      end

      next unless fixture.fetch("expected_changed")

      second = ClashPatch.patch(result.fetch(:config), @policy)
      assert_equal result.fetch(:config), second.fetch(:config), "#{fixture.fetch('name')}: second pass"
      refute second.fetch(:changed), "#{fixture.fetch('name')}: second pass changed"
      assert_equal :unchanged, second.fetch(:status), "#{fixture.fetch('name')}: second pass status"
    end
  end

  def test_shared_full_transform_fixtures_match_windows_exactly
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("transform_cases")
    inputs = fixtures.map { |fixture| fixture.fetch("input") }
    engine_path = File.join(ROOT, "clash-patch/scripts/windows/clash_verge_global.js")
    javascript = <<~'JS'
      const fs = require('node:fs');
      const engine = require(process.argv[1]);
      const inputs = JSON.parse(fs.readFileSync(0, 'utf8'));
      process.stdout.write(JSON.stringify(inputs.map((input) => engine.clashPatchTransform(input, 'fixture'))));
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, engine_path, stdin_data: JSON.generate(inputs))
    assert status.success?, stderr
    windows = JSON.parse(stdout)

    fixtures.each_with_index do |fixture, index|
      ruby = ClashPatch.patch(fixture.fetch("input"), @policy).fetch(:config)
      assert_equal ruby, windows.fetch(index), fixture.fetch("name")
      assert_equal fixture.fetch("expected_config_sha256"), Digest::SHA256.hexdigest(JSON.generate(windows.fetch(index))), "#{fixture.fetch('name')}: Windows output drift"
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
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:ai_group)}"
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
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:ai_group)}"
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
      assert_equal 2, Dir.glob(File.join(backup, "*.backup")).length
      assert_equal 1, Dir.glob(File.join(backup, "*--prewrite--*.backup")).length
    end
  end

  def test_dry_run_reports_preview_without_writing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.write(profile, original)

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, dry_run: true,
                               backup_root: File.join(directory, "backups"), selected_name: "friend")
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
    result = ClashPatch.patch(config, @policy)
    policy_out = result.fetch(:config).dig("dns", "nameserver-policy")

    refute policy_out.key?("+.example.com,+.example.org")
    route_group = result.fetch(:route_group)
    assert policy_out.fetch("+.example.com").all? { |value| value.end_with?("##{route_group}") }
    assert policy_out.fetch("+.example.org").all? { |value| value.end_with?("##{route_group}") }
    assert policy_out.fetch("+.keep.example").all? { |value| value.end_with?("##{route_group}") }
  end

  def test_chinese_status_covers_all_update_states
    base = { path: "/profiles/friend.yaml", status: :updated, ai_group: "AI" }

    assert_includes ClashPatch.chinese_status(base.merge(active: true, reloaded: true)), "已更新并自动生效"
    assert_includes ClashPatch.chinese_status(base.merge(active: false)), "已更新，选择该订阅时生效"
    assert_includes ClashPatch.chinese_status(base.merge(status: :reload_failed_rolled_back)), "自动刷新失败，已恢复原配置"
    assert_includes ClashPatch.chinese_status(base.merge(status: :unchanged)), "无需修改"
  end

  def test_run_automatically_reloads_and_checks_the_active_profile
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      File.write(File.join(directory, "other.yaml"), YAML.dump(base_config))

      requests = []
      proxy_body = JSON.generate("proxies" => {
        "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
        "AI" => { "type" => "Selector", "now" => "台湾家宽 01" }
      })
      requester = lambda do |method, endpoint, body|
        requests << [method, endpoint, body]
        case [method, endpoint]
        when ["GET", "/proxies"] then [200, proxy_body]
        when ["PUT", "/configs?force=true"] then [204, ""]
        when ["POST", "/cache/fakeip/flush"] then [204, ""]
        when ["POST", "/cache/dns/flush"] then [204, ""]
        when ["GET", "/configs"] then [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      results = ClashPatch.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               selected_name: "friend", auto_reload: true, requester: requester,
                               connectivity_checker: -> { true })
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      inactive = results.find { |entry| File.basename(entry[:path]) == "other.yaml" }
      assert_equal true, active.fetch(:reloaded)
      assert_includes ClashPatch.chinese_status(active), "已更新并自动生效"
      assert_includes ClashPatch.chinese_status(inactive), "已更新，选择该订阅时生效"
      assert requests.any? { |method, endpoint, _body| method == "PUT" && endpoint == "/configs?force=true" }
      assert requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/fakeip/flush" }
      assert requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/dns/flush" }
    end
  end

  def test_runtime_selection_guard_ignores_automatic_url_test_groups
    requester = lambda do |_method, _endpoint, _body|
      [200, JSON.generate("proxies" => {
        "Main" => { "type" => "Selector", "now" => "Singapore" },
        "Automatic" => { "type" => "URLTest", "now" => "Japan" }
      })]
    end

    assert_equal({ "Main" => "Singapore" }, ClashPatch.runtime_selections(requester))
  end

  def test_route_verifier_rejects_direct_hidden_below_ai_selector
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Nested" }
      } }
      observations = [
        { "chains" => ["Taiwan", "Main"] },
        { "chains" => ["DIRECT", "Nested", "AI"] },
        { "chains" => ["DIRECT", "Nested", "AI"] },
        { "chains" => ["DIRECT", "Nested", "AI"] }
      ]

      ClashPatch.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, proxies) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args) { observations.shift }) do
              refute ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
    end
  end

  def test_route_verifier_force_reaps_a_curl_process_that_ignores_term
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", 'trap("TERM") {}; STDOUT.puts("ready"); STDOUT.flush; sleep 30', out: writer)
    writer.close
    assert_equal "ready\n", reader.gets
    reader.close
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ClashRouteVerifier.terminate_process(pid, grace_seconds: 0.05)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.waitpid(pid) rescue nil
  end

  def test_active_reload_fails_when_an_existing_selector_disappears
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      proxy_reads = 0
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          proxy_reads += 1
          body = proxy_reads == 2 ? {} : { "Main" => { "type" => "Selector", "now" => "Taiwan" } }
          [200, JSON.generate("proxies" => body)]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      result = ClashPatch.activate_updated_profile(
        { path: profile, rollback_bytes: original.b, patched_digest: Digest::SHA256.hexdigest(candidate.b) },
        requester: requester, connectivity_checker: -> { true }
      )

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_restore_activation_preserves_the_existing_tun_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      proxy_body = JSON.generate(
        "proxies" => { "Main" => { "type" => "Selector", "now" => "Taiwan" } }
      )
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, proxy_body]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      result = ClashPatch.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: :preserve
      )

      assert_equal true, result[:reloaded]
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_failed_active_reload_restores_the_exact_original_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      requester = lambda do |method, endpoint, _body|
        if method == "GET" && endpoint == "/proxies"
          [200, JSON.generate("proxies" => { "Main" => { "type" => "Selector", "now" => "台湾家宽 01" } })]
        elsif method == "PUT" && endpoint == "/configs?force=true"
          [401, ""]
        else
          [404, ""]
        end
      end

      result = ClashPatch.run(
        directory: directory,
        policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"),
        selected_name: "friend",
        auto_reload: true,
        requester: requester,
        connectivity_checker: -> { true }
      ).first

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_includes ClashPatch.chinese_status(result), "运行内核恢复失败"
    end
  end

  def test_runtime_health_failure_reloads_the_restored_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      reload_bodies = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => { "Main" => { "type" => "Selector", "now" => "台湾家宽 01" } })]
        when ["PUT", "/configs?force=true"]
          reload_bodies << body
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        else
          [404, ""]
        end
      end

      result = ClashPatch.run(
        directory: directory,
        policy_path: POLICY_PATH,
        selected_name: "friend",
        auto_reload: true,
        requester: requester,
        connectivity_checker: -> { true }
      ).first

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, reload_bodies.length
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
                               selected_name: "friend")
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
      ai_group: "node\e]0;owned\a password=secret-value 11111111-2222-3333-4444-555555555555"
    }

    output = ClashPatch.chinese_status(result)

    refute_includes output, "\e"
    refute_includes output, "\a"
    refute_includes output, "11111111-2222-3333-4444-555555555555"
    refute_includes output, "secret-value"
  end

  def test_safe_labels_hide_absolute_paths
    output = ClashPatch.safe_label("failed at /Users/private/Clash/config.yaml and C:\\Users\\private\\Clash\\config.yaml")

    refute_includes output, "/Users/private"
    refute_includes output, "C:\\Users\\private"
    assert_includes output, "[路径已隐藏]"
  end

  def test_safe_labels_hide_all_proxy_uri_schemes
    output = ClashPatch.safe_label("ss://secret@example trojan://password@example vless://uuid@example")

    refute_includes output, "secret"
    refute_includes output, "password"
    refute_includes output, "uuid"
    assert_equal 3, output.scan("[已隐藏]").length
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

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#台湾家宽 01" }, policies.fetch("+.proxy.example")
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#SafeExisting" }, policies.fetch("+.group.example")
    %w[+.direct.example +.option.example +.interface.example].each do |pattern|
      assert policies.fetch(pattern).all? { |value| value.end_with?("##{result.fetch(:route_group)}") }, pattern
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
    safe_suffix = "##{result.fetch(:route_group)}"

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#台湾家宽 01" }, policies.fetch("+.encrypted.example")
    %w[+.plaintext.example +.provider.example +.include-all.example].each do |pattern|
      assert policies.fetch(pattern).all? { |endpoint| endpoint.end_with?(safe_suffix) }, pattern
    end
  end

  def test_dns_policy_accounts_for_exclusion_empty_fallback_and_dns_outbounds
    config = base_config
    original_main = Marshal.load(Marshal.dump(config.fetch("proxy-groups").find { |group| group["name"] == "Main" }))
    config["proxies"] << { "name" => "InternalDNS", "type" => "dns" }
    config["proxy-groups"].push(
      {
        "name" => "FilteredToCompatible", "type" => "select", "proxies" => ["台湾家宽 01"],
        "exclude-filter" => "台湾"
      },
      {
        "name" => "FilteredToSafeProxy", "type" => "select", "proxies" => ["台湾家宽 01"],
        "exclude-filter" => "台湾", "empty-fallback" => "日本家宽 01"
      },
      { "name" => "DnsOutboundGroup", "type" => "select", "proxies" => ["InternalDNS"] }
    )
    config["dns"]["nameserver-policy"] = {
      "+.compatible.example" => ["https://1.1.1.1/dns-query#FilteredToCompatible"],
      "+.fallback.example" => ["https://1.1.1.1/dns-query#FilteredToSafeProxy"],
      "+.dns-out.example" => ["https://1.1.1.1/dns-query#DnsOutboundGroup"]
    }

    result = ClashPatch.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"
    main_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:route_group) }

    assert policies.fetch("+.compatible.example").all? { |endpoint| endpoint.end_with?(safe_suffix) }
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#FilteredToSafeProxy" }, policies.fetch("+.fallback.example")
    assert policies.fetch("+.dns-out.example").all? { |endpoint| endpoint.end_with?(safe_suffix) }
    assert_equal original_main, main_group
  end

  def test_dns_policy_rejects_privacy_weakening_resolver_options
    config = base_config
    target = "台湾家宽 01"
    config["dns"]["nameserver-policy"] = {
      "+.h3.example" => ["https://1.1.1.1/dns-query##{target}&h3=true"],
      "+.skip-cert.example" => ["https://1.1.1.1/dns-query##{target}&skip-cert-verify=true"],
      "+.ecs.example" => ["https://1.1.1.1/dns-query##{target}&ecs=203.0.113.0/24&ecs-override=true"]
    }

    result = ClashPatch.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}##{target}&h3=true" }, policies.fetch("+.h3.example")
    %w[+.skip-cert.example +.ecs.example].each do |pattern|
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
      endpoint.end_with?("##{result.fetch(:route_group)}")
    end
  end

  def test_direct_and_rematch_home_names_are_not_selected_automatically
    config = base_config
    config["proxies"].unshift(
      { "name" => "台湾家宽 DIRECT", "type" => "direct" },
      { "name" => "台湾家宽 REMATCH", "type" => "rematch", "target-rematch-name" => "again" }
    )
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"].unshift(
      "台湾家宽 DIRECT", "台湾家宽 REMATCH"
    )

    result = ClashPatch.patch(config, @policy)
    main = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "Main" }

    refute result.key?(:selected_home)
    assert_includes main.fetch("proxies"), "台湾家宽 DIRECT"
    assert_includes main.fetch("proxies"), "台湾家宽 REMATCH"
    refute result.fetch(:config).fetch("proxy-groups").any? { |group| ClashPatch.managed_name?(group["name"], ClashPatch::SAFE_GROUP_BASE) }
  end

  def test_owned_ai_group_is_independent_and_collision_safe
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-groups"] << { "name" => "🤖 AI · Clash Patch", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << { "name" => "🤖 AI · Clash Patch 2", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    result = ClashPatch.patch(config, @policy)
    names = result.fetch(:config).fetch("proxy-groups").map { |group| group["name"] }

    assert_equal names.uniq, names
    assert_equal "🤖 AI · Clash Patch 3", result.fetch(:ai_group)
    managed = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], managed.fetch("proxies")
  end

  def test_user_owned_branded_select_group_is_preserved
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
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
    assert_equal "🤖 AI · Clash Patch", first.fetch(:ai_group)
    refute second.fetch(:changed)
  end

  def test_branded_user_group_with_ai_rules_is_not_mistaken_for_patch_ownership
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
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

    first = ClashPatch.patch(config, @policy)
    second = ClashPatch.patch(first.fetch(:config), @policy)

    assert_equal user_group, first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal user_group, second.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal "🤖 AI · Clash Patch", first.fetch(:ai_group)
    assert_equal "🤖 AI · Clash Patch", second.fetch(:ai_group)
    refute second.fetch(:changed)
  end

  def test_inline_proxy_names_reserve_managed_group_names
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxies"].unshift(
      { "name" => "🤖 AI · Clash Patch", "type" => "ss", "server" => "ai.example", "port" => 443 },
      { "name" => "🛡 安全代理 · Clash Patch", "type" => "ss", "server" => "safe.example", "port" => 443 }
    )

    result = ClashPatch.patch(config, @policy)

    assert_equal "🤖 AI · Clash Patch 2", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    refute result.fetch(:config).fetch("proxy-groups").any? { |group| ClashPatch.managed_name?(group["name"], ClashPatch::SAFE_GROUP_BASE) }
  end

  def test_migrates_legacy_owned_ai_rules_and_dns_pattern
    old = base_config
    old["proxy-groups"].reject! { |group| group["name"] == "AI" }
    ai_group = ClashPatch::AI_GROUP_BASE
    safe_group = ClashPatch::SAFE_GROUP_BASE
    old["proxy-groups"] << { "name" => ai_group, "type" => "select", "proxies" => ["台湾家宽 01"] }
    old["proxy-groups"] << {
      "name" => safe_group, "type" => "select", "proxies" => ["台湾家宽 01"], "include-all" => true,
      "exclude-type" => ClashPatch::EXCLUDED_SAFE_TYPES, "empty-fallback" => "REJECT"
    }
    old["rules"] = ["NETWORK,UDP,#{safe_group}", "NETWORK,UDP,REJECT"] +
      ClashPatch.render_ai_rules(@policy, ai_group).map { |rule| rule.sub("160.79.104.0/23", "160.79.104.0/21") } +
      ["DOMAIN-SUFFIX,ai.com,#{ai_group}"] + old.fetch("rules")
    old["dns"]["nameserver"] = ["https://dns.alidns.com/dns-query##{safe_group}"]
    old["dns"]["nameserver-policy"] = { "+.ai.com" => old.dig("dns", "nameserver").dup }

    result = ClashPatch.patch(old, @policy)
    rules = result.fetch(:config).fetch("rules")
    dns_policy = result.fetch(:config).dig("dns", "nameserver-policy")

    refute_includes rules, "DOMAIN-SUFFIX,ai.com,#{ai_group}"
    refute_includes rules, "IP-CIDR,160.79.104.0/21,#{ai_group},no-resolve"
    assert_includes rules, "IP-CIDR,160.79.104.0/23,#{ai_group},no-resolve"
    refute dns_policy.key?("+.ai.com")
    assert result.fetch(:ai_group_reset)
    assert_includes ClashPatch.chinese_status(result.merge(path: "/profiles/friend.yaml", active: false)), "升级 AI 分组"
  end

  def test_preserves_user_legacy_ai_rules_and_dns_pattern
    config = base_config
    config["proxy-groups"] << { "name" => "Friend", "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["rules"].unshift(
      "DOMAIN-SUFFIX,ai.com,Friend",
      "IP-CIDR,160.79.104.0/21,Friend,no-resolve"
    )
    config["dns"]["nameserver-policy"]["+.ai.com"] = ["https://1.1.1.1/dns-query#Friend"]

    result = ClashPatch.patch(config, @policy)

    assert_includes result.fetch(:config).fetch("rules"), "DOMAIN-SUFFIX,ai.com,Friend"
    assert_includes result.fetch(:config).fetch("rules"), "IP-CIDR,160.79.104.0/21,Friend,no-resolve"
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#Friend" }, result.fetch(:config).dig("dns", "nameserver-policy", "+.ai.com")
  end

  def test_patches_config_without_rules_array
    config = base_config
    config.delete("rules")

    result = ClashPatch.patch(config, @policy)

    assert_equal :updated, result.fetch(:status)
    assert_instance_of Array, result.fetch(:config).fetch("rules")
    assert result.fetch(:config).fetch("rules").any? { |rule| rule.start_with?("DOMAIN-SUFFIX,openai.com,") }
  end

  def test_existing_ai_group_is_reused_even_when_many_similar_names_exist
    config = base_config
    base = "🤖 AI · Clash Patch"
    config["proxy-groups"] << { "name" => base, "type" => "select", "proxies" => ["Main"] }
    (2..9).each do |suffix|
      config["proxy-groups"] << { "name" => "#{base} #{suffix}", "type" => "select", "proxies" => ["Main"] }
    end

    first = ClashPatch.patch(config, @policy)
    second = ClashPatch.patch(first.fetch(:config), @policy)

    assert_equal "AI", first.fetch(:ai_group)
    refute first.fetch(:config).fetch("proxy-groups").any? { |group| group["name"] == "#{base} 10" }
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

  def test_defaults_read_decodes_unicode_profile_names_from_plist
    status = Struct.new(:success?).new(true)
    plist = "<?xml version=\"1.0\"?><plist><dict><key>selectConfigName</key><string>Yue.to | 悦通</string></dict></plist>"
    responses = [[plist, "", status], ["Yue.to | 悦通\n", "", status]]
    runner = lambda do |*_args, **_kwargs|
      responses.shift || ["", "", Struct.new(:success?).new(false)]
    end

    Open3.stub(:capture3, runner) do
      assert_equal "Yue.to | 悦通", ClashPatch.defaults_read("selectConfigName")
    end
  end

  def test_single_custom_profile_directory_is_active
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))

      results = ClashPatch.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "friend")

      assert_equal true, results.fetch(0).fetch(:active)
      refute results.fetch(0).key?(:reloaded)
    end
  end

  def test_run_silently_skips_default_config_when_another_profile_is_selected
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "config.yaml"), "mode: rule\nrules: []\n")
      selected = File.join(directory, "friend.yaml")
      File.write(selected, YAML.dump(base_config))

      results = ClashPatch.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "friend", dry_run: true)

      assert_equal [selected], results.map { |result| result.fetch(:path) }
    end
  end

  def test_run_applies_the_common_baseline_to_every_subscription_in_current_storage
    Dir.mktmpdir do |directory|
      names = ["MESL", "Yue.to | 悦通", "网际快车"]
      names.each { |name| File.write(File.join(directory, "#{name}.yaml"), YAML.dump(base_config)) }
      File.write(File.join(directory, "config.yaml"), YAML.dump(base_config))

      results = ClashPatch.run(
        directories: [directory], policy_path: POLICY_PATH,
        selected_name: "MESL", usage_profile: 1
      )

      assert_equal names.sort, results.map { |result| File.basename(result.fetch(:path), ".yaml") }.sort
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      names.each do |name|
        config = ClashPatch.load_yaml(File.read(File.join(directory, "#{name}.yaml")))
        assert config.fetch("rule-providers").key?(provider_name), name
        assert_includes config.fetch("rules"), "RULE-SET,#{provider_name},DIRECT", name
        refute config.key?("tun"), name
      end
    end
  end

  def test_run_keeps_default_config_when_it_is_selected
    Dir.mktmpdir do |directory|
      config = File.join(directory, "config.yaml")
      File.write(config, YAML.dump(base_config))
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))

      results = ClashPatch.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "config", dry_run: true)

      assert_includes results.map { |result| result.fetch(:path) }, config
    end
  end

  def test_selected_profile_chooses_the_matching_icloud_container
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      FileUtils.mkdir_p(current)
      FileUtils.mkdir_p(legacy)
      File.write(File.join(current, "other.yaml"), YAML.dump(base_config))
      selected = File.join(legacy, "friend.yaml")
      File.write(selected, YAML.dump(base_config))

      results = ClashPatch.stub(:icloud_enabled?, true) do
        ClashPatch.run(directories: [current, legacy], policy_path: POLICY_PATH, selected_name: "friend")
      end
      active = results.find { |result| result[:active] }

      assert_equal selected, active.fetch(:path)
      refute active.key?(:reloaded)
    end
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

  def test_tun_state_does_not_require_a_local_socket_when_a_requester_is_supplied
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }

    ClashPatch.stub(:controller_socket, nil) do
      assert_equal :enabled, ClashPatch.tun_state(requester: enabled)
    end
  end

  def test_profile_discovery_uses_only_the_active_storage_root
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [local, current, legacy].each { |path| FileUtils.mkdir_p(path) }

      File.write(File.join(current, "active.yaml"), YAML.dump(base_config))
      File.write(File.join(legacy, "abandoned.yaml"), YAML.dump(base_config))

      local_directories = ClashPatch.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: false, selected: "active"
      )
      cloud_directories = ClashPatch.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "active"
      )

      assert_equal [local], local_directories
      assert_equal [current], cloud_directories
      refute_includes cloud_directories, legacy
    end
  end

  def test_profile_discovery_refuses_ambiguous_icloud_roots
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [current, legacy].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(current, "one.yaml"), YAML.dump(base_config))
      File.write(File.join(legacy, "two.yaml"), YAML.dump(base_config))

      directories = ClashPatch.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "missing"
      )

      assert_empty directories
    end
  end

  def test_profile_discovery_refuses_unknown_storage_mode
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      FileUtils.mkdir_p(local)
      File.write(File.join(local, "old.yaml"), YAML.dump(base_config))

      directories = ClashPatch.stub(:defaults_read, "") do
        ClashPatch.default_profile_directories(home: home, app_paths: [])
      end

      assert_empty directories
    end
  end

  def test_library_run_does_not_reload_unless_explicitly_enabled
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))

      results = ClashPatch.run(
        directory: directory,
        policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"),
        selected_name: "friend"
      )
      active = results.find { |entry| entry.fetch(:path) == profile }

      assert_equal :updated, active.fetch(:status)
      refute active.key?(:reloaded)
      assert_includes ClashPatch.chinese_status(active), "已更新，尚未自动刷新"
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

  def test_mihomo_default_core_is_resolved_before_status_and_validation
    discovered_core = "/tmp/discovered-mihomo"
    status_calls = []
    validation_calls = []
    success = Struct.new(:success?).new(true)

    ClashPatch.stub(:mihomo_core_path, discovered_core) do
      File.stub(:file?, ->(path) { path == discovered_core }) do
        File.stub(:executable?, ->(path) { path == discovered_core }) do
          ClashPatch.stub(:run_process_with_timeout, lambda { |core, *arguments, **_keywords|
            status_calls << [core, arguments]
            ["Mihomo Meta v1.19.27", success, false]
          }) do
            assert_equal :supported, ClashPatch.mihomo_core_status
          end
        end
      end

      ClashPatch.stub(:mihomo_core_status, lambda { |core, **_keywords|
        validation_calls << [:status, core]
        :supported
      }) do
        ClashPatch.stub(:run_process_with_timeout, lambda { |core, *arguments, **_keywords|
          validation_calls << [:validate, core, arguments]
          ["", success, false]
        }) do
          assert ClashPatch.validate_with_mihomo("/tmp/profile/config.yaml")
        end
      end
    end

    assert_equal [[discovered_core, ["-v"]]], status_calls
    assert_equal [
      [:status, discovered_core],
      [:validate, discovered_core, ["-d", "/tmp/profile", "-t", "-f", "/tmp/profile/config.yaml"]]
    ], validation_calls
  end

  def test_mihomo_validation_times_out_and_terminates_the_child
    Dir.mktmpdir do |directory|
      core = File.join(directory, "mihomo-test")
      profile = File.join(directory, "friend.yaml")
      File.write(core, <<~SH)
        #!/bin/sh
        if [ "$1" = "-v" ]; then
          echo 'Mihomo Meta v1.19.27 test'
          exit 0
        fi
        sleep 5
      SH
      File.chmod(0o700, core)
      File.write(profile, "rules: []\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ClashPatch.validate_with_mihomo(profile, core_path: core, timeout_seconds: 0.1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :timeout, result
      assert_operator elapsed, :<, 2
    end
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

  def test_cli_reports_useful_policy_errors_without_dumping_policy_content
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      policy = File.join(directory, "policy.json")
      File.write(profile, YAML.dump(base_config))
      File.write(policy, %({"token":"do-not-print",))

      _output, error, status = Open3.capture3(
        RbConfig.ruby, PATCHER_PATH, "--profile-dir", directory, "--policy", policy, "--dry-run"
      )

      refute status.success?
      assert_includes error, "策略文件不是有效的 JSON"
      refute_includes error, "do-not-print"
      refute_equal "Clash 补丁运行失败：JSON::ParserError\n", error
    end
  end

  def test_generated_profile_passes_installed_mihomo_validation
    core = ENV["CLASH_PATCH_TEST_MIHOMO"]
    if core.to_s.empty?
      flunk "CI required a real Mihomo core but CLASH_PATCH_TEST_MIHOMO was empty" if ENV["CLASH_PATCH_REQUIRE_REAL_MIHOMO"] == "1"
      skip "set CLASH_PATCH_RUN_INSTALLED_CORE_TEST=1 to test the locally installed Mihomo core" unless ENV["CLASH_PATCH_RUN_INSTALLED_CORE_TEST"] == "1"
      core = ClashPatch.mihomo_core_path
      skip "ClashX Meta Mihomo core is not installed" unless core
    end
    assert_equal :supported, ClashPatch.mihomo_core_status(core)

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
      [1, 2, 3].each do |usage_profile|
        profile = File.join(directory, "profile-#{usage_profile}.yaml")
        File.write(profile, text)
        assert_equal true, ClashPatch.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} baseline fixture must be valid"
        validator = ->(path) { ClashPatch.validate_with_mihomo(path, core_path: core) }
        result = ClashPatch.patch_path(
          profile, @policy, validator: validator, usage_profile: usage_profile
        )
        assert_equal :updated, result.fetch(:status), "profile #{usage_profile}"
        assert_equal true, ClashPatch.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} patch must stay valid"
      end
    end
  end

  def test_every_profile_status_is_documented
    policy_document = File.read(File.join(ROOT, "clash-patch/references/patch-policy.md"))
    skill_document = File.read(File.join(ROOT, "clash-patch/SKILL.md"))
    examples = [
      { path: "/profiles/friend.yaml", status: :updated, active: true, reloaded: true, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :updated, active: true, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :updated, active: false, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :reload_failed_rolled_back },
      { path: "/profiles/friend.yaml", status: :reload_failed_restore_pending },
      { path: "/profiles/friend.yaml", status: :reload_failed_rollback_conflict },
      { path: "/profiles/friend.yaml", status: :unchanged },
      { path: "/profiles/friend.yaml", status: :no_main_group },
      { path: "/profiles/friend.yaml", status: :no_ai_nodes },
      { path: "/profiles/friend.yaml", status: :invalid },
      { path: "/profiles/friend.yaml", status: :validation_failed },
      { path: "/profiles/friend.yaml", status: :validation_timeout },
      { path: "/profiles/friend.yaml", status: :non_idempotent },
      { path: "/profiles/friend.yaml", status: :invalid_policy },
      { path: "/profiles/friend.yaml", status: :concurrent_change },
      { path: "/profiles/friend.yaml", status: :io_error },
      { path: "/profiles/friend.yaml", status: :error }
    ]
    examples.each do |example|
      message = ClashPatch.chinese_status(example).split("：", 2).last
      status = message.split("；", 2).first
      assert_includes policy_document, status
    end
    assert_includes skill_document, "全部状态以"
  end

  def test_rule_parser_keeps_nested_commas_and_identifies_no_resolve_target
    rule = "AND,((NETWORK,UDP),(DST-PORT,443)),Reject,no-resolve"

    assert_equal ["AND", "((NETWORK,UDP),(DST-PORT,443))", "Reject", "no-resolve"], ClashPatch.split_rule_fields(rule)
    info = ClashPatch.rule_info(rule)
    assert_equal "AND", info.fetch(:type)
    assert_equal "((NETWORK,UDP),(DST-PORT,443))", info.fetch(:payload)
    assert_equal "Reject", info.fetch(:target)
  end

  def test_group_safety_rejects_invalid_or_unsupported_member_filters
    config = base_config
    config["proxy-groups"] << { "name" => "Filtered", "type" => "select", "proxies" => ["台湾家宽 01"], "exclude-filter" => "[" }
    refute ClashPatch.group_cannot_reach_direct?(config, "Filtered")

    config["proxy-groups"].last["exclude-filter"] = "(?=台湾)"
    refute ClashPatch.group_cannot_reach_direct?(config, "Filtered")
  end

  def test_group_safety_accepts_an_explicit_safe_empty_fallback
    config = base_config
    config["proxy-groups"] << { "name" => "Fallback", "type" => "select", "proxies" => [], "empty-fallback" => "台湾家宽 01" }

    assert ClashPatch.group_cannot_reach_direct?(config, "Fallback")
  end

  def test_managed_select_group_lookup_recognizes_an_owned_ai_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    name = ClashPatch::AI_GROUP_BASE
    config["proxy-groups"] << { "name" => name, "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["rules"] = ClashPatch.render_ai_rules(@policy, name) + config.fetch("rules")

    group = ClashPatch.find_managed_select_group(config, ClashPatch::AI_GROUP_BASE, :ai, @policy)

    assert_equal name, group.fetch("name")
  end

  def test_legacy_ai_dns_patterns_include_exact_domain_rules
    policy = Marshal.load(Marshal.dump(@policy))
    policy["legacy_ai_rules"] << "DOMAIN,legacy-ai.example,AI"

    assert_includes ClashPatch.legacy_ai_dns_patterns(policy), "legacy-ai.example"
  end

  def test_yaml_scalar_scanner_falls_back_to_text_when_numeric_conversion_rejects_input
    loader = Psych::ClassLoader::Restricted.new([], [])
    scanner = ClashPatch::YAML12ScalarScanner.new(loader)

    scanner.stub(:Integer, ->(_value) { raise ArgumentError, "conversion failed" }) do
      assert_equal "123", scanner.tokenize("123")
    end
  end

  def test_patch_rules_removes_the_owned_legacy_quic_guard
    config = base_config
    user_rule = "AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT"
    config["rules"].unshift(user_rule, ClashPatch::LEGACY_QUIC_REJECT_RULE)

    patched = ClashPatch.patch(config, @policy).fetch(:config)

    assert_includes patched.fetch("rules"), user_rule
    refute_includes patched.fetch("rules"), ClashPatch::LEGACY_QUIC_REJECT_RULE
  end

  def test_mihomo_status_classifies_command_failures_without_running_a_real_core
    status = Object.new
    status.define_singleton_method(:success?) { false }

    ClashPatch.stub(:run_process_with_timeout, ["bad executable", status, false]) do
      assert_equal :unreadable, ClashPatch.mihomo_core_status(RbConfig.ruby)
    end
    ClashPatch.stub(:run_process_with_timeout, ["", nil, true]) do
      assert_equal :timeout, ClashPatch.mihomo_core_status(RbConfig.ruby)
    end
  end

  def test_controller_request_returns_safe_empty_response_when_curl_fails
    failure = Object.new
    failure.define_singleton_method(:success?) { false }

    Open3.stub(:capture2e, ["curl failed", failure]) do
      assert_equal [0, ""], ClashPatch.controller_request("/tmp/missing.sock", "GET", "/configs")
    end
  end

  def test_controller_request_parses_a_successful_controller_response
    success = Object.new
    success.define_singleton_method(:success?) { true }

    Open3.stub(:capture2e, ["{\"tun\":true}\n200", success]) do
      assert_equal [200, "{\"tun\":true}"], ClashPatch.controller_request("/tmp/controller.sock", "GET", "/configs")
    end
  end

  def test_mihomo_validation_uses_the_profile_directory_and_fails_closed
    success = Object.new
    success.define_singleton_method(:success?) { true }
    calls = []
    ClashPatch.stub(:mihomo_core_status, :supported) do
      ClashPatch.stub(:run_process_with_timeout, ->(*args, **kwargs) { calls << [args, kwargs]; ["ok", success, false] }) do
        assert ClashPatch.validate_with_mihomo("/tmp/profile/config.yaml", core_path: "/tmp/mihomo")
      end
    end
    assert_equal ["/tmp/mihomo", "-d", "/tmp/profile", "-t", "-f", "/tmp/profile/config.yaml"], calls.fetch(0).fetch(0)

    ClashPatch.stub(:mihomo_core_status, :timeout) do
      assert_equal :timeout, ClashPatch.validate_with_mihomo("/tmp/profile/config.yaml", core_path: "/tmp/mihomo")
    end
  end

  def test_default_connectivity_retries_transient_errors_and_returns_false
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    attempts = 0
    Open3.stub(:capture2e, ->(*_args) { attempts += 1; ["", failed] }) do
      refute ClashPatch.default_connectivity_healthy?
    end
    assert_equal 3, attempts

    successful = Object.new
    successful.define_singleton_method(:success?) { true }
    Open3.stub(:capture2e, ["", successful]) do
      assert ClashPatch.default_connectivity_healthy?
    end
  end

  def test_runtime_helpers_fail_closed_on_invalid_json
    requester = ->(*_args) { [200, "not json"] }

    assert_equal :unknown, ClashPatch.tun_state(requester: requester)
    assert_nil ClashPatch.runtime_selections(requester)
    refute ClashPatch.dns_runtime_healthy?(requester, "example.invalid")
  end

  def test_process_timeout_helpers_cover_normal_exit_and_kill_fallbacks
    output, status, timed_out = ClashPatch.run_process_with_timeout(
      RbConfig.ruby, "-e", "STDOUT.write('fixture-output')", timeout_seconds: 2
    )
    assert_equal "fixture-output", output
    assert status.success?
    refute timed_out

    signals = []
    killer = lambda do |signal, pid|
      signals << [signal, pid]
      raise Errno::ESRCH
    end
    Process.stub(:kill, killer) do
      Process.stub(:waitpid, ->(_pid) { raise Errno::ECHILD }) do
        assert_nil ClashPatch.terminate_process_group(12_345)
      end
    end
    assert_equal [["TERM", -12_345], ["KILL", 12_345]], signals
  end

  def test_mihomo_core_status_covers_supported_old_and_unreadable_results
    Dir.mktmpdir do |directory|
      core = File.join(directory, "mihomo")
      File.write(core, "#!/bin/sh\n")
      File.chmod(0o700, core)
      success = Struct.new(:success?).new(true)

      ClashPatch.stub(:run_process_with_timeout, ["Mihomo Meta v1.19.27", success, false]) do
        assert_equal :supported, ClashPatch.mihomo_core_status(core)
      end
      ClashPatch.stub(:run_process_with_timeout, ["Mihomo Meta v1.19.26", success, false]) do
        assert_equal :too_old, ClashPatch.mihomo_core_status(core)
      end
      ClashPatch.stub(:run_process_with_timeout, ->(*_args, **_kwargs) { raise IOError }) do
        assert_equal :unreadable, ClashPatch.mihomo_core_status(core)
      end

      expected = File.expand_path(
        "~/Library/Application Support/com.metacubex.ClashX.meta/.private_core/" \
          "com.metacubex.ClashX.ProxyConfigHelper.meta"
      )
      File.stub(:file?, ->(path) { path == expected }) do
        File.stub(:executable?, ->(path) { path == expected }) do
          assert_equal expected, ClashPatch.mihomo_core_path
        end
      end
    end
  end

  def test_file_transaction_helpers_fail_closed_and_restore_partial_writes
    handle = Object.new
    handle.define_singleton_method(:flock) { |_mode| false }
    times = [0.0, 0.0, 1.0]
    ClashPatch.stub(:monotonic_now, -> { times.shift }) do
      ClashPatch.stub(:sleep, nil) do
        assert_raises(IOError) { ClashPatch.lock_exclusive_with_timeout(handle, timeout_seconds: 0.5) }
      end
    end

    missing = File.join(Dir.tmpdir, "missing-clash-patch-identity")
    refute ClashPatch.same_file_identity?(Struct.new(:dev, :ino).new(1, 1), missing)
    refute ClashPatch.atomic_compare_and_swap_bytes(missing, "old", "new")
    refute ClashPatch.locked_source_current?(Tempfile.new("missing-source"), missing, missing)

    Tempfile.create("clash-patch-write") do |file|
      file.binmode
      file.write("original")
      file.flush
      assert ClashPatch.write_locked_bytes(file, "replacement", "original")
      file.rewind
      assert_equal "replacement", file.read
    end

    failing = Object.new
    failing.define_singleton_method(:rewind) {}
    failing.define_singleton_method(:write) { |_bytes| raise IOError, "injected write failure" }
    error = assert_raises(IOError) { ClashPatch.write_locked_bytes(failing, "new", "old") }
    assert_includes error.message, "原内容恢复失败"
  end

  def test_patch_path_reports_non_idempotence_validation_timeout_and_unexpected_errors
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      calls = 0
      non_idempotent = lambda do |config, _policy, usage_profile:|
        calls += 1
        assert_equal 3, usage_profile
        { changed: true, status: :updated, config: config }
      end
      ClashPatch.stub(:patch, non_idempotent) do
        result = ClashPatch.patch_path(path, @policy, dry_run: true)
        assert_equal :non_idempotent, result.fetch(:status)
      end
      assert_equal 2, calls

      result = ClashPatch.patch_path(path, @policy, validator: ->(_candidate) { :timeout })
      assert_equal :validation_timeout, result.fetch(:status)

      ClashPatch.stub(:patch_path_once, ->(*_args, **_kwargs) { raise "injected unexpected failure" }) do
        assert_equal :error, ClashPatch.patch_path(path, @policy).fetch(:status)
      end
    end
  end

  def test_run_rejects_bad_policy
    Dir.mktmpdir do |directory|
      invalid_policy = File.join(directory, "policy.json")
      File.write(invalid_policy, JSON.generate("version" => -1))
      assert_raises(ClashPatch::InvalidConfigError) do
        ClashPatch.run(directory: directory, policy_path: invalid_policy)
      end
    end
  end

  def test_runtime_helpers_cover_socket_discovery_and_exception_boundaries
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      socket_path = File.join(home, "controller.sock")
      server = UNIXServer.new(socket_path)
      File.write(File.join(cache, "active.yaml"), YAML.dump("external-controller-unix" => socket_path))
      assert_equal socket_path, ClashPatch.controller_socket
    ensure
      server&.close
      ENV["HOME"] = old_home
    end

    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      File.write(File.join(cache, "invalid.yaml"), ":\n")
      assert_nil ClashPatch.controller_socket
    ensure
      ENV["HOME"] = old_home
    end

    Open3.stub(:capture2e, ->(*_args) { raise IOError }) do
      assert_equal [0, ""], ClashPatch.controller_request("socket", "GET", "/configs")
    end
    ClashPatch.stub(:controller_socket, nil) do
      assert_equal :unknown, ClashPatch.tun_state
    end
    ClashPatch.stub(:controller_socket, "socket") do
      ClashPatch.stub(:controller_request, [200, JSON.generate("tun" => { "enable" => true })]) do
        assert_equal :enabled, ClashPatch.tun_state
      end
    end
    assert_equal :unknown, ClashPatch.tun_state(requester: ->(*_args) {
      [200, JSON.generate("tun" => { "enable" => nil })]
    })
    Open3.stub(:capture2e, ->(*_args) { raise IOError }) do
      refute ClashPatch.default_connectivity_healthy?
    end
  end

  def test_runtime_rollback_helpers_fail_closed_on_missing_files_and_request_errors
    missing_result = {
      path: File.join(Dir.tmpdir, "missing-clash-patch-profile"),
      rollback_bytes: "old",
      patched_digest: Digest::SHA256.hexdigest("new")
    }
    refute ClashPatch.restore_profile_bytes(missing_result)
    refute ClashPatch.runtime_health_healthy?(
      ->(*_args) { raise IOError },
      selections: {}, expected_tun: :enabled, connectivity_checker: -> { true }
    )

    ClashPatch.stub(:controller_socket, nil) do
      ClashPatch.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
        result = ClashPatch.activate_updated_profile(missing_result)
        assert_equal :reload_failed_restore_pending, result.fetch(:status)
      end
    end
    ClashPatch.stub(:runtime_selections, ->(_requester) { raise IOError }) do
      ClashPatch.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
        result = ClashPatch.activate_updated_profile(missing_result, requester: ->(*_args) { [200, "{}"] })
        assert_equal :reload_failed_restore_pending, result.fetch(:status)
      end
    end
    ClashPatch.stub(:controller_socket, "socket") do
      ClashPatch.stub(:controller_request, [503, ""]) do
        ClashPatch.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
          result = ClashPatch.activate_updated_profile(missing_result)
          assert_equal :reload_failed_restore_pending, result.fetch(:status)
        end
      end
    end
    ClashPatch.stub(:restore_profile_bytes, true) do
      status = ClashPatch.rollback_after_reload_failure(
        missing_result, ->(*_args) { raise IOError }, missing_result.fetch(:path),
        selections: {}, expected_tun: :enabled
      )
      assert_equal :reload_failed_restore_pending, status
    end
  end

  def test_atomic_replace_restores_the_original_when_commit_verification_fails
    Dir.mktmpdir do |directory|
      path = File.join(directory, "profile.yaml")
      File.binwrite(path, "original")
      identities = [false, true]

      File.open(path, "r+b") do |source|
        result = ClashPatch.stub(:same_file_identity?, ->(*_args) { identities.shift }) do
          ClashPatch.atomic_replace_locked(source, path, File.realpath(path), "original", "replacement")
        end
        refute result
      end

      assert_empty identities
      assert_equal "original", File.binread(path)
    end
  end

  def test_safe_update_detects_lock_time_and_post_swap_identity_changes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      arguments = {
        targets: [{ name: "friend", path: path, url: "https://subscriptions.invalid/friend" }],
        policy: @policy,
        backup_root: File.join(directory, "backups"),
        usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_candidate) { true },
        activation: ->(_items) { flunk "must not activate" }
      }

      lock_checks = [true, true, false]
      result = ClashPatch.stub(:locked_profile_current?, ->(*_args) { lock_checks.shift }) do
        ClashPatch.safe_update_all(**arguments)
      end
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_empty lock_checks
      assert_equal original.b, File.binread(path)

      File.binwrite(path, original)
      identity_checks = [false, true]
      result = ClashPatch.stub(:same_file_identity?, ->(*_args) { identity_checks.shift }) do
        ClashPatch.safe_update_all(**arguments)
      end
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_empty identity_checks
      assert_equal original.b, File.binread(path)
    end
  end

  def test_storage_and_application_discovery_cover_local_and_icloud_variants
    ClashPatch.stub(:storage_mode, :icloud) do
      assert ClashPatch.icloud_enabled?
    end

    expected_user_app = File.expand_path("~/Applications/ClashX Meta.app")
    Dir.stub(:exist?, ->(path) { path == expected_user_app }) do
      assert_equal [expected_user_app], ClashPatch.clashx_app_paths
    end

    Dir.mktmpdir do |directory|
      missing_app = File.join(directory, "Missing.app")
      valid_app = File.join(directory, "Valid.app")
      broken_app = File.join(directory, "Broken.app")
      FileUtils.mkdir_p(File.join(valid_app, "Contents"))
      FileUtils.mkdir_p(File.join(broken_app, "Contents"))
      File.write(File.join(valid_app, "Contents", "Info.plist"), "fixture")
      File.write(File.join(broken_app, "Contents", "Info.plist"), "fixture")
      success = Struct.new(:success?).new(true)
      runner = lambda do |*_args|
        [JSON.generate("NSUbiquitousContainers" => { "iCloud.com.friend" => {} }), success]
      end

      ids = Open3.stub(:capture2, runner) do
        ClashPatch.icloud_container_ids([missing_app, valid_app])
      end
      assert_includes ids, "iCloud.com.friend"

      Open3.stub(:capture2, ->(*_args) { raise IOError, "injected plist failure" }) do
        ids = ClashPatch.icloud_container_ids([broken_app])
        assert_equal %w[iCloud.com.metacubex.ClashX iCloud.com.west2online.ClashX], ids
      end
    end

    roots = ["/tmp/cloud", "/tmp/local/.config/clash.meta"]
    ClashPatch.stub(:profile_paths, []) do
      ClashPatch.stub(:icloud_enabled?, false) do
        assert_equal roots.last, ClashPatch.active_profile_root(roots, "friend")
      end
    end
  end

  def test_result_contract_sanitizes_unknown_objects
    object = Object.new
    object.define_singleton_method(:to_s) { "token=fixture-secret" }

    assert_equal "[已隐藏]", ClashPatchResult.sanitize(object)
  end

  def test_cli_help_exposes_every_supported_operation_without_touching_profiles
    output, error = capture_io { assert_equal 0, ClashPatch.cli(["--help"]) }

    assert_includes output, "--safe-update-all"
    assert_empty error
  end

  def test_cli_reports_missing_profile_directories
    ClashPatch.stub(:default_profile_directories, []) do
      _output, error = capture_io { assert_equal 2, ClashPatch.cli([]) }
      assert_includes error, "没有找到"
    end

    Dir.mktmpdir do |directory|
      ClashPatch.stub(:run, []) do
        _output, error = capture_io do
          arguments = ["--profile-dir", directory, "--policy", POLICY_PATH]
          assert_equal 1, ClashPatch.cli(arguments)
        end
        assert_includes error, "没有找到可处理的配置"
      end
    end
  end

  def test_cli_read_only_runtime_operations_use_their_authoritative_helpers
    ClashPatch.stub(:mihomo_core_status, :supported) do
      output, = capture_io { assert_equal 0, ClashPatch.cli(["--print-core-status"]) }
      assert_includes output, "supported"
    end
    ClashPatch.stub(:tun_state, :enabled) do
      output, = capture_io { assert_equal 0, ClashPatch.cli(["--print-tun-state"]) }
      assert_includes output, "enabled"
    end
    ClashPatch.stub(:subscription_auto_update_state, :disabled) do
      output, = capture_io { assert_equal 0, ClashPatch.cli(["--print-subscription-auto-update-state"]) }
      assert_includes output, "disabled"
    end
  end

  def test_cli_json_covers_read_only_and_help_operations
    output, error = capture_io { assert_equal 0, ClashPatch.cli(["--json", "--help"]) }
    assert_empty error
    assert_equal "help", JSON.parse(output).fetch("operation")

    ClashPatch.stub(:mihomo_core_status, :supported) do
      output, error = capture_io { assert_equal 0, ClashPatch.cli(["--json", "--print-core-status"]) }
      assert_empty error
      assert_equal "ok", JSON.parse(output).fetch("status")
    end
    ClashPatch.stub(:mihomo_core_status, :missing) do
      output, error = capture_io { assert_equal 1, ClashPatch.cli(["--json", "--print-core-status"]) }
      assert_empty error
      assert_equal "unsupported", JSON.parse(output).fetch("status")
    end
    ClashPatch.stub(:tun_state, :enabled) do
      output, = capture_io { assert_equal 0, ClashPatch.cli(["--json", "--print-tun-state"]) }
      assert_equal "tun_state", JSON.parse(output).fetch("operation")
    end
    ClashPatch.stub(:subscription_auto_update_state, :disabled) do
      output, = capture_io do
        assert_equal 0, ClashPatch.cli(["--json", "--print-subscription-auto-update-state"])
      end
      assert_equal "subscription_auto_update_state", JSON.parse(output).fetch("operation")
    end
  end

  def test_cli_json_covers_backup_and_auto_update_operations
    Dir.mktmpdir do |directory|
      ClashPatch.stub(:list_backups, ["private.backup"]) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--profile-dir", directory, "--list-backups"])
        end
        assert_equal "backups_listed", JSON.parse(output).fetch("code")
      end
      ClashPatch.stub(:snapshot_initial_profiles, ["/private/friend.yaml.backup"]) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--profile-dir", directory, "--snapshot-initial"])
        end
        assert_equal ["initial_snapshot"], JSON.parse(output).fetch("changes")
      end
      comparison = { same: false, changes: ["dns.nameserver"] }
      ClashPatch.stub(:compare_backup, comparison) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--profile-dir", directory, "--compare-backup", "id"])
        end
        assert_equal ["dns.nameserver"], JSON.parse(output).fetch("changes")
      end
      ClashPatch.stub(:restore_backup, { status: :updated }) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--profile-dir", directory, "--restore-backup", "id"])
        end
        assert_equal "updated", JSON.parse(output).fetch("code")
      end
      ClashPatch.stub(:disable_subscription_auto_update, { status: :already_disabled }) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--disable-subscription-auto-update"])
        end
        assert_equal "no_change", JSON.parse(output).fetch("status")
      end
      ClashPatch.stub(:disable_subscription_auto_update, ->(**_args) { raise ClashPatch::InvalidConfigError }) do
        output, error = capture_io do
          assert_equal 1, ClashPatch.cli(["--json", "--disable-subscription-auto-update"])
        end
        assert_empty error
        assert_equal "auto_update_failed", JSON.parse(output).fetch("code")
      end
      ClashPatch.stub(:enable_subscription_auto_update, { status: :enabled }) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--json", "--enable-subscription-auto-update"])
        end
        assert_equal "enabled", JSON.parse(output).fetch("code")
      end
      ClashPatch.stub(:enable_subscription_auto_update, -> { raise ClashPatch::InvalidConfigError }) do
        output, error = capture_io do
          assert_equal 1, ClashPatch.cli(["--json", "--enable-subscription-auto-update"])
        end
        assert_empty error
        assert_equal "auto_update_restore_failed", JSON.parse(output).fetch("code")
      end
      ClashPatch.stub(:restore_owned_subscription_auto_update, { status: :restored }) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli([
            "--json", "--backup-dir", directory, "--restore-owned-subscription-auto-update"
          ])
        end
        result = JSON.parse(output)
        assert_equal "restore_owned_subscription_auto_update", result.fetch("operation")
        assert_equal "restored", result.fetch("code")
        assert_equal ["subscription_auto_update"], result.fetch("changes")
      end
      ClashPatch.stub(:restore_owned_subscription_auto_update, ->(**_args) { raise ClashPatch::InvalidConfigError }) do
        output, error = capture_io do
          assert_equal 1, ClashPatch.cli([
            "--json", "--backup-dir", directory, "--restore-owned-subscription-auto-update"
          ])
        end
        assert_empty error
        assert_equal "auto_update_restore_failed", JSON.parse(output).fetch("code")
      end
    end
  end

  def test_cli_human_mode_covers_maintenance_success_and_failure_outputs
    Dir.mktmpdir do |directory|
      operations = [
        [:disable_subscription_auto_update, ["--disable-subscription-auto-update"], { status: :disabled }],
        [:enable_subscription_auto_update, ["--enable-subscription-auto-update"], { status: :enabled }],
        [
          :restore_owned_subscription_auto_update,
          ["--backup-dir", directory, "--restore-owned-subscription-auto-update"],
          { status: :restored }
        ]
      ]
      operations.each do |method_name, arguments, result|
        calls = 0
        behavior = lambda do |*_arguments, **_keywords|
          calls += 1
          raise ClashPatch::InvalidConfigError, "injected maintenance failure" if calls == 2

          result
        end
        ClashPatch.stub(method_name, behavior) do
          output, error = capture_io { assert_equal 0, ClashPatch.cli(arguments.dup) }
          assert_includes output, result.fetch(:status).to_s
          assert_empty error

          _output, error = capture_io { assert_equal 1, ClashPatch.cli(arguments.dup) }
          assert_includes error, "injected maintenance failure"
        end
      end

      ClashPatch.stub(:snapshot_initial_profiles, ["/private/friend.yaml.backup"]) do
        output, error = capture_io do
          assert_equal 0, ClashPatch.cli(["--profile-dir", directory, "--snapshot-initial"])
        end
        assert_includes output, "friend.yaml.backup"
        assert_empty error
      end
    end
  end

  def test_cli_safe_update_covers_every_human_and_json_result_class
    Dir.mktmpdir do |directory|
      cases = [
        [{ status: :updated, count: 2, profiles: %w[first second] }, 0, "已安全更新"],
        [{ status: :rollback_failed }, 1, "未能恢复"],
        [{ status: :runtime_restore_pending }, 1, "运行内核恢复失败"],
        [{ status: :aborted }, 1, "保持原样"]
      ]
      cases.each do |result, expected_exit, expected_text|
        ClashPatch.stub(:remote_subscription_targets, []) do
          ClashPatch.stub(:selected_profile_name, "friend") do
            ClashPatch.stub(:safe_update_all, result) do
              output, error = capture_io do
                assert_equal expected_exit, ClashPatch.cli([
                  "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
                ])
              end
              assert_includes output + error, expected_text
            end
          end
        end
      end

      json_cases = [
        [{ status: :updated, count: 1, profiles: ["friend"] }, "safe_update_completed"],
        [{ status: :rollback_failed }, "rollback_failed"],
        [{ status: :aborted }, "safe_update_failed"]
      ]
      json_cases.each do |result, expected_code|
        ClashPatch.stub(:remote_subscription_targets, []) do
          ClashPatch.stub(:selected_profile_name, "friend") do
            ClashPatch.stub(:safe_update_all, result) do
              output, error = capture_io do
                ClashPatch.cli([
                  "--json", "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
                ])
              end
              assert_empty error
              assert_equal expected_code, JSON.parse(output).fetch("code")
            end
          end
        end
      end
    end
  end

  def test_cli_human_restore_and_top_level_errors_report_without_sensitive_values
    Dir.mktmpdir do |directory|
      [
        :reload_failed_rolled_back,
        :reload_failed_rollback_conflict,
        :invalid_backup
      ].each do |status|
        ClashPatch.stub(:restore_backup, { status: status }) do
          output, error = capture_io do
            assert_equal 1, ClashPatch.cli(["--profile-dir", directory, "--restore-backup", "backup-id"])
          end
          assert_includes output, status.to_s
          assert_empty error
        end
      end

      missing_policy = File.join(directory, "missing-policy.json")
      _output, error = capture_io do
        assert_equal 1, ClashPatch.cli(["--profile-dir", directory, "--policy", missing_policy])
      end
      assert_includes error, "找不到所需文件"

      invalid_policy = File.join(directory, "invalid-policy.json")
      File.write(invalid_policy, "{")
      _output, error = capture_io do
        assert_equal 1, ClashPatch.cli(["--profile-dir", directory, "--policy", invalid_policy])
      end
      assert_includes error, "不是有效的 JSON"

      [
        [ClashPatch::InvalidConfigError.new("password=fixture-secret"), "Clash 补丁运行失败"],
        [RuntimeError.new("token=fixture-secret"), "Clash 补丁运行失败"]
      ].each do |exception, expected_text|
        ClashPatch.stub(:run, ->(**_arguments) { raise exception }) do
          _output, error = capture_io do
            assert_equal 1, ClashPatch.cli(["--profile-dir", directory, "--policy", POLICY_PATH])
          end
          assert_includes error, expected_text
          refute_includes error, "fixture-secret"
        end
      end
    end
  end

  def test_cli_restore_backup_reloads_and_checks_the_active_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      restore_result = {
        status: :updated, path: profile, rollback_bytes: "current",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activated = false
      activation = lambda do |result, require_tun:|
        activated = true
        assert_equal :preserve, require_tun
        result.merge(reloaded: true)
      end

      ClashPatch.stub(:restore_backup, restore_result) do
        ClashPatch.stub(:selected_profile_name, "friend") do
          ClashPatch.stub(:active_profile_root, directory) do
            ClashPatch.stub(:activate_updated_profile, activation) do
              output, error = capture_io do
                assert_equal 0, ClashPatch.cli([
                  "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                  "--expected-current-sha256", "0" * 64
                ])
              end
              assert_empty error
              assert_equal "ok", JSON.parse(output).fetch("status")
            end
          end
        end
      end

      assert activated
    end
  end

  def test_cli_restore_backup_reports_when_the_previous_runtime_cannot_be_reloaded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      restore_result = {
        status: :updated, path: profile, rollback_bytes: "current",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activation_result = restore_result.merge(status: :reload_failed_restore_pending)

      ClashPatch.stub(:restore_backup, restore_result) do
        ClashPatch.stub(:selected_profile_name, "friend") do
          ClashPatch.stub(:active_profile_root, directory) do
            ClashPatch.stub(:activate_updated_profile, activation_result) do
              output, error = capture_io do
                assert_equal 1, ClashPatch.cli([
                  "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                  "--expected-current-sha256", "0" * 64
                ])
              end
              assert_empty error
              result = JSON.parse(output)
              assert_equal "partial", result.fetch("status")
              assert_equal "restore_runtime_pending", result.fetch("code")
              assert_includes result.fetch("summary_zh"), "运行内核"
            end
          end
        end
      end
    end
  end

  def test_cli_restore_backup_checks_the_active_runtime_when_the_file_already_matches
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      restore_result = {
        status: :no_change, path: profile, rollback_bytes: "restored",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activated = false
      activation = lambda do |result, require_tun:|
        activated = true
        assert_equal :preserve, require_tun
        result.merge(reloaded: true)
      end

      ClashPatch.stub(:restore_backup, restore_result) do
        ClashPatch.stub(:selected_profile_name, "friend") do
          ClashPatch.stub(:active_profile_root, directory) do
            ClashPatch.stub(:activate_updated_profile, activation) do
              output, error = capture_io do
                assert_equal 0, ClashPatch.cli([
                  "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                  "--expected-current-sha256", "0" * 64
                ])
              end
              assert_empty error
              result = JSON.parse(output)
              assert_equal "no_change", result.fetch("status")
              assert_includes result.fetch("summary_zh"), "运行检查"
            end
          end
        end
      end

      assert activated
    end
  end

  def test_cli_safe_update_reports_unresolved_runtime_recovery
    Dir.mktmpdir do |directory|
      ClashPatch.stub(:remote_subscription_targets, []) do
        ClashPatch.stub(:selected_profile_name, "friend") do
          ClashPatch.stub(
            :safe_update_all,
            { status: :runtime_restore_pending, runtime_status: :reload_failed_restore_pending }
          ) do
            output, error = capture_io do
              assert_equal 1, ClashPatch.cli([
                "--json", "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
              ])
            end
            assert_empty error
            result = JSON.parse(output)
            assert_equal "partial", result.fetch("status")
            assert_equal "safe_update_runtime_pending", result.fetch("code")
            assert_includes result.fetch("summary_zh"), "运行内核"
          end
        end
      end
    end
  end

  def test_json_item_and_batch_statuses_cover_success_failure_and_rollback
    assert_equal "updated", ClashPatch.result_item(path: "/private/a.yaml", status: :updated).fetch("status")
    assert_equal "unchanged", ClashPatch.result_item(path: "/private/a.yaml", status: :unchanged).fetch("status")
    assert_equal "rolled_back", ClashPatch.result_item(path: "/private/a.yaml", status: :reload_failed_rolled_back).fetch("status")
    assert_equal "skipped", ClashPatch.result_item(path: "/private/a.yaml", status: :invalid).fetch("status")
    assert_equal "failed", ClashPatch.result_item(path: "/private/a.yaml", status: :unknown).fetch("status")

    assert_equal "no_change", ClashPatch.batch_json_status([{ status: :unchanged }]).first
    assert_equal "ok", ClashPatch.batch_json_status([{ status: :updated }]).first
    assert_equal "partial", ClashPatch.batch_json_status([{ status: :updated }, { status: :invalid }]).first
    assert_equal "failed", ClashPatch.batch_json_status([{ status: :invalid }]).first
  end

  def test_cli_returns_failure_when_any_profile_was_not_applied
    results = [
      { path: "/private/current.yaml", status: :reload_failed_rolled_back },
      { path: "/private/other.yaml", status: :unchanged }
    ]
    ClashPatch.stub(:run, results) do
      output, error = capture_io do
        assert_equal 1, ClashPatch.cli(["--json", "--profile-dir", "/private", "--usage-profile", "3"])
      end
      assert_empty error
      result = JSON.parse(output)
      assert_equal "partial", result.fetch("status")
      assert_equal 1, result.fetch("exit_code")
    end

    ClashPatch.stub(:run, results) do
      _output, _error = capture_io do
        assert_equal 1, ClashPatch.cli(["--profile-dir", "/private", "--usage-profile", "3"])
      end
    end
  end

  def test_normal_batch_aborts_before_writing_when_a_later_profile_fails
    Dir.mktmpdir do |directory|
      first = File.join(directory, "a-valid.yaml")
      second = File.join(directory, "z-invalid.yaml")
      original = YAML.dump(base_config)
      File.write(first, original)
      File.write(second, "not: [valid")

      results = ClashPatch.run(
        directory: directory, policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"),
        validator: ->(_path) { true }, auto_reload: false, usage_profile: 3
      )

      assert results.any? { |result| result[:status] == :invalid }
      assert_equal original, File.read(first)
      assert results.any? { |result| result[:status] == :batch_aborted }
    end
  end

  def test_normal_batch_restores_an_earlier_real_write_when_a_later_commit_fails
    Dir.mktmpdir do |directory|
      first = File.join(directory, "a-first.yaml")
      second = File.join(directory, "z-second.yaml")
      File.write(first, YAML.dump(base_config.merge("subscription-marker" => "first-original")))
      File.write(second, YAML.dump(base_config.merge("subscription-marker" => "second-original")))
      originals = [first, second].to_h { |path| [path, File.binread(path)] }
      original_swap = ClashPatch.method(:atomic_swap_paths)
      swaps = 0
      fail_second_commit = lambda do |left, right|
        swaps += 1
        raise IOError, "injected second profile commit failure" if swaps == 2

        original_swap.call(left, right)
      end

      results = ClashPatch.stub(:atomic_swap_paths, fail_second_commit) do
        ClashPatch.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"),
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 3
        )
      end

      assert_equal :batch_rolled_back, results.fetch(0).fetch(:status)
      assert_equal :io_error, results.fetch(1).fetch(:status)
      assert_operator swaps, :>=, 3
      originals.each { |path, original| assert_equal original, File.binread(path), path }
    end
  end

  def test_patcher_is_split_into_explicit_modules_and_coverage_tracks_them
    expected = {
      "transform.rb" => :patch,
      "backups.rb" => :create_versioned_backup,
      "mihomo.rb" => :validate_with_mihomo,
      "profile_writer.rb" => :patch_path,
      "subscriptions.rb" => :safe_update_all,
      "runtime.rb" => :activate_updated_profile,
      "cli.rb" => :cli
    }
    module_root = File.join(ROOT, "clash-patch/scripts/macos/patch_profiles")
    expected.each do |filename, method_name|
      path = File.join(module_root, filename)
      assert File.file?(path), filename
      source = File.read(path)
      assert_match(/^module ClashPatch$/, source, filename)
      assert_match(/^  module_function$/, source, filename)
      assert_equal path, ClashPatch.method(method_name).source_location.first, method_name
    end

    coverage_source = File.read(File.join(ROOT, "tests/coverage_ruby.rb"))
    assert_includes coverage_source, 'Dir.glob(File.join(MACOS_RUBY_ROOT, "**", "*.rb"))'
    assert_includes coverage_source, "MINIMUM_MODULE_LINE_COVERAGE"
  end

  def test_cli_rejects_unknown_options_and_safe_updates_without_a_usage_profile
    _output, error = capture_io { assert_equal 64, ClashPatch.cli(["--unknown-option"]) }
    assert_includes error, "参数错误"

    Dir.mktmpdir do |directory|
      _output, error = capture_io do
        assert_equal 64, ClashPatch.cli(["--profile-dir", directory, "--safe-update-all"])
      end
      assert_includes error, "必须指定用途档位"
    end
  end

  def test_cli_dry_run_reports_each_profile_without_calling_the_mihomo_validator
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      output, error = capture_io do
        assert_equal 0, ClashPatch.cli(["--profile-dir", directory, "--policy", POLICY_PATH, "--dry-run"])
      end
      assert_includes output, "friend.yaml"
      assert_empty error
    end
  end

  def test_cli_backup_commands_delegate_without_exposing_backup_contents
    Dir.mktmpdir do |directory|
      ClashPatch.stub(:list_backups, ["backup-id"]) do
        output, = capture_io { assert_equal 0, ClashPatch.cli(["--profile-dir", directory, "--list-backups"]) }
        assert_includes output, "backup-id"
      end
      ClashPatch.stub(:compare_backup, { status: :changed }) do
        output, = capture_io do
          assert_equal 0, ClashPatch.cli(["--profile-dir", directory, "--compare-backup", "backup-id"])
        end
        assert_includes output, "changed"
      end
    end
  end

  def test_route_verifier_json_and_profile_discovery_fail_closed
    ClashPatch.stub(:controller_request, [503, "unavailable"]) do
      assert_nil ClashRouteVerifier.get_json("socket", "/proxies")
    end
    ClashPatch.stub(:controller_request, [200, "not json"]) do
      assert_nil ClashRouteVerifier.get_json("socket", "/proxies")
    end
    ClashPatch.stub(:selected_profile_name, "friend") do
      ClashPatch.stub(:default_profile_directories, ["one", "two"]) do
        ClashPatch.stub(:profile_paths, ->(directory) { directory == "two" ? ["/tmp/friend.yaml"] : [] }) do
          ClashPatch.stub(:active_profile?, ->(path, selected) { path == "/tmp/friend.yaml" && selected == "friend" }) do
            assert_equal "/tmp/friend.yaml", ClashRouteVerifier.active_profile
          end
        end
      end
    end
    ClashPatch.stub(:selected_profile_name, "missing") do
      ClashPatch.stub(:default_profile_directories, ["one", "two"]) do
        ClashPatch.stub(:profile_paths, []) do
          assert_nil ClashRouteVerifier.active_profile
        end
      end
    end
  end

  def test_route_verifier_reserves_and_releases_a_local_source_port
    port = ClashRouteVerifier.reserve_local_port
    assert_operator port, :>, 0
    listener = TCPServer.new("127.0.0.1", port)
    listener.close
  end

  def test_route_verifier_observes_a_new_matching_connection_and_reaps_curl
    calls = 0
    connections = [
      { "connections" => [{ "id" => "old", "metadata" => { "host" => "www.google.com" } }] },
      {
        "connections" => [
          { "id" => "old" },
          {
            "id" => "new",
            "metadata" => { "host" => "www.google.com", "network" => "tcp", "sourcePort" => 45_555 },
            "chains" => ["Main"]
          }
        ]
      }
    ]

    ClashRouteVerifier.stub(:get_json, ->(*_args) { entry = connections[calls]; calls += 1; entry || { "connections" => [] } }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        Process.stub(:spawn, 42) do
          Process.stub(:kill, true) do
            Process.stub(:wait, true) do
              observed = ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i)
              assert_equal "new", observed.fetch("id")
            end
          end
        end
      end
    end
  end

  def test_route_verifier_ignores_same_host_traffic_from_another_source_port
    calls = 0
    spawn_arguments = nil
    controller = lambda do |*_args|
      calls += 1
      next({ "connections" => [] }) if calls == 1

      local_port_index = spawn_arguments&.index("--local-port")
      curl_port = local_port_index ? spawn_arguments.fetch(local_port_index + 1).to_i : 45_555
      {
        "connections" => [
          {
            "id" => "background", "metadata" => {
              "host" => "www.google.com", "network" => "tcp", "sourcePort" => curl_port + 1
            }
          },
          {
            "id" => "curl", "metadata" => {
              "host" => "www.google.com", "network" => "tcp", "sourcePort" => curl_port
            }
          }
        ]
      }
    end

    ClashRouteVerifier.stub(:get_json, controller) do
      Process.stub(:spawn, ->(*arguments) { spawn_arguments = arguments; 42 }) do
        Process.stub(:kill, true) do
          Process.stub(:wait, true) do
            observed = ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i)
            assert_equal "curl", observed.fetch("id")
          end
        end
      end
    end
  end

  def test_route_verifier_ignores_missing_curl_process_during_cleanup
    responses = [
      { "connections" => [] },
      {
        "connections" => [{
          "id" => "new",
          "metadata" => { "host" => "www.google.com", "network" => "tcp", "sourcePort" => 45_555 }
        }]
      }
    ]
    ClashRouteVerifier.stub(:get_json, ->(*_args) { responses.shift || { "connections" => [] } }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        Process.stub(:spawn, 42) do
          Process.stub(:kill, ->(*_args) { raise Errno::ESRCH }) do
            Process.stub(:wait, ->(*_args) { raise Errno::ECHILD }) do
              assert_equal "new", ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i).fetch("id")
            end
          end
        end
      end
    end
  end

  def test_route_verifier_returns_nil_when_no_matching_connection_is_observed
    ClashRouteVerifier.stub(:get_json, { "connections" => [] }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        ClashRouteVerifier.stub(:sleep, ->(_seconds) {}) do
          Process.stub(:spawn, 42) do
            Process.stub(:kill, true) do
              Process.stub(:waitpid, ->(*_arguments) { raise Errno::ECHILD }) do
                assert_nil ClashRouteVerifier.observe_connection(
                  "socket", "https://www.google.com", /google/i
                )
              end
            end
          end
        end
      end
    end
  end

  def test_route_verifier_gracefully_reaps_a_finished_curl_process
    signals = []
    waits = [nil, [42, Struct.new(:success?).new(true)]]
    Process.stub(:kill, ->(signal, process_id) { signals << [signal, process_id] }) do
      Process.stub(:waitpid, ->(*_arguments) { waits.shift }) do
        assert_nil ClashRouteVerifier.terminate_process(42, grace_seconds: 1)
      end
    end
    assert_equal [["TERM", 42]], signals
    assert_empty waits
  end

  def test_route_verifier_returns_false_when_profile_loading_raises
    ClashPatch.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:active_profile, -> { raise IOError, "profile disappeared" }) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
  end

  def test_route_verifier_fails_closed_at_every_discovery_boundary
    ClashPatch.stub(:controller_socket, nil) do
      ClashRouteVerifier.stub(:active_profile, "/tmp/friend.yaml") do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
    ClashPatch.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:active_profile, nil) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end

    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      ClashPatch.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashPatch.stub(:detect_main_group, nil) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          ClashPatch.stub(:existing_ai_group, nil) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          ClashRouteVerifier.stub(:get_json, { "proxies" => [] }) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          direct_proxies = {
            "proxies" => {
              "Main" => { "now" => "DIRECT" },
              "AI" => { "now" => "Japan" }
            }
          }
          ClashRouteVerifier.stub(:get_json, direct_proxies) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
        end
      end
    end
  end

  def test_route_verifier_reports_a_full_healthy_route_check
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = { "proxies" => {
        "Main" => { "now" => "Taiwan" }, "AI" => { "now" => "Japan" }
      } }
      observations = [
        { "chains" => ["Taiwan", "Main"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] }
      ]
      ClashPatch.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, proxies) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args) { observations.shift }) do
              output = StringIO.new
              assert ClashRouteVerifier.run(output: output)
              assert_includes output.string, "Google：通过"
              assert_includes output.string, "Claude：通过"
            end
          end
        end
      end
    end
  end

  def test_route_verifier_rejects_an_unrelated_selector_for_google
    proxies = {
      "Main" => { "now" => "Taiwan" },
      "AI" => { "now" => "Japan" },
      "Gaming" => { "now" => "GameNode" }
    }
    refute ClashRouteVerifier.route_passes?(
      ["GameNode", "Gaming"], proxies: proxies, kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["Google"], proxies: proxies.merge("Google" => { "now" => "" }), kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["DIRECT", "Google"], proxies: proxies.merge("Google" => { "now" => "DIRECT" }), kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
  end

  def test_route_verifier_accepts_a_user_google_proxy_group
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Google" => { "type" => "Selector", "now" => "Singapore" }
      } }
      observations = [
        { "chains" => ["Singapore", "Google"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] }
      ]
      ClashPatch.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, proxies) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
    end
  end

  def test_safe_update_rejects_two_paths_to_the_same_inode
    Dir.mktmpdir do |directory|
      first = File.join(directory, "first.yaml")
      second = File.join(directory, "second.yaml")
      File.write(first, YAML.dump(base_config))
      File.link(first, second)

      result = ClashPatch.safe_update_all(
        targets: [{ name: "first", path: first }, { name: "second", path: second }],
        backup_root: File.join(directory, "backups"),
        policy: @policy, usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config) },
        validator: ->(_path) { true }
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :duplicate_target, result.fetch(:reason)
    end
  end

  def test_cli_rejects_an_empty_profile_directory
    Dir.mktmpdir do |directory|
      output, error = capture_io do
        assert_equal 1, ClashPatch.cli([
          "--json", "--profile-dir", directory, "--policy", POLICY_PATH,
          "--usage-profile", "1", "--no-reload"
        ])
      end
      assert_empty error
      result = JSON.parse(output)
      assert_equal "failed", result.fetch("status")
      assert_equal "no_profiles", result.fetch("code")
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
