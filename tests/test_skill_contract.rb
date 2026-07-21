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
    clash-patch/scripts/install_windows.cmd
    clash-patch/scripts/uninstall_macos.sh
    clash-patch/scripts/uninstall_windows.ps1
    clash-patch/scripts/uninstall_windows.cmd
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
    prompt = metadata.dig("interface", "default_prompt")
    assert_includes prompt, "$clash-patch"
    assert_includes prompt, "当前存储位置"
    assert_includes prompt, "绝对不要退出、停止或重启 Clash 客户端"
    assert_match(/[\p{Han}]/, prompt)
  end

  def test_skill_contains_required_chinese_user_contract
    skip unless File.file?(File.join(SKILL, "SKILL.md"))

    source = File.read(File.join(SKILL, "SKILL.md"))
    %w[简体中文 当前存储位置 ClashX\ Meta Clash\ Verge\ Rev 深度测试 截图 未验证].each do |text|
      assert_includes source, text.gsub("\\ ", " ")
    end
    %w[ipinfo.cv/webrtc-check ip.net.coffee/dns ip.net.coffee/webrtc].each do |url|
      assert_includes source, url
    end
  end

  def test_skill_reuses_ai_groups_and_never_auto_selects_nodes
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    ruby_patcher = File.read(File.join(SKILL, "scripts/macos/patch_profiles.rb"))
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

    assert_includes skill, "已有可选 AI 分组时，直接复用"
    assert_includes skill, "不得修改它的成员或当前选择"
    assert_includes skill, "不得创建第二个安全代理分组"
    assert_includes policy, "不得替用户选择台湾、日本或任何家宽节点"
    refute_includes ruby_patcher, "def ensure_safe_group"
    refute_includes ruby_patcher, "def home_candidate"
    refute_includes windows_patcher, "function clashPatchEnsureSafeGroup"
    refute_includes windows_patcher, "function clashPatchHomeCandidate"
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
    refute policy.key?("proxy_bootstrap_resolvers")
    refute policy.key?("default_bootstrap_resolvers")
  end

  def test_managed_dns_policy_uses_bootstrap_free_ip_doh_without_site_exceptions
    policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    assert_equal [
      "https://94.140.14.140/dns-query",
      "https://94.140.14.141/dns-query",
      "https://101.101.101.101/dns-query"
    ], policy.fetch("resolvers")

    public_source = Dir.glob(File.join(ROOT, "{README.md,clash-patch/**/*}"), File::FNM_EXTGLOB)
                       .select { |path| File.file?(path) }
                       .map { |path| File.binread(path).force_encoding("UTF-8").scrub }
                       .join("\n")
    refute_includes public_source.downcase, "aiping.cn"

    policy_doc = File.read(File.join(SKILL, "references/patch-policy.md"))
    assert_includes policy_doc, "无需先解析解析器域名"
  end

  def test_windows_policy_is_generated_from_canonical_json
    generator = File.join(ROOT, "tests/generate_windows_policy.rb")
    assert system(RbConfig.ruby, generator, "--check"), "Windows policy block is stale"
  end

  def test_windows_policy_generator_uses_binary_io
    source = File.read(File.join(ROOT, "tests/generate_windows_policy.rb"))
    assert_includes source, "File.binread"
    assert_includes source, "File.binwrite"
    refute_match(/File\.write\(engine_path/, source)
  end

  def test_readme_is_chinese_and_explains_safe_refresh_behavior
    path = File.join(ROOT, "README.md")
    skip unless File.file?(path)

    source = File.read(path)
    assert_operator source.scan(/[\p{Han}]/).length, :>, 200
    %w[单次运行 当前存储位置 全局扩展脚本 DNS WebRTC 家宽 台湾 日本].each do |term|
      assert_includes source, term
    end
    %w[游戏 语音 视频 QUIC 第三方].each { |term| assert_includes source, term }
  end

  def test_policy_documents_dns_filters_and_safety_migrations
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    %w[exclude-filter empty-fallback skip-cert-verify ecs 160.79.104.0/21 ai.com proxy-server-nameserver system 二次转换].each do |term|
      assert_includes policy, term
    end
  end

  def test_macos_installer_is_one_shot_and_removes_legacy_persistence
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    refute_includes source, "RunAtLoad"
    refute_includes source, "WatchPaths"
    refute_includes source, "KeepAlive"
    patcher = File.read(File.join(SKILL, "scripts/macos/patch_profiles.rb"))
    assert_includes patcher, 'File.join(home, ".config", "clash.meta")'
    assert_includes source, "launchctl bootout"
    assert_match(/[\p{Han}]/, source)
    assert_includes source, "plutil"
    refute_includes source, "<plist version="
    refute_includes source, "launchctl bootstrap"
    refute_includes source, "osascript"
    assert_match(/\A#!\/bin\/sh\nset -eu\nset -f\n/, source)
    refute_match(/\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/, source)
  end

  def test_installers_preflight_and_uninstallers_restore_owned_settings
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    mac_uninstall = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows_install = File.binread(File.join(SKILL, "scripts/install_windows.ps1"))
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1"))
    patcher = File.read(File.join(SKILL, "scripts/macos/patch_profiles.rb"))

    assert_operator mac_install.index('id -u'), :<, mac_install.index('/bin/mkdir -p')
    assert_operator mac_install.index('--print-core-status'), :<, mac_install.index('/bin/mkdir -p')
    assert_operator mac_install.index('plutil -extract Label'), :<, mac_install.index('launchctl bootout')
    assert_operator mac_install.index('ProgramArguments.0'), :<, mac_install.index('launchctl bootout')
    assert_operator mac_install.index('ProgramArguments.1'), :<, mac_install.index('launchctl bootout')
    assert_includes mac_install, "com.clashpatch.profiles"
    assert_includes mac_install, "com.wallny.clash-profile-patcher"
    assert_includes mac_uninstall, "com.clashpatch.profiles"
    assert_includes mac_uninstall, "com.wallny.clash-profile-patcher"
    refute_includes mac_install, "launchctl bootstrap"
    refute_includes mac_install, "WatchPaths"
    assert_includes mac_uninstall, "restoreTunProxy"
    assert_includes mac_uninstall, "RestoreTunPresent"
    assert_includes mac_uninstall, "RestoreTunKnown"
    assert_operator mac_uninstall.index('ProgramArguments.0'), :<, mac_uninstall.index('launchctl bootout')
    assert_operator mac_uninstall.index('ProgramArguments.1'), :<, mac_uninstall.index('launchctl bootout')
    assert_includes patcher, "File::EXCL"

    assert_equal "\xEF\xBB\xBF".b, windows_install.byteslice(0, 3)
    assert_equal "\xEF\xBB\xBF".b, windows_uninstall.byteslice(0, 3)
    assert_equal "\xEF\xBB\xBF".b, windows_tests.byteslice(0, 3)
    assert_includes windows_install.force_encoding("UTF-8"), "MihomoPath"
    assert_includes windows_install, "Test-MihomoVersion"
    assert_includes windows_install, "OriginalBytes"
    assert_includes windows_install, "install-state.json"
    assert_includes windows_install, "SetAccessRuleProtection"
    assert_includes windows_install, "S-1-5-18"
    assert_includes windows_install, "S-1-5-32-544"
    assert_includes windows_uninstall, "InstalledSha256"
  end


  def test_skill_and_scripts_never_stop_or_restart_clash
    skill = File.read(File.join(SKILL, "SKILL.md"))
    readme = File.read(File.join(ROOT, "README.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_install = File.binread(File.join(SKILL, "scripts/install_windows.ps1")).force_encoding("UTF-8")
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1")).force_encoding("UTF-8")

    [skill, readme, policy].each do |source|
      assert_includes source, "绝对不要退出、停止或重启 Clash 客户端"
      refute_includes source, "请先从托盘菜单完全退出"
      refute_includes source, "退出客户端，再"
    end
    [mac_install, windows_install, windows_uninstall].each do |source|
      refute_match(/osascript[^\n]*(?:quit|terminate)/i, source)
      refute_match(/Stop-Process|taskkill|killall/i, source)
      refute_includes source, "请先从托盘菜单完全退出"
      refute_includes source, "退出客户端，再"
    end
  end

  def test_validation_timeout_and_idempotence_guards_are_documented
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac = File.read(File.join(SKILL, "scripts/macos/patch_profiles.rb"))
    windows = File.binread(File.join(SKILL, "scripts/install_windows.ps1")).force_encoding("UTF-8")

    [skill, policy].each do |source|
      assert_includes source, "30 秒"
      assert_includes source, "二次转换"
    end
    assert_includes mac, "VALIDATION_TIMEOUT_SECONDS = 30"
    assert_includes mac, ":non_idempotent"
    refute_match(/^\s*def (?:reload|select_proxy)\b/, mac)
    assert_includes windows, "WaitForExit($TimeoutSeconds * 1000)"
    assert_includes windows, '$process.Kill()'
  end

  def test_reality_short_id_scope_is_documented
    readme = File.read(File.join(ROOT, "README.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    assert_match(/macOS[^\n]*REALITY `short-id`|REALITY `short-id`[^\n]*macOS/, readme)
    assert_match(/macOS[^\n]*REALITY `short-id`|REALITY `short-id`[^\n]*macOS/, policy)
  end

  def test_ci_covers_production_runtimes_and_pins_actions
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    uses = workflow.scan(/^\s*- uses:\s*(\S+)/).flatten

    refute_empty uses
    uses.each { |entry| assert_match(/@[0-9a-f]{40}\z/, entry, entry) }
    assert_includes workflow, "runs-on: macos-15"
    assert_includes workflow, "/usr/bin/ruby tests/test_macos_patcher.rb"
    assert_includes workflow, "shell: powershell"
    assert_includes workflow, "Get-Command powershell.exe"
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
    assert_operator mac.index("ProgramArguments.0"), :<, mac.index("launchctl bootout")
    assert_operator mac.index("ProgramArguments.1"), :<, mac.index("launchctl bootout")
    assert_includes windows, "CLASH PATCH BEGIN"
    refute_match(/Remove-Item[^\n]+backups/i, windows)
    refute_match(%r{/bin/rm[^\n]+backups}i, mac)
  end
end
