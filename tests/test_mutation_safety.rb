require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)

class MutationSafetyTest < Minitest::Test
  def with_repo_copy
    Dir.mktmpdir("clash-patch-mutation-") do |directory|
      %w[.github clash-patch tests README.md].each do |entry|
        FileUtils.cp_r(File.join(ROOT, entry), File.join(directory, entry))
      end
      yield directory
    end
  end

  def replace_once(root, relative_path, before, after)
    path = File.join(root, relative_path)
    source = File.binread(path)
    assert_equal 1, source.scan(before).length, "mutation anchor changed: #{relative_path}"
    File.binwrite(path, source.sub(before, after))
  end

  def assert_mutation_is_killed(root, *command)
    stdout = +""
    stderr = +""
    status = nil
    timed_out = false
    Open3.popen3(*command, chdir: root) do |stdin, child_stdout, child_stderr, thread|
      stdin.close
      stdout_reader = Thread.new { child_stdout.read }
      stderr_reader = Thread.new { child_stderr.read }
      begin
        Timeout.timeout(30) { status = thread.value }
      rescue Timeout::Error
        timed_out = true
        Process.kill("KILL", thread.pid) rescue nil
        thread.join
      ensure
        stdout = stdout_reader.value
        stderr = stderr_reader.value
      end
    end
    refute timed_out, "mutation test timed out instead of detecting the behavior: #{command.join(' ')}"
    refute_match(/(?:SyntaxError|syntax error|LoadError|cannot load such file)/i, stdout + stderr)
    refute status.success?, <<~MESSAGE
      mutation survived: #{command.join(" ")}
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
    assert_match(
      /(?:Failure:|failed|fail|not ok)/i,
      stdout + stderr,
      "mutation exited nonzero without an assertion failure: #{command.join(' ')}"
    )
  end

  def test_read_only_automatic_variable_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/verify_routes.ps1",
        '$connectionHost = [string]$connection.metadata.host',
        '$host = [string]$connection.metadata.host'
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=PowerShell scripts never assign to read-only automatic variables",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_safe_update_path_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/subscriptions.rb",
        "def locked_profile_current?(handle, path)\n",
        "def locked_profile_current?(handle, path)\n    return true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_preserves_an_atomic_refresh_during_backup"
      )
    end
  end

  def test_early_profile_save_mutation_is_killed
    with_repo_copy do |root|
      early_save = <<~SH
        if [ "$PROFILE_SOURCE" != "saved" ]; then
          save_profile
        fi

      SH
      replace_once(
        root,
        "clash-patch/scripts/install_macos.sh",
        "if [ \"$USAGE_PROFILE\" -eq 3 ]; then\n",
        early_save + "if [ \"$USAGE_PROFILE\" -eq 3 ]; then\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_failed_profile_change_preserves_the_previous_saved_profile"
      )
    end
  end

  def test_safe_update_rollback_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/subscriptions.rb",
        "handle.write(item.fetch(:original))",
        "handle.write(item.fetch(:candidate))"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_restores_every_profile_when_a_later_write_fails"
      )
    end
  end

  def test_partial_write_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/profile_writer.rb",
        "    begin\n      source.rewind\n      restored = source.write(original_bytes)",
        "    begin\n      raise write_error\n      source.rewind\n      restored = source.write(original_bytes)"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_locked_write_restores_original_bytes_after_a_partial_write_error"
      )
    end
  end

  def test_route_domain_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/verify_routes.rb",
        '/(?:\A|\.)google\.com\z/i',
        "/google/i"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_target_patterns_require_real_domain_boundaries"
      )
    end
  end
end
