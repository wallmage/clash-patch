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
    clash-patch/scripts/macos/verify_routes.rb
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

  def test_agent_instructions_execute_clear_requests_without_reconfirmation
    instructions = File.read(File.join(ROOT, "AGENTS.md"))
    assert_includes instructions, "从实现、验证、安装到提交推送连续做完"
    assert_includes instructions, "不得要求用户重复确认"
    assert_includes instructions, "不得自行新增需求汇总、入口、方案或计划文档"
    assert_includes instructions, "实际修改项目后"
    assert_includes instructions, "自动完成本地测试、commit 和 push"
    assert_includes instructions, "不得把“尚未 commit 或 push”作为常规收尾"
  end

  def test_public_guides_stay_concise_and_separate_detailed_policy
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))

    assert_operator readme.lines.length, :<=, 110
    assert_operator skill.lines.length, :<=, 80
    assert_includes skill, "详细产品规则和全部状态以"
  end

  def test_skill_exposes_patch_and_diagnostics_as_separate_modules
    skill = File.read(File.join(SKILL, "SKILL.md"))
    metadata = YAML.safe_load(skill.match(/\A---\n(.*?)\n---/m)[1])

    assert_includes metadata.fetch("description"), "diagnose"
    assert_includes metadata.fetch("description"), "slow"
    assert_includes metadata.fetch("description"), "intermittent"
    assert_includes skill, "Patch 模块"
    assert_includes skill, "Diagnostics 模块"
    assert_includes skill, "不能因为用户提到 Clash 就先运行补丁"
    assert_includes skill, "Diagnostics 默认只读"
  end

  def test_diagnostics_uses_a_universal_evidence_loop
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "## Diagnostics 模块"
    %w[复现 影响范围 对照 时间线 假设 证据 排除 最小改动 复测 观察窗口].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "不要求用户先知道该查什么"
    assert_includes policy, "任何外部记录都不是诊断前提"
    assert_includes policy, "没有证据不能下结论"
    assert_includes policy, "按现象选择必要层级，不是每次全部执行"
    assert_includes policy, "始终记录时间、操作系统、活动网络和原始症状"
    assert_includes policy, "只有影响范围或证据指向共同网络路径时"
    assert_includes policy, "保留所有尚未证实的解释"
    assert_includes policy, "只有充分反证"
  end

  def test_diagnostics_separates_clues_from_conclusions
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[已确认 有力支持 尚未证实 已排除].each { |state| assert_includes policy, state }
    assert_includes policy, "单个现象或相关性只能算线索"
    assert_includes policy, "第二种独立证据"
    assert_includes policy, "反证"
    assert_includes policy, "解释全部已知现象"
  end

  def test_diagnostics_selects_tools_by_the_observed_symptom
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[浏览器 DNS 分流 TCP TLS 首字节 丢包 进程 系统记录 应用日志].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "一个应用异常而其他应用正常"
    assert_includes policy, "不得直接执行 Patch 模块"
    assert_includes policy, "不得把完整补丁验收当成每次诊断的固定步骤"
  end

  def test_diagnostics_finishes_with_repair_explanation_and_verification
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "能在本机安全修复"
    assert_includes policy, "由代理自动完成"
    assert_includes policy, "本机无法修复"
    assert_includes policy, "在线搜索"
    assert_includes policy, "官方或第一方资料"
    assert_includes policy, "一次只改变一个变量"
    assert_includes policy, "修复前的状态"
    assert_includes policy, "原始症状"
    assert_includes policy, "发生了什么"
    assert_includes policy, "为什么会这样"
  end

  def test_diagnostics_does_not_hide_a_full_patch_behind_a_targeted_repair
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "Patch 模块会应用完整安全策略，不是单项修复器"
    assert_includes policy, "包含与已确认问题无关的改动"
    assert_includes policy, "不得把完整 Patch 伪装成单项修复"
    assert_includes skill, "Patch 专用验收"
    assert_includes skill, "Diagnostics 不固定执行"
    assert_includes skill, "单项 Clash 配置修复仍留在 Diagnostics"
    assert_includes policy, "只有用户明确要求完整安全增强时才进入 Patch"
    assert_includes policy, "macOS 单项配置事务"
    assert_includes policy, "依次清除 Fake-IP 和 DNS 缓存"
    assert_includes policy, "Windows 当前没有安全的即时单项配置写入路径"
    assert_includes policy, "## Patch 验证标准"
  end

  def test_diagnostics_defines_observation_by_the_original_failure_pattern
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "可以立即重复的问题"
    assert_includes policy, "修复前后各连续测试三次"
    assert_includes policy, "最近记录中的典型复发间隔"
    assert_includes policy, "同样长的时间窗"
    assert_includes policy, "curl.exe"
    assert_includes policy, "Test-NetConnection"
    assert_includes policy, "Test-Connection"
    assert_includes policy, "采集工具或会话"
    assert_includes policy, "停止与清理方法"
    assert_includes policy, "未建立监测"
    assert_includes policy, "只有已经确认采集器正在运行时"
  end

  def test_diagnostics_protects_application_state_and_log_secrets
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[访问令牌 refresh\ token ID\ token Authorization Cookie 账号标识 会话内容].each do |term|
      assert_includes policy, term.gsub("\\ ", " ")
    end
    assert_includes policy, "只读取必要时间窗"
    assert_includes policy, "未保存工作"
    assert_includes policy, "关闭应用、注销账号、删除或隔离缓存、Repair、重装或降级"
    assert_includes policy, "明确授权"
    assert_includes policy, "相同服务不等于相同账号、接口或认证方式"
    assert_includes policy, "登录、支付、发消息"
    assert_includes policy, "停止重复提交"
    assert_includes policy, "密码、验证码、MFA 或硬件确认"
  end

  def test_windows_diagnostics_does_not_claim_an_instant_runtime_patch
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "Windows 客户端运行时不得修改当前配置"
    assert_includes policy, "不能写成已立即生效"
    assert_includes policy, "不得为了复测而触发订阅切换、节点切换"
    assert_includes policy, "代理组切换或 TUN 切换"
    assert_includes policy, "更不得重启客户端"
    assert_includes policy, "已更新，尚未生效"
  end

  def test_diagnostics_does_not_bake_in_the_reference_incident
    public_source = Dir.glob(File.join(ROOT, "{README.md,clash-patch/**/*}"), File::FNM_EXTGLOB)
                       .select { |path| File.file?(path) }
                       .map { |path| File.binread(path).force_encoding("UTF-8").scrub }
                       .join("\n")

    %w[MESL 5.86GB 702.9MB MAO-5G].each { |term| refute_includes public_source, term }
    refute_match(/7\s*月\s*19\s*日/, public_source)
  end

  def test_readme_and_metadata_describe_diagnostics
    readme = File.read(File.join(ROOT, "README.md"))
    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))

    assert_includes readme, "Patch"
    assert_includes readme, "Diagnostics"
    assert_includes metadata.dig("interface", "short_description"), "诊断"
    assert_includes metadata.dig("interface", "default_prompt"), "诊断"
  end

  def test_documentation_distinguishes_written_tun_settings_from_runtime_state
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))

    refute_includes policy, "TUN：已开启"
    assert_includes policy, "配置中的 TUN：已写入；运行状态：已自动刷新并验证"
    assert_includes skill, "检查 TUN、DNS、外网连通性和原有代理组选择"
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

  def test_skill_names_every_guard_from_the_network_outage
    source = File.read(File.join(SKILL, "SKILL.md"))

    assert_includes source, "保留 `default-nameserver` 和 `proxy-server-nameserver`"
    assert_includes source, "大陆 IP DoH"
    assert_includes source, "direct-nameserver-follow-policy"
    assert_includes source, "不得把节点启动解析改成 `1.1.1.1` 或 `8.8.8.8`"
    assert_includes source, "不安装 LaunchAgent、`WatchPaths` 或目录监听"
    assert_includes source, "REALITY `short-id`"
    assert_includes source, "只允许通过本地控制器自动刷新"
    assert_includes source, "失败时立即恢复原文件和原运行配置"
    assert_includes source, "`config.yaml` 是 ClashX Meta 的默认基础配置"
    assert_includes source, "不得删除"
  end

  def test_skill_automates_route_and_browser_verification_when_computer_use_exists
    source = File.read(File.join(SKILL, "SKILL.md"))

    assert_includes source, "访问 Google 时必须经过当前主代理节点"
    assert_includes source, "访问 OpenAI、Anthropic 或 Claude 时必须经过 AI 分组当前节点"
    assert_includes source, "macOS 或 Windows 环境只要提供 Computer Use，就由代理连续完成"
    assert_includes source, "当前环境没有 Computer Use 时，给出中文逐步操作"
  end


  def test_macos_route_verifier_checks_main_and_ai_destinations
    source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))

    %w[Google OpenAI Anthropic Claude].each { |name| assert_includes source, name }
    assert_includes source, 'chains.include?(expected.fetch(kind))'
    assert_includes source, 'existing.include?(entry["id"])'
  end

  def test_skill_reuses_user_ai_groups_and_creates_independent_node_selectors
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    ruby_patcher = File.read(File.join(SKILL, "scripts/macos/patch_profiles.rb"))
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

    assert_includes skill, "已有可选 AI 分组时，直接复用"
    assert_includes skill, "不得修改它的成员或当前选择"
    assert_includes skill, "全部可用的真实节点和代理提供者"
    assert_includes skill, "主代理组与 AI 节点互不影响"
    assert_includes skill, "不得创建第二个安全代理分组"
    assert_includes policy, "不得替用户选择台湾、日本或任何家宽节点"
    refute_includes ruby_patcher, "def ensure_safe_group"
    refute_includes ruby_patcher, "def home_candidate"
    refute_includes windows_patcher, "function clashPatchEnsureSafeGroup"
    refute_includes windows_patcher, "function clashPatchHomeCandidate"
  end

  def test_agents_requires_requirement_docs_to_change_with_behavior
    agents = File.read(File.join(ROOT, "AGENTS.md"))

    assert_includes agents, "功能需求变化时"
    assert_includes agents, "代码、Skill 和相关产品文档必须在同一次改动中同步更新"
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
    assert_equal [
      "https://223.5.5.5/dns-query#DIRECT",
      "https://1.12.12.12/dns-query#DIRECT"
    ], policy.fetch("direct_resolvers")

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
    assert_includes policy, "/cache/fakeip/flush"
    assert_includes policy, "/cache/dns/flush"
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
