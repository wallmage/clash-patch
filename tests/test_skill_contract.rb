require "json"
require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SKILL = File.join(ROOT, "clash-patch")

class SkillContractTest < Minitest::Test
  REQUIRED_PUBLIC_FILES = %w[
    README.md
    clash-patch/SKILL.md
    clash-patch/agents/openai.yaml
    clash-patch/references/patch-policy.md
    clash-patch/references/policy.json
    clash-patch/scripts/install_macos.sh
    clash-patch/scripts/install_windows.ps1
    clash-patch/scripts/uninstall_macos.sh
    clash-patch/scripts/uninstall_windows.ps1
    clash-patch/scripts/macos/patch_profiles.rb
    clash-patch/scripts/windows/clash_verge_global.js
    .github/workflows/test.yml
    tests/fixtures/main_group_cases.json
    tests/generate_windows_policy.rb
    tests/test_macos_patcher.rb
    tests/test_skill_contract.rb
    tests/test_windows_installer.ps1
    tests/test_windows_patcher.js
    LICENSE
  ].freeze

  def test_all_distribution_files_exist
    missing = REQUIRED_PUBLIC_FILES.reject { |path| File.file?(File.join(ROOT, path)) }
    assert_empty missing, "missing public files: #{missing.join(', ')}"
  end

  def test_tests_are_distributed_but_working_material_is_ignored
    ignore = File.read(File.join(ROOT, ".gitignore"))
    assert_includes ignore.lines.map(&:strip), "docs/"
    assert_includes ignore.lines.map(&:strip), "tests/baseline.md"
    refute_includes ignore.lines.map(&:strip), "tests/"
    assert_includes ignore.lines.map(&:strip), "dist/"
  end

  def test_skill_frontmatter_contains_only_name_and_description
    skip unless File.file?(File.join(SKILL, "SKILL.md"))

    source = File.read(File.join(SKILL, "SKILL.md"))
    frontmatter = source.match(/\A---\n(.*?)\n---/m)
    refute_nil frontmatter
    metadata = YAML.safe_load(frontmatter[1])
    assert_equal %w[description name], metadata.keys.sort
    assert_equal "clash-patch", metadata["name"]
    assert_match(/\AUse when\b/, metadata["description"])
  end

  def test_openai_metadata_invokes_skill_in_chinese
    skip unless File.file?(File.join(SKILL, "agents/openai.yaml"))

    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))
    assert_includes metadata.dig("interface", "default_prompt"), "$clash-patch"
    assert_match(/[\p{Han}]/, metadata.dig("interface", "default_prompt"))
  end

  def test_skill_contains_required_chinese_user_contract
    skip unless File.file?(File.join(SKILL, "SKILL.md"))

    source = File.read(File.join(SKILL, "SKILL.md"))
    %w[简体中文 所有订阅 ClashX\ Meta Clash\ Verge\ Rev 深度测试 截图 未验证].each do |text|
      assert_includes source, text.gsub("\\ ", " ")
    end
    %w[ipinfo.cv/webrtc-check ip.net.coffee/dns ip.net.coffee/webrtc].each do |url|
      assert_includes source, url
    end
  end

  def test_public_tree_contains_no_personal_provider_or_machine_data
    files = Dir.glob(File.join(ROOT, "{README.md,clash-patch/**/*}"), File::FNM_EXTGLOB).select { |path| File.file?(path) }
    source = files.map { |path| File.binread(path).force_encoding("UTF-8").scrub }.join("\n")
    refute_match(%r{/Users/[^/\s]+}, source)
    refute_match(%r{https?://[^\s]+(?:token|subscribe|subscription)[^\s]*=}i, source)
  end

  def test_policy_is_valid_json_and_omits_forbidden_ai_domains
    path = File.join(SKILL, "references/policy.json")
    skip unless File.file?(path)

    policy = JSON.parse(File.read(path))
    assert_includes policy.fetch("forbidden_ai_domains"), "raw.githubusercontent.com"
    assert_includes policy.fetch("forbidden_ai_domains"), "storage.googleapis.com"
    ai_rules = policy.fetch("ai_rules").join("\n")
    refute_includes ai_rules, "raw.githubusercontent.com"
    refute_includes ai_rules, "storage.googleapis.com"
    refute_includes policy.fetch("proxy_bootstrap_resolvers").join("\n"), "223.5.5.5"
    refute_includes policy.fetch("default_bootstrap_resolvers").join("\n"), "223.5.5.5"
  end

  def test_windows_policy_is_generated_from_canonical_json
    generator = File.join(ROOT, "tests/generate_windows_policy.rb")
    assert system(RbConfig.ruby, generator, "--check"), "Windows policy block is stale"
  end

  def test_readme_is_chinese_and_explains_both_persistence_mechanisms
    path = File.join(ROOT, "README.md")
    skip unless File.file?(path)

    source = File.read(path)
    assert_operator source.scan(/[\p{Han}]/).length, :>, 200
    %w[LaunchAgent WatchPaths 全局扩展脚本 DNS WebRTC 家宽 台湾 日本].each do |term|
      assert_includes source, term
    end
  end

  def test_macos_installer_is_event_driven_and_not_resident
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    assert_includes source, "RunAtLoad"
    assert_includes source, "WatchPaths"
    refute_includes source, "KeepAlive"
    assert_includes source, "~/.config/clash.meta"
    assert_includes source, "launchctl"
    assert_match(/[\p{Han}]/, source)
    assert_includes source, "plutil"
    refute_includes source, "<plist version="
    assert_includes source, "--print-watch-paths"
    assert_includes source, "restoreTunProxy"
    refute_includes source, "tunOverridden"
    assert_includes source, "osascript"
    assert_includes source, "--print-tun-state"
    refute_includes source, "read_tun_enabled"
  end

  def test_license_is_mit
    source = File.read(File.join(ROOT, "LICENSE"))
    assert_includes source, "MIT License"
    assert_includes source, "wallmage"
  end

  def test_uninstallers_remove_persistence_without_deleting_backups
    mac = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows = File.read(File.join(SKILL, "scripts/uninstall_windows.ps1"))
    assert_includes mac, "bootout"
    assert_operator mac.index("plutil -extract Label"), :<, mac.index("launchctl bootout")
    assert_includes windows, "CLASH PATCH BEGIN"
    refute_match(/Remove-Item[^\n]+backups/i, windows)
    refute_match(%r{/bin/rm[^\n]+backups}i, mac)
  end
end
