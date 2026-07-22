require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
INSTALLER = File.join(ROOT, "clash-patch/scripts/install_macos.sh")
UNINSTALLER = File.join(ROOT, "clash-patch/scripts/uninstall_macos.sh")

class MacosWrapperTest < Minitest::Test
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

  def with_missing_mihomo_installer
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "puts 'missing' if ARGV.include?('--print-core-status')\n"
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
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

  def test_profiles_one_and_two_are_saved_and_reused_without_patching_subscriptions
    [1, 2].each do |profile|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status, state = run_script(INSTALLER, "--profile", profile.to_s, home: home)
          assert status.success?, stdout
          assert File.file?(state)
          assert_includes stdout, "已保存用途档位 #{profile}"
          assert_includes stdout, "未修改"

          stdout, _stderr, status = run_script(INSTALLER, "--show-profile", home: home)
          assert status.success?
          assert_equal "#{profile}\n", stdout

          stdout, _stderr, status = run_script(INSTALLER, home: home)
          assert status.success?, stdout
          refute_includes stdout, "已保存用途档位"
        end
      end
    end
  end

  def test_environment_profile_is_supported_but_invalid_environment_is_rejected
    Dir.mktmpdir do |home|
      with_supported_app(home) do
        stdout, _stderr, status = run_script(
          INSTALLER, home: home, extra_env: { "CLASH_PATCH_USAGE_PROFILE" => "1" }
        )
        assert status.success?, stdout
        assert_includes stdout, "已保存用途档位 1"
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

  def test_safe_update_requires_the_same_mihomo_preflight
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          _stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)
          assert status.success?

          stdout, _stderr, status = run_script(installer, "--safe-update", home: home)
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
      File.write(File.join(backup_dir, "keep.backup"), "keep")
      unowned_agent = File.join(agent_dir, "com.clashpatch.profiles.plist")
      File.write(unowned_agent, "not a plist owned by clash patch")

      stdout, _stderr, status = run_script(UNINSTALLER, home: home)

      assert status.success?, stdout
      refute File.exist?(File.join(install_dir, "patch_profiles.rb"))
      refute File.exist?(File.join(install_dir, "policy.json"))
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
