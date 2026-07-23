require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
INSTALLER = File.join(ROOT, "clash-patch/scripts/install_macos.sh")
UNINSTALLER = File.join(ROOT, "clash-patch/scripts/uninstall_macos.sh")
RESULT_CONTRACT = File.join(ROOT, "clash-patch/scripts/macos/result_contract.rb")

class MacosWrapperTest < Minitest::Test
  REQUIRED_RESULT_FIELDS = %w[
    schema version command platform client operation ok status code exit_code summary_zh
    profile changes checks items messages warnings
  ].freeze

  def run_script(path, *arguments, home:, extra_env: {})
    state = File.join(home, "usage-profile.plist")
    env = {
      "HOME" => home,
      "CLASH_PATCH_USAGE_STATE_PATH" => state,
      "CLASH_PATCH_USAGE_PROFILE" => nil,
      "CLASH_PATCH_PROFILE_DIR" => nil
    }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", path, *arguments)
    [stdout, stderr, status, state]
  end

  def with_supported_app(home)
    FileUtils.mkdir_p(File.join(home, "Applications", "ClashX Meta.app"))
    yield
  end

  def install_fake_mihomo(home)
    core = File.join(
      home, "Applications", "ClashX Meta.app", "Contents", "Resources",
      "com.metacubex.ClashX.ProxyConfigHelper.meta"
    )
    FileUtils.mkdir_p(File.dirname(core))
    File.write(core, <<~SH)
      #!/bin/sh
      /usr/bin/printf '%s\n' "$*" >> "$HOME/fake-mihomo-arguments.log"
      if [ "${1:-}" = "-v" ]; then
        /usr/bin/printf '%s\n' 'Mihomo Meta v1.19.27 test'
      fi
      exit 0
    SH
    File.chmod(0o700, core)
    core
  end

  def with_missing_mihomo_installer
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      FileUtils.cp(RESULT_CONTRACT, File.join(scripts, "macos", "result_contract.rb")) if File.file?(RESULT_CONTRACT)
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "puts 'missing' if ARGV.include?('--print-core-status')\n"
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
    end
  end

  def with_supported_mihomo_installer(patcher_source: nil)
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      FileUtils.cp(RESULT_CONTRACT, File.join(scripts, "macos", "result_contract.rb"))
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        patcher_source || "if ARGV.include?('--print-core-status'); puts 'supported'; end\nexit 0\n"
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
    end
  end

  def assert_json_result(stdout, status, command:)
    result = JSON.parse(stdout)
    assert_equal REQUIRED_RESULT_FIELDS.sort, result.keys.sort
    assert_equal "clash-patch.result", result.fetch("schema")
    assert_equal 1, result.fetch("version")
    assert_equal command, result.fetch("command")
    assert_equal "macos", result.fetch("platform")
    assert_equal "clashx-meta", result.fetch("client")
    assert_equal status.exitstatus, result.fetch("exit_code")
    assert_equal stdout.bytes, stdout.encode("UTF-8").bytes
    result
  end

  def test_installer_json_mode_returns_one_contract_object_for_help_and_errors
    Dir.mktmpdir do |home|
      stdout, stderr, status = run_script(INSTALLER, "--help", "--json", home: home)
      assert status.success?
      assert_empty stderr
      assert_json_result(stdout, status, command: "install")

      stdout, stderr, status = run_script(INSTALLER, "--unknown", "--json", home: home)
      assert_equal 64, status.exitstatus
      assert_empty stderr
      result = assert_json_result(stdout, status, command: "install")
      assert_equal "invalid_request", result.fetch("status")
    end
  end

  def test_installer_json_mode_reports_saved_profile_without_extra_output
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          _stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)
          assert status.success?

          stdout, stderr, status = run_script(installer, "--show-profile", "--json", home: home)
          assert status.success?
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal 1, result.fetch("profile")
        end
      end
    end
  end

  def test_uninstaller_json_mode_returns_one_contract_object
    Dir.mktmpdir do |home|
      stdout, stderr, status = run_script(UNINSTALLER, "--json", home: home)
      assert status.success?, stdout
      assert_empty stderr
      result = assert_json_result(stdout, status, command: "uninstall")
      refute_includes JSON.generate(result), home
    end
  end

  def test_uninstaller_rejects_unknown_arguments_without_removing_state
    Dir.mktmpdir do |home|
      state = File.join(home, "usage-profile.plist")
      File.write(state, "owned")

      stdout, _stderr, status = run_script(UNINSTALLER, "--typo", home: home)

      assert_equal 64, status.exitstatus
      assert_includes stdout, "用法："
      assert File.file?(state)
    end
  end

  def test_installer_help_and_argument_errors_have_stable_exit_codes
    Dir.mktmpdir do |home|
      stdout, _stderr, status = run_script(INSTALLER, "--help", home: home)
      assert status.success?
      assert_includes stdout, "用法："

      _stdout, _stderr, status = run_script(INSTALLER, "--unknown", home: home)
      assert_equal 64, status.exitstatus

      _stdout, _stderr, status = run_script(INSTALLER, "--profile", home: home)
      assert_equal 64, status.exitstatus

      stdout, _stderr, status = run_script(INSTALLER, "--profile", "4", home: home)
      assert_equal 64, status.exitstatus
      assert_includes stdout, "用途档位无效"

      _stdout, _stderr, status = run_script(
        INSTALLER, "--show-profile", "--safe-update", home: home
      )
      assert_equal 64, status.exitstatus

      _stdout, _stderr, status = run_script(
        INSTALLER, "--show-profile", "--profile", "1", home: home
      )
      assert_equal 64, status.exitstatus
    end
  end

  def test_installer_reports_unset_profile_without_modifying_state
    Dir.mktmpdir do |home|
      stdout, _stderr, status, state = run_script(INSTALLER, home: home)
      assert_equal 10, status.exitstatus
      assert_includes stdout, "还没有选择用途档位"
      refute File.exist?(state)

      stdout, _stderr, status = run_script(INSTALLER, "--show-profile", home: home)
      assert status.success?
      assert_equal "unset\n", stdout
    end
  end

  def test_profiles_one_and_two_are_saved_and_apply_the_common_subscription_baseline
    with_supported_mihomo_installer do |installer|
      [1, 2].each do |profile|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            stdout, _stderr, status, state = run_script(installer, "--profile", profile.to_s, home: home)
            assert status.success?, stdout
            assert File.file?(state)
            assert_includes stdout, "已保存用途档位 #{profile}"
            assert_includes stdout, "全部订阅都已使用同一套国内域名直连规则"

            stdout, _stderr, status = run_script(installer, "--show-profile", home: home)
            assert status.success?
            assert_equal "#{profile}\n", stdout

            stdout, _stderr, status = run_script(installer, home: home)
            assert status.success?, stdout
            refute_includes stdout, "已保存用途档位"
          end
        end
      end
    end
  end

  def test_installer_runs_the_real_ruby_patcher_and_mihomo_validation
    Dir.mktmpdir do |home|
      with_supported_app(home) do
        install_fake_mihomo(home)
        profiles = File.join(home, "profiles")
        FileUtils.mkdir_p(profiles)
        profile = File.join(profiles, "friend.yaml")
        original = <<~YAML
          mixed-port: 7890
          proxies:
            - name: node
              type: ss
              server: proxy.invalid
              cipher: aes-128-gcm
              password: fixture-secret
          proxy-groups:
            - name: Proxy
              type: select
              proxies:
                - node
          dns:
            enable: true
            nameserver:
              - 223.5.5.5
          rules:
            - MATCH,Proxy
        YAML
        File.write(profile, original)

        stdout, stderr, status, state = run_script(
          INSTALLER, "--profile", "1", home: home,
          extra_env: { "CLASH_PATCH_PROFILE_DIR" => profiles }
        )

        assert status.success?, "#{stdout}\n#{stderr}"
        assert_empty stderr
        assert File.file?(state)
        output = File.read(profile)
        refute_equal original, output
        assert_includes output, "clash-patch-cn-domain"
        assert_includes output, "RULE-SET,clash-patch-cn-domain,DIRECT"
        assert Dir.glob(File.join(home, "Library/Application Support/ClashPatch/backups/*.backup")).any?
        core_arguments = File.read(File.join(home, "fake-mihomo-arguments.log"))
        assert_match(/^-v$/m, core_arguments)
        assert_includes core_arguments, " -t -f "
      end
    end
  end

  def test_environment_profile_is_supported_but_invalid_environment_is_rejected
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(
            installer, home: home, extra_env: { "CLASH_PATCH_USAGE_PROFILE" => "1" }
          )
          assert status.success?, stdout
          assert_includes stdout, "已保存用途档位 1"
        end
      end
    end

    Dir.mktmpdir do |home|
      stdout, _stderr, status = run_script(
        INSTALLER, home: home, extra_env: { "CLASH_PATCH_USAGE_PROFILE" => "bad" }
      )
      assert_equal 64, status.exitstatus
      assert_includes stdout, "用途档位无效"
    end
  end

  def test_profile_three_fails_closed_before_saving_when_mihomo_is_missing
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status, state = run_script(installer, "--profile", "3", home: home)
          assert_equal 8, status.exitstatus
          assert_includes stdout, "没有找到可用的 Mihomo"
          refute File.exist?(state)
        end
      end
    end
  end

  def test_failed_profile_change_preserves_the_previous_saved_profile
    failing_patcher = <<~RUBY
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 1 if ARGV.include?("--snapshot-initial")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: failing_patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
          original = File.binread(state)

          stdout, _stderr, status = run_script(installer, "--profile", "2", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "无法创建初始快照"
          assert_equal original, File.binread(state)

          stdout, stderr, status = run_script(installer, "--profile", "2", "--json", home: home)
          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "snapshot_failed", result.fetch("code")
          assert_equal original, File.binread(state)
        end
      end
    end
  end

  def test_profile_three_restores_auto_update_when_a_later_step_fails
    patcher = <<~RUBY
      File.open(File.join(ENV.fetch("HOME"), "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--enable-subscription-auto-update")
        puts "enabled"
        exit 0
      end
      exit 1 if ARGV.include?("--snapshot-initial")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "无法创建初始快照"
          calls = File.read(File.join(home, "patcher-calls.log")).lines.map(&:strip)
          disable_index = calls.index { |call| call.include?("--disable-subscription-auto-update") }
          enable_index = calls.index { |call| call.include?("--enable-subscription-auto-update") }
          refute_nil disable_index
          refute_nil enable_index
          assert_operator enable_index, :>, disable_index
        end
      end
    end
  end

  def test_unsafe_profile_state_is_rejected_before_profile_three_changes_settings
    patcher = <<~RUBY
      File.open(File.join(ENV.fetch("HOME"), "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      puts "supported" if ARGV.include?("--print-core-status")
      puts "disabled" if ARGV.include?("--disable-subscription-auto-update")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          File.symlink(File.join(home, "outside-state"), state)
          File.write(File.join(home, "patcher-calls.log"), "")

          stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 7, status.exitstatus
          assert_includes stdout, "档位保存位置不安全"
          calls = File.read(File.join(home, "patcher-calls.log"))
          refute_includes calls, "--disable-subscription-auto-update"
          refute_includes calls, "--snapshot-initial"
        end
      end
    end
  end

  def test_auto_update_restore_failure_is_reported_as_partial
    patcher = <<~RUBY
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "disabled"
        exit 0
      end
      exit 1 if ARGV.include?("--enable-subscription-auto-update")
      exit 1 if ARGV.include?("--snapshot-initial")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(installer, "--profile", "3", "--json", home: home)

          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "partial", result.fetch("status")
          assert_equal "auto_update_restore_failed", result.fetch("code")
        end
      end
    end
  end

  def test_json_wrapper_preserves_a_partial_safe_update_result
    patcher = <<~RUBY
      require "json"
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--safe-update-all")
        puts JSON.generate(
          "status" => "partial",
          "code" => "safe_update_runtime_pending",
          "summary_zh" => "订阅文件已恢复，但运行内核恢复失败。"
        )
        exit 1
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(
            installer, "--safe-update", "--profile", "1", "--json", home: home
          )

          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "partial", result.fetch("status")
          assert_equal "safe_update_runtime_pending", result.fetch("code")
        end
      end
    end
  end

  def test_profile_three_downgrade_requires_safe_uninstall
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
          original = File.binread(state)

          stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "先运行安全卸载"
          assert_equal original, File.binread(state)
        end
      end
    end
  end

  def test_safe_update_requires_the_same_mihomo_preflight
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(installer, "--safe-update", "--profile", "1", home: home)
          assert_equal 8, status.exitstatus
          assert_includes stdout, "没有找到可用的 Mihomo"
        end
      end
    end
  end

  def test_installer_rejects_non_macos_and_missing_custom_directory
    Dir.mktmpdir do |home|
      fake_bin = File.join(home, "bin")
      FileUtils.mkdir_p(fake_bin)
      uname = File.join(fake_bin, "uname")
      File.write(uname, "#!/bin/sh\nprintf 'Linux\\n'\n")
      File.chmod(0o700, uname)
      stdout, _stderr, status = run_script(
        INSTALLER, "--profile", "1", home: home,
        extra_env: { "PATH" => "#{fake_bin}:/usr/bin:/bin" }
      )
      assert_equal 2, status.exitstatus
      assert_includes stdout, "当前系统不是 macOS"
    end

    Dir.mktmpdir do |home|
      with_supported_app(home) do
        missing = File.join(home, "missing-profiles")
        stdout, _stderr, status = run_script(
          INSTALLER, "--profile", "1", home: home,
          extra_env: { "CLASH_PATCH_PROFILE_DIR" => missing }
        )
        assert_equal 5, status.exitstatus
        assert_includes stdout, "没有找到指定的 ClashX Meta 配置目录"
      end
    end
  end

  def test_uninstaller_removes_owned_files_preserves_backups_and_keeps_unowned_agent
    Dir.mktmpdir do |home|
      install_dir = File.join(home, "Library", "Application Support", "ClashPatch")
      backup_dir = File.join(install_dir, "backups")
      agent_dir = File.join(home, "Library", "LaunchAgents")
      FileUtils.mkdir_p(backup_dir)
      FileUtils.mkdir_p(agent_dir)
      File.write(File.join(install_dir, "patch_profiles.rb"), "owned")
      File.write(File.join(install_dir, "policy.json"), "owned")
      state = File.join(home, "usage-profile.plist")
      File.write(state, "owned")
      File.write(File.join(backup_dir, "keep.backup"), "keep")
      unowned_agent = File.join(agent_dir, "com.clashpatch.profiles.plist")
      File.write(unowned_agent, "not a plist owned by clash patch")

      stdout, _stderr, status = run_script(UNINSTALLER, home: home)

      assert status.success?, stdout
      refute File.exist?(File.join(install_dir, "patch_profiles.rb"))
      refute File.exist?(File.join(install_dir, "policy.json"))
      refute File.exist?(state)
      assert File.file?(File.join(backup_dir, "keep.backup"))
      assert File.file?(unowned_agent)
      assert_includes stdout, "备份仍保留"
      assert_includes stdout, "无法确认"
    end
  end

  def test_uninstaller_rejects_non_macos
    Dir.mktmpdir do |home|
      fake_bin = File.join(home, "bin")
      FileUtils.mkdir_p(fake_bin)
      uname = File.join(fake_bin, "uname")
      File.write(uname, "#!/bin/sh\nprintf 'Linux\\n'\n")
      File.chmod(0o700, uname)
      stdout, _stderr, status = run_script(
        UNINSTALLER, home: home, extra_env: { "PATH" => "#{fake_bin}:/usr/bin:/bin" }
      )
      assert_equal 2, status.exitstatus
      assert_includes stdout, "当前系统不是 macOS"
    end
  end
end
