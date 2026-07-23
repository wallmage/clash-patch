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
    binary_before = before.b
    binary_after = after.b
    assert_equal 1, source.scan(binary_before).length, "mutation anchor changed: #{relative_path}"
    File.binwrite(path, source.sub(binary_before, binary_after))
  end

  def assert_mutation_is_killed(root, *command)
    stdout = +""
    stderr = +""
    status = nil
    timed_out = false
    Open3.popen3(*command, chdir: root, pgroup: true) do |stdin, child_stdout, child_stderr, thread|
      stdin.close
      stdout_reader = Thread.new { child_stdout.read }
      stderr_reader = Thread.new { child_stderr.read }
      begin
        Timeout.timeout(30) { status = thread.value }
      rescue Timeout::Error
        timed_out = true
        begin
          Process.kill("KILL", -thread.pid)
        rescue Errno::ESRCH, Errno::EPERM
          Process.kill("KILL", thread.pid) rescue nil
        end
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

  def test_windows_live_match_main_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/verify_routes.ps1",
        '$main = Get-LiveMainGroup $proxies',
        '$main = Find-Group $proxies @($policy.main_group_names) $MainGroup "主代理组"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_route_verifier_uses_live_match_rule_for_main_group"
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

  def test_safe_update_precommit_journal_cleanup_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/subscriptions.rb",
        "        remove_profile_transaction(transaction)\n" \
          "        return { status: :aborted, failed_profile: \"\", reason: :concurrent_change }\n",
        "        true\n" \
          "        return { status: :aborted, failed_profile: \"\", reason: :concurrent_change }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_discards_an_uncommitted_journal_after_a_preflight_refresh"
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
        "clash-patch/scripts/macos/patch_profiles/profile_writer.rb",
        "        item.fetch(\"Path\"), current, original, expected_path: item.fetch(\"WritePath\")\n",
        "        item.fetch(\"Path\"), current, current, expected_path: item.fetch(\"WritePath\")\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLASH_PATCH_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_next_safe_update_recovers_batch_killed_after_first_swap"
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

  def test_atomic_swap_verification_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/profile_writer.rb",
        "        if File.exist?(temporary.path) && File.exist?(write_path) &&\n" \
          "           same_file_identity?(source_stat, temporary.path) &&\n" \
          "           File.binread(write_path) == replacement_bytes\n" \
          "          atomic_swap_paths(temporary.path, write_path)\n" \
          "        end\n",
        "        if File.exist?(temporary.path) && File.exist?(write_path) &&\n" \
          "           same_file_identity?(source_stat, temporary.path) &&\n" \
          "           File.binread(write_path) == replacement_bytes\n" \
          "          false\n" \
          "        end\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_atomic_replace_restores_the_original_when_commit_verification_fails"
      )
    end
  end

  def test_safe_update_post_swap_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/mihomo.rb",
        "    unless completed\n",
        "    if completed\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLASH_PATCH_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_mihomo_does_not_survive_a_killed_validator"
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

  def test_route_source_port_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/verify_routes.rb",
        "          metadata[\"network\"].to_s.casecmp(\"tcp\").zero? &&\n" \
          "          metadata[\"sourcePort\"].to_i == source_port\n",
        "          metadata[\"network\"].to_s.casecmp(\"tcp\").zero?\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_verifier_ignores_same_host_traffic_from_another_source_port"
      )
    end
  end

  def test_windows_idempotence_fail_safe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/clash_verge_global.js",
        "  if (JSON.stringify(candidate) !== JSON.stringify(secondPass)) return config;\n",
        "  if (JSON.stringify(candidate) !== JSON.stringify(secondPass)) return candidate;\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=global transform verifies a second pass before returning a candidate",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_release_archive_dependency_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles.rb",
        "patch_profiles/profile_writer patch_profiles/subscriptions patch_profiles/runtime",
        "patch_profiles/profile_writer patch_profiles/missing_subscriptions patch_profiles/runtime"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path"
      )
    end
  end

  def test_release_public_install_dry_run_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/install_macos.sh",
        "      --profile-dir \"$CUSTOM_PROFILE_DIR\" \\\n" \
          "      --policy \"$POLICY_SOURCE\" \\\n" \
          "      --backup-dir \"$BACKUP_DIR\" --usage-profile \"$USAGE_PROFILE\" --json 2>/dev/null",
        "      --profile-dir \"$CUSTOM_PROFILE_DIR\" \\\n" \
          "      --policy \"$POLICY_SOURCE\" \\\n" \
          "      --backup-dir \"$BACKUP_DIR\" --usage-profile \"$USAGE_PROFILE\" --dry-run --json 2>/dev/null"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path"
      )
    end
  end

  def test_normal_batch_preflight_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/profile_writer.rb",
        "    unless preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }\n",
        "    if false && !preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_normal_batch_aborts_before_writing_when_a_later_profile_fails"
      )
    end
  end

  def test_auto_update_compensation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/install_macos.sh",
        'disabled) AUTO_UPDATE_CHANGED=1; say "已自动关闭订阅更新，并保存修改前状态。" ;;',
        'disabled) say "已自动关闭订阅更新，并保存修改前状态。" ;;'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_profile_three_restores_auto_update_when_a_later_step_fails"
      )
    end
  end

  def test_auto_update_ownership_state_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/subscriptions.rb",
        "      ownership = write_auto_update_ownership_state(\n" \
          "        backup_root, domain, original, \"installed\", existing: auto_update_ownership_state(backup_root)\n" \
          "      )\n",
        "      ownership = { \"Path\" => auto_update_ownership_path(backup_root) }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_disables_subscription_auto_update_through_defaults_and_verifies_it"
      )
    end
  end

  def test_result_contract_profile_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/result_contract.rb",
        'value.match?(/\A[1-3]\z/) ? value.to_i : nil',
        'value.match?(/\A[1-4]\z/) ? value.to_i : nil'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_result_contract_cli_emits_valid_json_and_rejects_bad_arguments"
      )
    end
  end

  def test_default_mihomo_resolution_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/mihomo.rb",
        "  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)\n" \
          "    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path\n",
        "  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)\n" \
          "    core = core_path\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_mihomo_default_core_is_resolved_before_status_and_validation"
      )
    end
  end

  def test_runtime_google_dns_health_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/runtime.rb",
        '    return false unless dns_runtime_healthy?(requester, "www.google.com")',
        '    true'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_runtime_health_rejects_every_partial_health_failure"
      )
    end
  end

  def test_remote_subscription_https_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/macos/patch_profiles/subscriptions.rb",
        '      raise InvalidConfigError, "远程订阅地址不是 HTTPS" unless url.start_with?("https://")',
        '      true'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_remote_subscription_manifest_rejects_unsafe_and_ambiguous_records"
      )
    end
  end

  def test_windows_deferred_probe_failure_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '    if ($script:deferredProbeFailures.Count -gt 0) {' + "\n" +
          '        throw ("deferred production probes failed:',
        '    if ($script:deferredProbeFailures.Count -gt 0) {' + "\n" +
          '        Write-Host ("deferred production probes failed:'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_runtime_tests_use_powershell_ast_for_automatic_variable_writes"
      )
    end
  end

  def test_windows_failure_diagnostic_privacy_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '    return "output_length=$($text.Length) output_sha256=$digest"',
        '    return $text'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_test_failure_diagnostics_do_not_echo_captured_output"
      )
    end
  end

  def test_windows_candidate_cleanup_publish_order_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/install_windows/mihomo.ps1",
        "        Start-MihomoCandidateCleanupWatcher $temporary\n" +
          "        [System.IO.File]::Move($staging, $temporary)",
        "        [System.IO.File]::Move($staging, $temporary)\n" +
          "        Start-MihomoCandidateCleanupWatcher $temporary"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_candidate_cleanup_watcher_is_armed_before_publish"
      )
    end
  end

  def test_macos_production_probe_ci_gate_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/run_macos_production_probes.rb",
        'probe_environment = { "CLASH_PATCH_RUN_PRODUCTION_PROBES" => "1" }.freeze',
        'probe_environment = { "CLASH_PATCH_RUN_PRODUCTION_PROBES" => "0" }.freeze'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure"
      )
    end
  end

  def test_macos_real_mihomo_test_rename_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_macos_patcher.rb",
        "  def test_generated_profile_passes_installed_mihomo_validation\n",
        "  def test_generated_profile_passes_real_mihomo_validation\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_real_mihomo_runner_rejects_zero_or_skipped_cases"
      )
    end
  end

  def test_macos_production_probe_failure_aggregation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/run_macos_production_probes.rb",
        "  failed ||= !success\n",
        "  failed ||= false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure"
      )
    end
  end

  def test_github_actions_dynamic_shell_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "      - name: Download and verify official Windows Mihomo\n        shell: powershell",
        "      - name: Download and verify official Windows Mihomo\n        shell: ${{ matrix.shell }}"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_github_actions_shell_fields_are_static"
      )
    end
  end

  def test_windows_powershell_5_full_suite_entrypoint_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "          $runtime = (Get-Command powershell.exe).Source\n" +
          "          & $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1",
        "          $runtime = (Get-Command powershell.exe).Source\n" +
          "          Write-Host $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_full_runtime_jobs_require_completion_receipts"
      )
    end
  end

  def test_windows_powershell_7_full_suite_entrypoint_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "          $runtime = (Get-Command pwsh.exe).Source\n" +
          "          & $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1",
        "          $runtime = (Get-Command pwsh.exe).Source\n" +
          "          Write-Host $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_full_runtime_jobs_require_completion_receipts"
      )
    end
  end

  def test_macos_uninstall_auto_update_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/uninstall_macos.sh",
        "\ndelete_staged_install_files\n\nAUTO_UPDATE_RESTORED=0",
        "\nAUTO_UPDATE_RESTORED=0"
      )
      replace_once(
        root,
        "clash-patch/scripts/uninstall_macos.sh",
        "\ncommit_staged_install_files\n/bin/rmdir",
        "\ndelete_staged_install_files\ncommit_staged_install_files\n/bin/rmdir"
      )

      assert_mutation_is_killed(
        root,
        "/usr/bin/env", "CLASH_PATCH_RUN_PRODUCTION_PROBES=1",
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_production_probe_uninstall_preserves_a_file_replaced_after_staging"
      )
    end
  end

  def test_macos_production_probe_inventory_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_macos_patcher.rb",
        "def test_production_probe_mihomo_does_not_survive_a_killed_validator",
        "def test_mihomo_does_not_survive_a_killed_validator"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_transaction_journal_matrix_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '                    Name = "alternate-data-stream"',
        '                    Name = "alternate-stream-removed"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_interrupted_new_file_probe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '        Invoke-DeferredProbe "interrupted new-file transaction preserves later content" {',
        '        Invoke-DeferredProbe "interrupted new-file transaction probe removed" {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_interrupted_new_file_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/install_windows/transaction.ps1",
        '            if ($snapshot.Exists -and' + "\n" +
          '                $currentHash -ne $replacementHash -and -not $isInterruptedReplacement) {' + "\n" +
          '                throw "中断事务新建目标有无法自动合并的新改动：$($action.Path)"' + "\n" +
          "            }\n",
        '            if ($false) {' + "\n" +
          '                throw "中断事务新建目标有无法自动合并的新改动：$($action.Path)"' + "\n" +
          "            }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_interrupted_new_file_recovery_requires_managed_bytes"
      )
    end
  end

  def test_windows_recovery_prefix_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/install_windows/transaction.ps1",
        '            -not ($action.Action -eq "delete" -and $isInterruptedOriginal)) {',
        '            $true) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_interrupted_recovery_accepts_only_original_byte_prefixes"
      )
    end
  end

  def test_windows_suffix_main_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/install_windows/script_js.ps1",
        "                Assert-JavaScriptDoesNotBindMain $suffix\n",
        "                Assert-JavaScriptReservedIdentifiers $suffix\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_managed_script_suffix_cannot_rebind_main"
      )
    end
  end

  def test_windows_ambiguous_app_home_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "clash-patch/scripts/windows/install_windows/transaction.ps1",
        '    if ($existing.Count -gt 1) {',
        '    if ($false) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_default_app_home_rejects_multiple_existing_candidates"
      )
    end
  end

  def test_windows_public_uninstall_kill_probe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '        $env:CLASH_PATCH_TEST_UNINSTALL_CRASH_READY = $publicUninstallCrashReady',
        '        $env:CLASH_PATCH_TEST_UNINSTALL_PROBE_REMOVED = $publicUninstallCrashReady'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end
end
