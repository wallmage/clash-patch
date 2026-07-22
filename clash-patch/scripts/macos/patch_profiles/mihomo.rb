module ClashPatch
  module_function

  def mihomo_version(text)
    match = text.to_s.match(/\bv?(\d+)\.(\d+)\.(\d+)\b/i)
    match && match.captures.map(&:to_i)
  end

  def mihomo_version_supported?(text)
    version = mihomo_version(text)
    version && (version <=> MIN_MIHOMO_VERSION) >= 0
  end

  def terminate_process_group(pid)
    Process.kill("TERM", -pid)
    sleep 0.05
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::EPERM
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  ensure
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def run_process_with_timeout(command, *arguments, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    output = Tempfile.new("clash-patch-command")
    pid = Process.spawn(command, *arguments, out: output, err: output, pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        output.flush
        output.rewind
        return [output.read, waited[1], false]
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        terminate_process_group(pid)
        output.flush
        output.rewind
        return [output.read, nil, true]
      end
      sleep 0.05
    end
  ensure
    output.close! if output
  end

  def mihomo_core_status(core_path = AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path
    return :missing unless core && File.file?(core) && File.executable?(core)

    output, status, timed_out = run_process_with_timeout(core, "-v", timeout_seconds: timeout_seconds)
    return :timeout if timed_out
    return :unreadable unless status.success?

    mihomo_version_supported?(output) ? :supported : :too_old
  rescue SystemCallError, IOError
    :unreadable
  end

  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path
    core_status = mihomo_core_status(core, timeout_seconds: timeout_seconds)
    return :timeout if core_status == :timeout
    return false unless core_status == :supported

    _output, status, timed_out = run_process_with_timeout(
      core, "-d", mihomo_validation_directory(path), "-t", "-f", path,
      timeout_seconds: timeout_seconds
    )
    return :timeout if timed_out

    status.success?
  end

  def mihomo_validation_directory(path)
    File.dirname(File.expand_path(path))
  end

  def mihomo_core_path
    candidates = [
      File.expand_path("~/Library/Application Support/com.metacubex.ClashX.meta/.private_core/com.metacubex.ClashX.ProxyConfigHelper.meta"),
      "/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta",
      File.expand_path("~/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta")
    ]
    candidates.find { |path| File.file?(path) && File.executable?(path) }
  end

end

