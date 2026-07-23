require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
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
    clash-patch/references/result-contract.json
    clash-patch/scripts/install_macos.sh
    clash-patch/scripts/install_windows.ps1
    clash-patch/scripts/install_windows.cmd
    clash-patch/scripts/uninstall_macos.sh
    clash-patch/scripts/uninstall_windows.ps1
    clash-patch/scripts/uninstall_windows.cmd
    clash-patch/scripts/macos/patch_profiles.rb
    clash-patch/scripts/macos/patch_profiles/transform.rb
    clash-patch/scripts/macos/patch_profiles/backups.rb
    clash-patch/scripts/macos/patch_profiles/mihomo.rb
    clash-patch/scripts/macos/patch_profiles/profile_writer.rb
    clash-patch/scripts/macos/patch_profiles/subscriptions.rb
    clash-patch/scripts/macos/patch_profiles/runtime.rb
    clash-patch/scripts/macos/patch_profiles/cli.rb
    clash-patch/scripts/macos/result_contract.rb
    clash-patch/scripts/macos/verify_routes.rb
    clash-patch/scripts/windows/verify_routes.ps1
    clash-patch/scripts/windows/clash_verge_global.js
    clash-patch/scripts/windows/result_contract.ps1
    clash-patch/scripts/windows/install_windows/common.ps1
    clash-patch/scripts/windows/install_windows/yaml.ps1
    clash-patch/scripts/windows/install_windows/profiles.ps1
    clash-patch/scripts/windows/install_windows/mihomo.ps1
    clash-patch/scripts/windows/install_windows/transaction.ps1
    clash-patch/scripts/windows/install_windows/script_js.ps1
    clash-patch/scripts/windows/install_windows/safe_update.ps1
    .github/workflows/test.yml
    tests/fixtures/main_group_cases.json
    tests/baseline.md
    tests/coverage_ruby.rb
    tests/generate_windows_policy.rb
    tests/run_macos_production_probes.rb
    tests/test_macos_patcher.rb
    tests/test_macos_wrappers.rb
    tests/test_mutation_safety.rb
    tests/test_skill_contract.rb
    tests/test_windows_installer.ps1
    tests/test_windows_patcher.js
    docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md
    LICENSE
  ].freeze

  def windows_installer_source
    paths = [File.join(SKILL, "scripts/install_windows.ps1")] +
      Dir[File.join(SKILL, "scripts/windows/install_windows/*.ps1")].sort
    paths.map { |path| File.binread(path).force_encoding("UTF-8") }.join("\n")
  end

  def mac_patcher_source
    paths = [File.join(SKILL, "scripts/macos/patch_profiles.rb")] +
      Dir[File.join(SKILL, "scripts/macos/patch_profiles/*.rb")].sort
    paths.map { |path| File.read(path) }.join("\n")
  end

  def test_all_distribution_files_exist
    missing = REQUIRED_PUBLIC_FILES.reject { |path| File.file?(File.join(ROOT, path)) }
    assert_empty missing, "missing public files: #{missing.join(', ')}"
  end

  def test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path
    release_files = REQUIRED_PUBLIC_FILES.select do |path|
      path == "README.md" || path == "LICENSE" || path.start_with?("clash-patch/")
    end
    Dir.mktmpdir("clash-patch-release-") do |directory|
      package_name = "Clash Patch 发布包"
      staging = File.join(directory, "staging")
      package_root = File.join(staging, package_name)
      release_files.each do |relative|
        destination = File.join(package_root, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(ROOT, relative), destination, preserve: true)
      end

      archive = File.join(directory, "clash-patch-release.tar")
      _output, _error, status = Open3.capture3(
        "tar", "-cf", archive, "-C", staging, package_name
      )
      assert status.success?, "release archive creation failed"

      listing, _error, status = Open3.capture3("tar", "-tf", archive)
      assert status.success?, "release archive listing failed"
      entries = listing.lines.map(&:chomp)
      refute entries.any? { |entry| entry.start_with?("/") || entry.split("/").include?("..") }
      release_files.each { |relative| assert_includes entries, "#{package_name}/#{relative}" }

      extracted = File.join(directory, "extracted")
      FileUtils.mkdir_p(extracted)
      _output, _error, status = Open3.capture3("tar", "-xf", archive, "-C", extracted)
      assert status.success?, "release archive extraction failed"
      unpacked = File.join(extracted, package_name)
      install_macos = File.join(unpacked, "clash-patch/scripts/install_macos.sh")
      uninstall_macos = File.join(unpacked, "clash-patch/scripts/uninstall_macos.sh")
      patcher = File.join(unpacked, "clash-patch/scripts/macos/patch_profiles.rb")
      windows_engine = File.join(unpacked, "clash-patch/scripts/windows/clash_verge_global.js")
      assert File.executable?(install_macos)
      assert File.executable?(uninstall_macos)

      [install_macos, uninstall_macos].each do |script|
        _output, _error, status = Open3.capture3("sh", "-n", script)
        assert status.success?, "extracted shell entrypoint failed syntax validation"
        _output, _error, status = Open3.capture3({ "HOME" => directory }, "sh", script, "--help")
        assert status.success?, "extracted shell help entrypoint failed"
      end
      _output, _error, status = Open3.capture3(RbConfig.ruby, patcher, "--help")
      assert status.success?, "extracted Ruby entrypoint failed"
      _output, _error, status = Open3.capture3("node", "--check", windows_engine)
      assert status.success?, "extracted Windows JavaScript entrypoint failed syntax validation"

      profile_directory = File.join(directory, "用户 配置")
      FileUtils.mkdir_p(profile_directory)
      File.write(File.join(profile_directory, "friend.yaml"), <<~YAML)
        mixed-port: 7890
        proxies:
          - name: node
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Main
            type: select
            proxies: [node]
        rules:
          - MATCH,Main
      YAML
      _output, _error, status = Open3.capture3(
        RbConfig.ruby, patcher, "--profile-dir", profile_directory,
        "--usage-profile", "1", "--dry-run"
      )
      assert status.success?, "extracted release could not patch a profile from a Unicode path"

      if RUBY_PLATFORM.include?("darwin")
        release_home = File.join(directory, "安装 用户")
        fake_core = File.join(
          release_home, "Applications", "ClashX Meta.app", "Contents", "Resources",
          "com.metacubex.ClashX.ProxyConfigHelper.meta"
        )
        FileUtils.mkdir_p(File.dirname(fake_core))
        File.write(fake_core, <<~SH)
          #!/bin/sh
          if [ "${1:-}" = "-v" ]; then
            printf '%s\n' 'Mihomo Meta v1.19.27 release-test'
          fi
          exit 0
        SH
        FileUtils.chmod(0o700, fake_core)
        release_env = {
          "HOME" => release_home,
          "CLASH_PATCH_PROFILE_DIR" => profile_directory,
          "CLASH_PATCH_USAGE_STATE_PATH" => File.join(release_home, "usage-profile.plist"),
          "CLASH_PATCH_USAGE_PROFILE" => nil
        }
        output, error, status = Open3.capture3(
          release_env, "sh", install_macos, "--profile", "1", "--json"
        )
        assert status.success?, "extracted public installer failed: #{error}"
        assert_empty error
        result = JSON.parse(output)
        assert_equal status.exitstatus, result.fetch("exit_code")
        assert_equal "install", result.fetch("command")
        assert result.fetch("ok")
        assert File.file?(release_env.fetch("CLASH_PATCH_USAGE_STATE_PATH"))
        patched_profile = YAML.safe_load(File.read(File.join(profile_directory, "friend.yaml")))
        assert patched_profile.fetch("rule-providers").key?("clash-patch-cn-domain")
      end
    end
  end

  def test_tests_and_product_spec_are_distributed_but_generated_material_is_ignored
    ignore = File.read(File.join(ROOT, ".gitignore"))
    ignore_lines = ignore.lines.map(&:strip)

    assert_includes ignore_lines, "docs/*"
    assert_includes ignore_lines, "!docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"
    refute_includes ignore.lines.map(&:strip), "tests/baseline.md"
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

  def test_public_guides_define_their_roles_and_point_to_detailed_policy
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes readme, "本文档面向用户"
    assert_includes readme, "给代理执行的流程规定在 `clash-patch/SKILL.md`"
    assert_includes readme, "产品规则和全部状态文案以 `clash-patch/references/patch-policy.md` 为准"
    assert_includes skill, "开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)"
    assert_includes skill, "详细产品规则和全部状态以该文件为准"
    assert_includes policy, "# Clash 补丁策略"
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

  def test_patch_module_selects_and_remembers_the_minimum_usage_profile
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_installer = windows_installer_source

    [readme, skill, policy, design].each do |document|
      %w[普通浏览 海外\ AI Claude/Claude\ Code].each do |profile|
        assert_includes document, profile.gsub("\\ ", " ")
      end
      assert_includes document, "首次"
      assert_includes document, "保存"
      assert_includes document, "修改"
    end

    assert_includes skill, "你使用网络代理主要用于哪些用途"
    assert_includes skill, "没有已保存档位"
    assert_includes skill, "明确表达 `Claude` 或 `Claude Code`"
    refute_includes skill, "语音输入中的 `cloud`"
    refute_includes readme, "语音输入中的 `cloud`"
    refute_includes policy, "语音输入把 Claude 识别为 `cloud`"
    refute_includes design, "语音输入 `cloud`"
    assert_includes policy, "只应用满足已选用途所需的最少改动"

    assert_includes mac_installer, "CLASH_PATCH_USAGE_PROFILE"
    assert_includes mac_installer, "usage-profile.plist"
    assert_includes mac_installer, "--profile"
    assert_includes windows_installer, "CLASH_PATCH_USAGE_PROFILE"
    assert_includes windows_installer, "clash-patch-usage-profile.json"
    assert_includes windows_installer, "UsageProfile"
  end

  def test_each_usage_profile_has_distinct_actions_and_acceptance_tests
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [skill, policy].each do |document|
      assert_includes document, "档位 1"
      assert_includes document, "档位 2"
      assert_includes document, "档位 3"
      assert_includes document, "Google"
      assert_includes document, "Twitter"
      assert_includes document, "ChatGPT"
      assert_includes document, "Gemini"
      assert_includes document, "Claude"
    end

    assert_includes policy, "档位 1 不修改 TUN"
    assert_includes policy, "共同国内域名直连基线"
    assert_includes policy, "档位 2 不增加 WebRTC 或 AI 分组补丁"
    assert_includes policy, "只关闭 Clash 客户端自己的系统代理开关"
    assert_includes policy, "不得清除或覆盖 AdGuard"
    assert_includes policy, "不是为了隐藏代理"
    assert_includes policy, "台湾家宽优先，其次日本家宽"
    assert_includes policy, "不得自动切换节点"
  end

  def test_profile_changes_are_safe_and_lower_profiles_do_not_run_the_full_patch
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))

    assert_includes skill, "用户可以随时改档"
    assert_includes policy, "升档"
    assert_includes policy, "降档"
    assert_includes policy, "不能为了降档覆盖后来产生的用户改动"
    assert_includes skill, "从档位 3 降到档位 1 或 2"
    assert_includes skill, "uninstall_macos.sh"
    assert_includes skill, "uninstall_windows.cmd"
    assert_includes policy, "旧订阅增强仍可能保留"
    assert_includes policy, "只有档位 3"
    assert_includes mac_installer, '--usage-profile "$USAGE_PROFILE"'
    assert_includes windows_installer, 'if ($resolvedUsageProfile -ne 3)'
    assert_includes windows_installer, '$savedUsageProfile -eq 3'
    assert_includes windows_installer, "必须先运行安全卸载"
  end

  def test_all_profiles_share_one_managed_china_domain_baseline
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy_doc = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    mac_patcher = mac_patcher_source
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

    [readme, skill, policy_doc, design].each do |document|
      assert_includes document, "共同国内域名直连基线"
      assert_includes document, "全部订阅"
    end
    provider = policy.fetch("cn_domain_provider")
    assert_equal "http", provider.fetch("type")
    assert_equal "domain", provider.fetch("behavior")
    assert_equal "mrs", provider.fetch("format")
    assert_equal 86_400, provider.fetch("interval")
    assert_includes provider.fetch("url"), "/geosite/cn.mrs"
    assert_includes mac_patcher, "patch_common_cn"
    assert_includes mac_patcher, '"rule-set:#{provider_name}"'
    assert_includes windows_patcher, "clashPatchCommonCn"
    assert_includes windows_patcher, "CLASH_PATCH_USAGE_PROFILE"
  end

  def test_known_diagnostics_cover_domestic_misrouting_and_adguard_certificate_failures
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [skill, policy].each do |document|
      assert_includes document, "第一档已知故障：国内请求误走海外"
      assert_includes document, "Kimi"
      assert_includes document, "欧陆词典"
      assert_includes document, "不得点击"
      assert_includes document, "CERTIFICATE_VERIFY_FAILED"
      assert_includes document, "不添加 Apple"
      assert_includes document, "暂未复现"
    end
  end

  def test_adguard_certificate_failures_preserve_the_global_tun_compatibility_path
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "禁止按应用调整 AdGuard 过滤范围"
      assert_includes document, "Clash TUN 存在时不得把 AdGuard 改为 `Network Extension`"
      assert_includes document, "系统代理所有权"
      assert_includes document, "PAC 查询中断"
    end

    [skill, policy, design].each do |document|
      assert_includes document, "`ProxyConfigHelper`"
      refute_includes document, "排除出错的非浏览器应用"
      refute_includes document, "调整应用过滤范围"
    end
  end

  def test_saved_profile_bounds_diagnostics_repairs_and_regression_checks
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "Patch 和 Diagnostics"
      assert_includes document, "诊断"
      assert_includes document, "档位"
    end

    assert_includes skill, "Diagnostics 每次开始都先读取本机保存的档位"
    assert_includes skill, "故障本身不能自动升档"
    assert_includes policy, "用途档位是 Diagnostics 的需求边界"
    assert_includes policy, "但不检查或修改 TUN"
    assert_includes policy, "不运行 DNS 泄漏、WebRTC 或 AI 检查"
    assert_includes policy, "共同国内域名直连基线"
    assert_includes policy, "档位 2 不运行 DNS 泄漏、WebRTC 或 AI 分组检查"
    assert_includes policy, "档位 3 的既有能力"
    assert_includes policy, "只重测可能受本次改动影响的第三档能力"
    assert_includes metadata.dig("interface", "default_prompt"), "诊断前读取用途档位"
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

  def test_long_read_only_investigations_can_use_safe_parallel_subagents
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "Sub Agent"
      assert_includes document, "超过 10 分钟"
    end
    assert_includes policy, "只读证据"
    assert_includes policy, "统一时间窗"
    assert_includes policy, "只有一个界面操作者"
    assert_includes policy, "只有一个主动流量生成者"
    assert_includes policy, "写入、更新、恢复和最终判断"
    assert_includes policy, "主代理串行完成"
  end

  def test_computer_use_rules_cover_windows_without_overstating_availability
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "Windows Computer Use"
      assert_includes document, "当前会话"
      assert_includes document, "前台桌面"
    end
    assert_includes policy, "保持解锁"
    assert_includes policy, "不能操作 UAC"
    assert_includes policy, "优先使用脚本"
    assert_includes policy, "2026-07-09"
  end

  def test_patch_runtime_route_verifiers_exist_on_both_platforms
    mac_verifier = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_verifier = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [mac_verifier, windows_verifier].each do |source|
      assert_includes source, "Google"
      assert_includes source, "OpenAI"
      assert_includes source, "Anthropic"
      assert_includes source, "Claude"
      assert_includes source, "/connections"
      assert_includes source, "/proxies"
      assert_includes source, "DIRECT"
    end
    assert_includes policy, "verify_routes.ps1"
    assert_includes mac_verifier, "NON_PROXY_TERMINALS"
    assert_includes mac_verifier, "non_proxy_terminal?"
    assert_includes windows_verifier, '$Chains -contains "DIRECT"'
    assert_includes windows_verifier, "function Test-RouteChains"
    assert_includes windows_verifier, 'type -eq "Selector"'
  end

  def test_diagnostics_separates_clues_from_conclusions
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[已确认 有力支持 尚未证实 已排除].each { |state| assert_includes policy, state }
    assert_includes policy, "单个现象或相关性只能算线索"
    assert_includes policy, "第二种独立证据"
    assert_includes policy, "反证"
    assert_includes policy, "解释全部已知现象"
  end

  def test_diagnostics_has_reproduction_scope_and_reset_gates
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes skill, "有 Computer Use"
    assert_includes skill, "修改前复现"
    assert_includes skill, "两次假设"
    assert_includes skill, "诊断重置"
    assert_includes policy, "配置缺陷不等于故障原因"
    assert_includes policy, "至少两个健康对照"
    assert_includes policy, "恢复全部未生效的试验"
    assert_includes policy, "没有新的证据不得进行第三次修改"
    assert_includes policy, "不能因为单个目标的对照结果就停用或删除整个组件"
    assert_includes policy, "共同组件本身"
  end

  def test_diagnostics_resolves_overlapping_network_interceptors_by_responsibility
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "重叠接管"
      assert_includes document, "职责分层"
    end

    assert_includes policy, "系统代理或 PAC"
    assert_includes policy, "透明代理或内容过滤器"
    assert_includes policy, "VPN 或 TUN"
    assert_includes policy, "原有功能覆盖"
    assert_includes policy, "安全属性"
    assert_includes policy, "不逐站添加例外"
  end

  def test_macos_adguard_uses_the_known_clash_compatibility_path
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "AdGuard for Mac"
      assert_includes document, "Network Extension"
      assert_includes document, "自动代理"
    end

    assert_includes skill, "档位 2、3"
    assert_includes skill, "不得逐站添加例外"
    assert_includes policy, "已知兼容路径"
    assert_includes policy, "不是升档"
    assert_includes policy, "只通过 AdGuard 界面"
    assert_includes policy, "不得用 `networksetup`"
    assert_includes policy, "Safari 和 Chrome"
    assert_includes policy, "非浏览器应用"
    assert_includes policy, "至少三个无关目标"
    assert_includes policy, "不能仅凭检测到 AdGuard"
    assert_includes policy, "无改善立即恢复"
    assert_includes design, "Patch 和 Diagnostics"
  end

  def test_configuration_history_is_versioned_compared_and_safely_restored
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    mac_patcher = mac_patcher_source
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_installer = windows_installer_source

    [readme, skill, policy, design].each do |document|
      assert_includes document, "每次写入"
      assert_includes document, "日期时间"
      assert_includes document, "配置差异"
      assert_includes document, "回滚"
    end

    assert_includes skill, "修改前的版本"
    assert_includes skill, "先备份当前版本"
    assert_includes policy, "不能仅凭时间接近"
    assert_includes policy, "预期 SHA-256"
    assert_includes policy, "不得自动删除历史备份"
    assert_includes policy, "不输出配置值"
    assert_includes policy, "失败时恢复回滚前版本"
    assert_includes mac_patcher, "--snapshot-initial"
    assert_includes mac_patcher, "--list-backups"
    assert_includes mac_patcher, "--compare-backup"
    assert_includes mac_patcher, "--restore-backup"
    assert_includes mac_installer, "--snapshot-initial"
    assert_includes windows_installer, "ListBackups"
    assert_includes windows_installer, "CompareBackup"
    assert_includes windows_installer, "RestoreBackup"
    assert_includes windows_installer, "clash-patch-backups"
    assert_includes windows_installer, "yyyy-MM-dd_HH-mm-ss"
    assert_includes windows_installer, "ChangedFields"
    assert_includes skill, "先列出备份"
    assert_includes skill, "先比较"
    assert_includes skill, "症状出现前"
    assert_includes skill, "--expected-current-sha256"
    assert_includes skill, "-ExpectedCurrentSha256"
  end

  def test_safe_update_replaces_all_subscriptions_as_one_transaction
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    patcher = mac_patcher_source

    [readme, skill, policy, design].each do |document|
      assert_includes document, "安全更新"
      assert_includes document, "全部远程订阅"
      assert_includes document, "全部保持原样"
      assert_includes document, "档位 3"
      assert_includes document, "关闭自动更新"
    end
    assert_includes installer, "--safe-update"
    assert_includes patcher, "--safe-update-all"
    assert_includes patcher, "--print-subscription-auto-update-state"
    assert_includes patcher, "--disable-subscription-auto-update"
    assert_includes installer, "--disable-subscription-auto-update"
    assert_includes windows_installer_source, "allow_auto_update"
    assert_includes windows_installer_source, "VerifySafeUpdate"
    [readme, skill, policy, design].each do |document|
      assert_includes document, "不依赖 Computer Use"
    end
    assert_includes policy, "不得安装永久监听"
    refute_includes skill, "订阅以后刷新时，请再次运行"
  end

  def test_macos_backup_recovery_includes_the_active_runtime
    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    ]

    documents.each do |document|
      assert_includes document, "macOS 恢复当前订阅后"
      assert_includes document, "运行内核"
      assert_includes document, "恢复回滚前版本"
    end
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
    assert_includes source, "不得安装永久监听、LaunchAgent、`WatchPaths`、计划任务或目录监听"
    assert_includes source, "REALITY `short-id`"
    assert_includes source, "只允许通过本地控制器自动刷新"
    assert_includes source, "失败时立即恢复原文件和原运行配置"
    assert_includes source, "`config.yaml` 是 ClashX Meta 的默认基础配置"
    assert_includes source, "不得删除"
  end

  def test_skill_automates_route_and_browser_verification_when_computer_use_exists
    source = File.read(File.join(SKILL, "SKILL.md"))

    assert_includes source, "访问 Google 时必须经过主代理组"
    assert_includes source, "不能经过 `DIRECT` 或 AI 分组"
    assert_includes source, "访问 OpenAI、Anthropic 或 Claude 时必须经过 AI 分组当前节点"
    assert_includes source, "macOS 或 Windows 环境只要提供 Computer Use，就由代理连续完成"
    assert_includes source, "当前环境没有 Computer Use 时，给出中文逐步操作"
  end


  def test_macos_route_verifier_checks_main_and_ai_destinations
    source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))

    %w[Google OpenAI Anthropic Claude].each { |name| assert_includes source, name }
    assert_includes source, "def route_passes?"
    assert_includes source, "return false if chains.include?(ai_group)"
    assert_includes source, 'existing.include?(entry["id"])'
  end

  def test_skill_reuses_user_ai_groups_and_creates_independent_node_selectors
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    ruby_patcher = mac_patcher_source
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

  def test_public_policy_routes_quic_with_the_shared_browser_udp_guard
    retired_rule = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"
    files = [
      File.join(ROOT, "README.md"),
      File.join(SKILL, "SKILL.md"),
      File.join(SKILL, "references/patch-policy.md"),
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md")
    ]

    files.each do |path|
      source = File.read(path)
      refute_includes source, retired_rule, path
      assert_includes source, "QUIC", path
      assert_includes source, "AI 分组", path
    end
  end

  def test_shared_browser_policy_scopes_dns_but_not_webrtc_by_domain
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))

    [skill, policy, design].each do |source|
      %w[AI\ 分组 STUN 标签页 TCP DNS].each { |term| assert_includes source, term }
    end
    assert_includes policy, "NETWORK,UDP,<AI 分组>"
    refute_includes policy, "NETWORK,UDP,<原主代理组>"
  end

  def test_diagnostics_separates_network_wait_from_browser_rendering
    files = [
      File.join(ROOT, "README.md"),
      File.join(SKILL, "SKILL.md"),
      File.join(SKILL, "references/patch-policy.md"),
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md")
    ]

    files.each do |path|
      source = File.read(path)
      %w[主文档 扩展 对照 单站].each { |term| assert_includes source, term, path }
    end
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
    patcher = mac_patcher_source
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
    windows_install_entry = File.binread(File.join(SKILL, "scripts/install_windows.ps1"))
    windows_install = windows_installer_source
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1"))
    patcher = mac_patcher_source

    assert_operator mac_install.index('id -u'), :<, mac_install.index("\n  save_profile\n")
    assert_operator mac_install.index('core_status='), :<, mac_install.index("\n  save_profile\n")
    assert_operator mac_install.index('core_status='), :<, mac_install.index('--disable-subscription-auto-update')
    assert_operator mac_install.index('plutil -extract Label'), :<, mac_install.index('launchctl bootout')
    assert_operator mac_install.index('ProgramArguments.0'), :<, mac_install.index('launchctl bootout')
    assert_operator mac_install.index('ProgramArguments.1'), :<, mac_install.index('launchctl bootout')
    assert_includes mac_install, "com.clashpatch.profiles"
    assert_includes mac_install, "com.wallny.clash-profile-patcher"
    assert_includes mac_uninstall, "com.clashpatch.profiles"
    assert_includes mac_uninstall, "com.wallny.clash-profile-patcher"
    refute_includes mac_install, "launchctl bootstrap"
    refute_includes mac_install, "WatchPaths"
    refute_includes mac_uninstall, 'defaults write "$DEFAULTS_DOMAIN" restoreTunProxy'
    assert_includes mac_uninstall, "旧版安装前的 TUN 偏好无法证明仍是当前选择"
    assert_operator mac_uninstall.index('ProgramArguments.0'), :<, mac_uninstall.index('launchctl bootout')
    assert_operator mac_uninstall.index('ProgramArguments.1'), :<, mac_uninstall.index('launchctl bootout')
    assert_includes patcher, "File::EXCL"

    assert_equal "\xEF\xBB\xBF".b, windows_install_entry.byteslice(0, 3)
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
    assert_includes windows_install, "clash-patch-auto-update-state.json"
    assert_includes windows_uninstall, "clash-patch-auto-update-state.json"
    assert_includes windows_uninstall, "Invoke-VerifiedWriteDeleteTransaction"
    assert_includes windows_tests, "auto-update restore did not reconstruct the original absent/null/tilde/empty-map shapes"
    assert_includes windows_tests, "running offline uninstall changed a protected target"
    assert_includes windows_tests, "delete transaction allowed a same-target write between verification and deletion"
  end

  def test_windows_safe_uninstall_ownership_and_partial_boundary_are_documented
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md"))
    baseline = File.read(File.join(ROOT, "tests/baseline.md"))

    [readme, policy, design].each do |source|
      assert_includes source, "所有权状态"
      assert_match(/客户端.*运行.*(?:不改任何文件|整批不改|整批卸载返回 `partial`)/, source)
      assert_match(/不得要求.*退出、停止或重启|不要求退出、停止或重启|不会要求退出或重启/, source)
    end
    assert_includes skill, "Windows 卸载返回 `partial`"
    assert_includes skill, "必须保留旧档位且不得继续降档"
    assert_includes baseline, "句柄绑定删除"
    assert_includes baseline, "文件身份"
    assert_includes baseline, "失败恢复不覆盖并发内容"
  end


  def test_skill_and_scripts_never_stop_or_restart_clash
    skill = File.read(File.join(SKILL, "SKILL.md"))
    readme = File.read(File.join(ROOT, "README.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_install = windows_installer_source
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
    mac = mac_patcher_source
    windows = windows_installer_source

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
    assert_includes workflow, "ruby tests/run_macos_production_probes.rb"
    assert_includes workflow, "ruby tests/coverage_ruby.rb"
    assert_includes workflow, "ruby tests/test_mutation_safety.rb"
    assert_includes workflow, "ruby tests/test_macos_wrappers.rb"
    assert_includes workflow, "runs-on: ${{ matrix.runner }}"
    assert_includes workflow, "runner: macos-15-intel"
    assert_includes workflow, "architecture: arm64"
    assert_includes workflow, "architecture: amd64"
    assert_includes workflow, "v1.19.27:$MIHOMO_MINIMUM_SHA256:MINIMUM"
    assert_includes workflow, "v1.19.29:$MIHOMO_CURRENT_SHA256:CURRENT"
    assert_includes workflow, "3617c9d8a5a55aecfe1ebd0f55ff59f2706c8ad68fd65c6c4e5f7cf2b74263f1"
    assert_includes workflow, "5392bea435a1c4b0a496571daafa977f744207cfafac18fb78a9b7d0747585c2"
    assert_includes workflow, "4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
    assert_includes workflow, "b57fec2e38462532fe75252792b355b99db16b0b8ea2d6bdf0cd8bc7ddacb9d2"
    mihomo_hashes = workflow.scan(/(?:minimum|current)_sha256:\s*"([^"]+)"/).flatten
    assert_equal 4, mihomo_hashes.length
    mihomo_hashes.each { |digest| assert_match(/\A[0-9a-f]{64}\z/, digest) }
    assert_includes workflow, "github.com/MetaCubeX/mihomo/releases/download/"
    assert_includes workflow, "shasum -a 256 --check"
    assert_includes workflow, "--connect-timeout 15 --max-time 300"
    assert_equal 2, workflow.scan(/CLASH_PATCH_REQUIRE_REAL_MIHOMO: "1"/).length
    assert_includes workflow, 'CLASH_PATCH_TEST_MIHOMO="$MIHOMO_MINIMUM_PATH" ruby'
    assert_includes workflow, 'CLASH_PATCH_TEST_MIHOMO="$MIHOMO_CURRENT_PATH" ruby'
    assert_equal 2, workflow.scan(/ruby tests\/test_macos_patcher\.rb --name test_generated_profile_passes_installed_mihomo_validation/).length
    macos_tests = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    assert_includes macos_tests, 'ENV["CLASH_PATCH_REQUIRE_REAL_MIHOMO"] == "1"'
    assert_includes macos_tests, 'ENV["CLASH_PATCH_TEST_MIHOMO"]'
    assert_includes workflow, "--test-coverage-lines=100"
    assert_includes workflow, "--test-coverage-functions=100"
    assert_includes workflow, "--test-coverage-branches=80"
    assert_includes workflow, "34b4c5bc0c176eebd298f6624aa23ea41985a2c54efb04eb0e9c4542e45190ee"
    assert_includes workflow, "1a8520cfe425441eba3eba8623b27b985020031243fe1ecaa1af2b92358a03f9"
    assert_includes workflow, "mihomo-windows-amd64-$env:MIHOMO_VERSION.zip"
    assert_includes workflow, "-RealMihomoOnly"
    assert_includes workflow, "executable: powershell.exe"
    assert_includes workflow, "executable: pwsh.exe"
    assert_equal 4, workflow.scan(/- version: v1\.19\.(?:27|29)\n\s+sha256: "[0-9a-f]{64}"\n\s+executable: (?:powershell|pwsh)\.exe\n\s+edition: (?:Desktop|Core)\n\s+major: [57]/).length
    assert_includes workflow, "--connect-timeout 15 --max-time 300"
    assert_includes workflow, "shell: powershell"
    assert_includes workflow, "Get-Command powershell.exe"
    assert_includes workflow, "-ExpectedPSEdition Desktop -ExpectedPSMajor 5"
    assert_match(/^  windows-installer-powershell-5:$/, workflow)
    assert_includes workflow, "shell: pwsh"
    assert_includes workflow, "Get-Command pwsh.exe"
    assert_includes workflow, "-ExpectedPSEdition Core -ExpectedPSMajor 7"
    assert_match(/^  windows-installer-powershell-7:$/, workflow)
    assert_includes workflow, "git diff --check"
    assert_includes workflow, "fetch-depth: 0"
    assert_includes workflow, "github.event.before"
    assert_includes workflow, "github.event.pull_request.base.sha"
    assert_equal 6, workflow.scan(/timeout-minutes:\s*20/).length
  end

  def test_github_actions_shell_fields_are_static
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    shell_values = workflow.scan(/^\s+shell:\s*(.+)$/).flatten

    refute_empty shell_values
    assert shell_values.all? { |value| %w[bash powershell pwsh].include?(value) },
           "GitHub rejects expression contexts in steps[*].shell before any job starts"
  end

  def test_windows_full_runtime_jobs_require_completion_receipts
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1")).force_encoding("UTF-8")

    {
      "windows-installer-powershell-5" => ["powershell.exe", "Desktop", "5"],
      "windows-installer-powershell-7" => ["pwsh.exe", "Core", "7"]
    }.each do |job_name, (executable, edition, major)|
      job = workflow[/^  #{Regexp.escape(job_name)}:\n(?:(?!^  \S).*\n)*/]
      refute_nil job, "missing Windows full-suite job: #{job_name}"
      assert_match(
        /^\s*\$runtime = \(Get-Command #{Regexp.escape(executable)}\)\.Source\n\s*& \$runtime -NoLogo -NoProfile -File \.\/tests\/test_windows_installer\.ps1 -PowerShellPath \$runtime -ExpectedPSEdition #{edition} -ExpectedPSMajor #{major} -CompletionReceiptPath \$receipt$/,
        job
      )
      assert_includes job, 'Remove-Item -LiteralPath $receipt -Force -ErrorAction SilentlyContinue'
      assert_includes job, 'Test-Path -LiteralPath $receipt -PathType Leaf'
      assert_includes job, 'Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json'
      assert_includes job, '$completed.Mode -ne "Full"'
      assert_includes job, "$completed.PSEdition -ne \"#{edition}\""
      assert_includes job, "[int]$completed.PSMajor -ne #{major}"
    end

    assert_includes windows_tests, "[string]$CompletionReceiptPath"
    assert_includes windows_tests, 'Mode = "Full"'
    assert_includes windows_tests, "PSEdition = $ExpectedPSEdition"
    assert_includes windows_tests, "PSMajor = $ExpectedPSMajor"
    assert_match(/WriteAllText\(\s*\$CompletionReceiptPath,/m, windows_tests)
  end

  def test_ruby_coverage_requires_the_entire_transform_module_at_one_hundred_percent
    source = File.read(File.join(ROOT, "tests/coverage_ruby.rb"))

    assert_includes source, "MINIMUM_PATCHER_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_MODULE_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_VERIFY_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_PRODUCTION_BRANCH_COVERAGE = 75.0"
    assert_includes source, 'TRANSFORM_PATH = File.join(MACOS_RUBY_ROOT, "patch_profiles", "transform.rb")'
    assert_includes source, "MINIMUM_TRANSFORM_LINE_COVERAGE = 100.0"
    assert_includes source, "uncovered_line_ranges"
    assert_includes source, "uncovered_branch_lines"
    assert_includes source, "path == TRANSFORM_PATH"
    refute_includes source, "TRANSFORM_CORE_METHODS"
    refute_includes source, "RubyVM::AbstractSyntaxTree"
  end

  def test_windows_runtime_tests_use_powershell_ast_for_automatic_variable_writes
    source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))

    assert_includes source, "Assert-NoReadOnlyAutomaticVariableWrites"
    assert_includes source, "AssignmentStatementAst"
    assert_includes source, "ParameterAst"
    assert_includes source, "ForEachStatementAst"
    assert_includes source, "UnaryExpressionAst"
    assert_includes source, "PostfixPlusPlus"
    assert_includes source, "CommandAst"
    assert_includes source, "Set-Variable"
    assert_includes source, "Invoke-DeferredProbe"
    assert_match(
      /^    if \(\$script:deferredProbeFailures\.Count -gt 0\) \{\n        throw \("deferred production probes failed:/,
      source
    )
    assert_includes source, "Compress-Archive"
    assert_includes source, "Expand-Archive"
    assert_includes source, "incomplete release changed AppHome"
  end

  def test_windows_candidate_cleanup_watcher_is_armed_before_publish
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/mihomo.ps1")
    ).force_encoding("UTF-8")
    function_source = source[
      /function Test-MihomoCandidate\b.*?(?=^function |\z)/m
    ]

    refute_nil function_source
    watcher = function_source.index("Start-MihomoCandidateCleanupWatcher $temporary")
    publish = function_source.index("[System.IO.File]::Move($staging, $temporary)")
    refute_nil watcher
    refute_nil publish
    assert_operator watcher, :<, publish,
                    "candidate must never become visible before caller-death cleanup is armed"
  end

  def test_windows_test_failure_diagnostics_do_not_echo_captured_output
    source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))
    diagnostic = source[/function Get-TestOutputDiagnostic\b.*?^}/m]
    json_assertion = source[/function Assert-JsonResult\b.*?^}/m]

    refute_nil diagnostic
    refute_nil json_assertion
    assert_includes diagnostic, '[System.Security.Cryptography.SHA256]::Create()'
    assert_includes diagnostic, 'return "output_length=$($text.Length) output_sha256=$digest"'
    refute_match(/return\s+\$text\b/, diagnostic)
    refute_match(/throw "[^"]*\$\(\$result\.Output\)/, source)
    refute_match(/Assert-True .*"[^"]*\$\(\$[A-Za-z0-9_]+\.Output\)/, source)
    assert_operator json_assertion.index("JSON result leaked"), :<,
                    json_assertion.index("$result.exit_code -eq $ExitCode"),
                    "privacy must be checked before a mismatched result is printed"
  end

  def test_production_probe_inventory_and_ci_aggregation_are_fixed
    patcher_source = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    wrapper_source = File.read(File.join(ROOT, "tests/test_macos_wrappers.rb"))
    runner_source = File.read(File.join(ROOT, "tests/run_macos_production_probes.rb"))
    windows_source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    expected_macos = %w[
      test_production_probe_mihomo_does_not_survive_a_killed_validator
      test_production_probe_next_run_recovers_batch_killed_after_first_commit
      test_production_probe_next_safe_update_recovers_batch_killed_after_first_swap
      test_production_probe_normal_batch_rejects_duplicate_file_aliases
      test_production_probe_normal_batch_restores_a_commit_when_bookkeeping_raises
      test_production_probe_safe_update_restores_a_swap_when_bookkeeping_raises
    ].sort
    expected_wrappers = %w[
      test_production_probe_uninstall_preserves_a_file_replaced_after_staging
    ]
    expected_windows = [
      "Mihomo candidate privacy and cleanup after caller death",
      "Mihomo timeout terminates descendants",
      "SUBST AppHome lock alias",
      "duplicate transaction action field",
      "extended-path AppHome lock alias",
      "installer and uninstaller shared AppHome lock",
      "interrupted new-file transaction preserves later content",
      "interrupted transaction same-byte identity replacement",
      "new-file transaction journal empty original bytes",
      "non-proxy route termini",
      "private transaction journal ACL",
      "public restore strong-kill atomicity",
      "public restore same-byte identity replacement",
      "release archive public install",
      "short-path backup identity alias",
      "strict transaction journal byte schema",
      "strict UTF-8 safe-update validation",
      "strict safe-update manifest schema"
    ].sort
    expected_transaction_journal_cases = %w[
      alternate-data-stream
      duplicate-action
      duplicate-actions
      duplicate-existed
      duplicate-original-base64
      duplicate-path
      duplicate-replacement-base64
      duplicate-version
      invalid-utf8
      reserved-device
      trailing-dot
      trailing-space
    ].sort
    expected_public_kill_markers = %w[
      CLASH_PATCH_TEST_PUBLIC_CRASH_READY
      CLASH_PATCH_TEST_RESTORE_CRASH_READY
      CLASH_PATCH_TEST_UNINSTALL_CRASH_READY
    ].sort

    assert_equal expected_macos,
                 patcher_source.scan(/^  def (test_production_probe_[a-z0-9_]+)/).flatten.sort
    assert_equal expected_wrappers,
                 wrapper_source.scan(/^  def (test_production_probe_[a-z0-9_]+)/).flatten.sort
    assert_equal expected_windows,
                 windows_source.scan(/Invoke-DeferredProbe "([^"]+)"/).flatten.sort
    journal_matrix = windows_source[
      /\$transactionJournalCases = @\(.*?\n            \)\n            \$unsafeTransactionJournals/m
    ]
    refute_nil journal_matrix
    assert_equal expected_transaction_journal_cases,
                 journal_matrix.scan(/Name = "([^"]+)"/).flatten.sort
    assert_equal expected_public_kill_markers,
                 windows_source.scan(/\$env:(CLASH_PATCH_TEST_[A-Z_]+CRASH_READY)/).flatten.uniq.sort
    armed_public_kill_markers = windows_source.scan(
      /\$env:(CLASH_PATCH_TEST_[A-Z_]+CRASH_READY)\s*=\s*\$([A-Za-z][A-Za-z0-9]*)/
    ).reject { |_, value| value == "null" }.map(&:first).uniq.sort
    assert_equal expected_public_kill_markers, armed_public_kill_markers
    assert_includes windows_source, '"real Mihomo core #{0} profile {1}: {2}"'
    assert_equal 1, workflow.scan("ruby tests/run_macos_production_probes.rb").length
    assert_includes runner_source, 'ENV.fetch("CLASH_PATCH_CURRENT_RUBY", RbConfig.ruby)'
    assert_includes runner_source, 'ENV.fetch("CLASH_PATCH_SYSTEM_RUBY", "/usr/bin/ruby")'
  end

  def test_windows_interrupted_new_file_recovery_requires_managed_bytes
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    recovery_plan = source[
      /function Get-InterruptedTransactionRecoveryPlan\b.*?(?=^function Invoke-InterruptedTransactionRecovery)/m
    ]

    refute_nil recovery_plan
    assert_match(
      /\} elseif \(\$action\.Action -eq "write"\) \{\n\s+if \(\$snapshot\.Exists -and\n\s+\$currentHash -ne \$replacementHash -and -not \$isInterruptedReplacement\) \{\n\s+throw "中断事务新建目标有无法自动合并的新改动/,
      recovery_plan
    )
  end

  def test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure
    runner = File.join(ROOT, "tests/run_macos_production_probes.rb")
    assert File.file?(runner), "macOS production probes need one behaviorally testable CI runner"

    Dir.mktmpdir("clash-patch-probe-runner-") do |directory|
      current_ruby = File.join(directory, "current-ruby")
      system_ruby = File.join(directory, "system-ruby")
      counter = File.join(directory, "counter")
      log = File.join(directory, "calls")
      fake_ruby_source = <<~RUBY
        #!#{RbConfig.ruby}
        statuses = ENV.fetch("CLASH_PATCH_FAKE_PROBE_STATUSES").split(",").map(&:to_i)
        counter_path = ENV.fetch("CLASH_PATCH_FAKE_PROBE_COUNTER")
        call_index = File.file?(counter_path) ? File.read(counter_path).to_i : 0
        File.write(counter_path, (call_index + 1).to_s)
        File.open(ENV.fetch("CLASH_PATCH_FAKE_PROBE_LOG"), "a") do |file|
          file.puts(([File.basename($PROGRAM_NAME), ENV["CLASH_PATCH_RUN_PRODUCTION_PROBES"]] + ARGV).join("|"))
        end
        exit statuses.fetch(call_index, 99)
      RUBY
      [current_ruby, system_ruby].each do |path|
        File.write(path, fake_ruby_source)
        FileUtils.chmod(0o700, path)
      end
      expected_calls = [
        "current-ruby|1|tests/test_macos_patcher.rb|--name|/production_probe/",
        "current-ruby|1|tests/test_macos_wrappers.rb|--name|/production_probe/",
        "system-ruby|1|tests/test_macos_patcher.rb|--name|/production_probe/",
        "system-ruby|1|tests/test_macos_wrappers.rb|--name|/production_probe/"
      ]

      4.times do |failed_index|
        statuses = Array.new(4, 0)
        statuses[failed_index] = 7
        FileUtils.rm_f([counter, log])
        _output, _error, status = Open3.capture3(
          {
            "CLASH_PATCH_CURRENT_RUBY" => current_ruby,
            "CLASH_PATCH_SYSTEM_RUBY" => system_ruby,
            "CLASH_PATCH_FAKE_PROBE_STATUSES" => statuses.join(","),
            "CLASH_PATCH_FAKE_PROBE_COUNTER" => counter,
            "CLASH_PATCH_FAKE_PROBE_LOG" => log
          },
          RbConfig.ruby, runner, chdir: ROOT
        )
        refute status.success?, "probe runner ignored failure at command #{failed_index + 1}"
        calls = File.readlines(log, chomp: true)
        assert_equal expected_calls, calls,
                     "probe runner did not execute every suite on both supported Rubies"
      end

      FileUtils.rm_f([counter, log])
      _output, _error, status = Open3.capture3(
        {
          "CLASH_PATCH_CURRENT_RUBY" => current_ruby,
          "CLASH_PATCH_SYSTEM_RUBY" => system_ruby,
          "CLASH_PATCH_FAKE_PROBE_STATUSES" => "0,0,0,0",
          "CLASH_PATCH_FAKE_PROBE_COUNTER" => counter,
          "CLASH_PATCH_FAKE_PROBE_LOG" => log
        },
        RbConfig.ruby, runner, chdir: ROOT
      )
      assert status.success?, "probe runner rejected four successful probe suites"
      assert_equal expected_calls, File.readlines(log, chomp: true)
    end
  end

  def test_every_test_entrypoint_is_wired_into_ci
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    entrypoints = Dir[File.join(ROOT, "tests/test_*.{rb,js,ps1}")].sort

    refute_empty entrypoints
    entrypoints.each do |path|
      assert_includes workflow, File.basename(path), "test entrypoint is not executed by CI: #{path}"
    end
  end

  def test_every_local_test_entrypoint_is_in_the_precommit_release_list
    instructions = File.read(File.join(ROOT, "AGENTS.md"))
    local_entrypoints = Dir[File.join(ROOT, "tests/test_*.{rb,js}")].sort

    refute_empty local_entrypoints
    local_entrypoints.each do |path|
      assert_includes instructions, File.basename(path), "local test entrypoint is missing from AGENTS.md: #{path}"
    end
  end

  def test_all_public_commands_expose_the_versioned_result_contract
    contract = JSON.parse(File.read(File.join(SKILL, "references/result-contract.json")))
    assert_equal "clash-patch.result", contract.fetch("schema")
    assert_equal 1, contract.fetch("version")
    assert_equal %w[
      schema version command platform client operation ok status code exit_code summary_zh
      profile changes checks items messages warnings
    ], contract.fetch("required_fields")
    assert_equal %w[install uninstall patch verify_routes], contract.fetch("commands")
    assert_equal ["integer", "null"], contract.fetch("field_types").fetch("profile")
    %w[changes checks items messages warnings].each do |field|
      assert_equal "array", contract.fetch("field_types").fetch(field)
    end

    mac_paths = %w[
      scripts/install_macos.sh scripts/uninstall_macos.sh
      scripts/macos/patch_profiles.rb scripts/macos/verify_routes.rb
    ]
    windows_paths = %w[
      scripts/install_windows.ps1 scripts/uninstall_windows.ps1 scripts/windows/verify_routes.ps1
    ]
    mac_paths.each do |path|
      source = path == "scripts/macos/patch_profiles.rb" ? mac_patcher_source : File.read(File.join(SKILL, path))
      assert_includes source, "--json", path
    end
    windows_paths.each { |path| assert_includes File.read(File.join(SKILL, path)), "Json", path }

    ruby_contract = File.read(File.join(SKILL, "scripts/macos/result_contract.rb"))
    powershell_contract = File.read(File.join(SKILL, "scripts/windows/result_contract.ps1"))
    assert_includes ruby_contract, 'SCHEMA = "clash-patch.result"'
    assert_includes ruby_contract, "VERSION = 1"
    assert_includes ruby_contract, "COMMANDS = %w[install uninstall patch verify_routes]"
    assert_includes powershell_contract, '$script:ClashPatchResultSchema = "clash-patch.result"'
    assert_includes powershell_contract, '$script:ClashPatchResultVersion = 1'
    assert_includes powershell_contract, '$script:ClashPatchResultCommands = @("install", "uninstall", "patch", "verify_routes")'
  end

  def test_production_coverage_cannot_be_inflated_with_ignore_markers
    production = Dir.glob(File.join(SKILL, "scripts/**/*.{rb,js,ps1,sh,cmd}"))
    markers = [":nocov:", "c8 ignore", "istanbul ignore", "coverage:ignore", "node:coverage"]
    offenders = production.each_with_object([]) do |path, found|
      text = File.read(path).downcase
      markers.each { |marker| found << "#{path}: #{marker}" if text.include?(marker) }
    end

    assert_empty offenders, "production coverage exclusions are forbidden: #{offenders.join(', ')}"
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
