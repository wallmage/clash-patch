module ClashPatch
  module_function

  LOCK_TIMEOUT_SECONDS = 5
  RENAME_SWAP = 0x00000002

  module DarwinRename
    extend Fiddle::Importer
    dlload "/usr/lib/libSystem.B.dylib"
    extern "int renamex_np(const char *, const char *, unsigned int)"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def lock_exclusive_with_timeout(handle, timeout_seconds: LOCK_TIMEOUT_SECONDS)
    deadline = monotonic_now + timeout_seconds
    loop do
      return true if handle.flock(File::LOCK_EX | File::LOCK_NB)
      raise IOError, "等待配置文件锁超时" if monotonic_now >= deadline

      sleep 0.05
    end
  end

  def atomic_swap_paths(first, second)
    result = DarwinRename.renamex_np(first.to_s, second.to_s, RENAME_SWAP)
    raise SystemCallError.new("无法原子交换配置文件", Fiddle.last_error) unless result.zero?

    true
  end

  def same_file_identity?(stat, path)
    current = File.stat(path)
    stat.dev == current.dev && stat.ino == current.ino
  rescue SystemCallError
    false
  end

  def atomic_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    source.rewind
    return false unless locked_source_current?(source, path, write_path) && source.read.b == expected_bytes

    source_stat = source.stat
    Tempfile.create([".clash-patch-swap-", ".tmp"], File.dirname(write_path)) do |temporary|
      temporary.binmode
      temporary.write(replacement_bytes)
      temporary.flush
      temporary.fsync
      File.chmod(source_stat.mode & 0o7777, temporary.path)
      return false unless locked_source_current?(source, path, write_path)

      atomic_swap_paths(temporary.path, write_path)
      committed = same_file_identity?(source_stat, temporary.path) &&
                  File.binread(temporary.path) == expected_bytes &&
                  File.realpath(path) == write_path &&
                  File.binread(write_path) == replacement_bytes
      unless committed
        if File.exist?(temporary.path) && File.exist?(write_path) &&
           same_file_identity?(source_stat, temporary.path) &&
           File.binread(write_path) == replacement_bytes
          atomic_swap_paths(temporary.path, write_path)
        end
        return false
      end
      true
    end
  end

  def atomic_compare_and_swap_bytes(path, expected_bytes, replacement_bytes,
                                    expected_identity: nil, expected_path: nil)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    write_path = File.realpath(path)
    return false if expected_path && write_path != expected_path
    File.open(write_path, "rb") do |source|
      lock_exclusive_with_timeout(source)
      if expected_identity
        stat = source.stat
        return false unless [stat.dev, stat.ino] == expected_identity
      end
      atomic_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    end
  rescue SystemCallError, IOError
    false
  end

  def write_locked_bytes(source, replacement_bytes, original_bytes)
    source.rewind
    written = source.write(replacement_bytes)
    raise IOError, "配置写入不完整" unless written == replacement_bytes.bytesize

    source.truncate(replacement_bytes.bytesize)
    source.flush
    source.fsync
    true
  rescue SystemCallError, IOError => write_error
    begin
      source.rewind
      restored = source.write(original_bytes)
      raise IOError, "原配置恢复不完整" unless restored == original_bytes.bytesize

      source.truncate(original_bytes.bytesize)
      source.flush
      source.fsync
    rescue SystemCallError, IOError => restore_error
      raise IOError, "配置写入失败且原内容恢复失败：#{restore_error.class}"
    end
    raise write_error
  end

  def locked_source_current?(source, path, write_path)
    return false unless File.realpath(path) == write_path

    source_stat = source.stat
    path_stat = File.stat(write_path)
    source_stat.dev == path_stat.dev && source_stat.ino == path_stat.ino
  rescue SystemCallError, IOError
    false
  end

  def patch_path_once(path, policy, dry_run:, backup_root:, validator:, usage_profile: 3)
    write_path = File.realpath(path)
    outcome = nil
    File.open(write_path, dry_run ? "rb" : "r+b") do |source|
      lock_exclusive_with_timeout(source)
      original_bytes = source.read
      original_text = original_bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidConfigError, "配置不是有效的 UTF-8" unless original_text.valid_encoding?

      config = load_yaml(original_text, path)
      result = patch(config, policy, usage_profile: usage_profile)
      return result.merge(path: path) unless result[:changed]

      patched_text = dump_config(result[:config])
      candidate_config = load_yaml(patched_text, path)
      second_pass = patch(candidate_config, policy, usage_profile: usage_profile)
      if second_pass[:changed] || second_pass[:config] != candidate_config
        return base_result(config, :non_idempotent).merge(path: path)
      end
      Tempfile.create([File.basename(write_path), ".tmp"], File.dirname(write_path), encoding: "UTF-8") do |temporary|
        temporary.write(patched_text)
        temporary.flush
        temporary.fsync
        load_yaml(File.read(temporary.path, encoding: "UTF-8"), temporary.path)
        unless validator.nil?
          validation = validator.call(temporary.path)
          if validation == :timeout
            return base_result(config, :validation_timeout).merge(path: path)
          end
          unless validation == true
            return base_result(config, :validation_failed).merge(path: path)
          end
        end
        return result.merge(path: path, dry_run: true) if dry_run

        source.rewind
        if !locked_source_current?(source, path, write_path) || source.read != original_bytes
          outcome = :retry
        else
          create_versioned_backup(path, backup_root, content: original_bytes, reason: "prewrite") if backup_root
          source.rewind
          if !locked_source_current?(source, path, write_path) || source.read != original_bytes
            outcome = :retry
          else
            patched_bytes = File.binread(temporary.path)
            swapped = atomic_replace_locked(source, path, write_path, original_bytes, patched_bytes)
            outcome = if swapped
                        committed = File.stat(write_path)
                        result.merge(
                          path: path,
                          rollback_bytes: original_bytes,
                          patched_digest: Digest::SHA256.hexdigest(patched_bytes),
                          patched_identity: [committed.dev, committed.ino],
                          patched_path: write_path
                        )
                      else
                        :retry
                      end
          end
        end
      end
    end
    outcome
  end

  def patch_path(path, policy, dry_run: false, backup_root: nil, validator: nil, usage_profile: 3)
    MAX_PATCH_ATTEMPTS.times do
      outcome = patch_path_once(
        path, policy, dry_run: dry_run, backup_root: backup_root,
        validator: validator, usage_profile: usage_profile
      )
      return outcome unless outcome == :retry
    end
    base_result(nil, :concurrent_change).merge(path: path)
  rescue Psych::Exception, JSON::ParserError, InvalidConfigError, SystemStackError
    base_result(nil, :invalid).merge(path: path)
  rescue SystemCallError, IOError
    base_result(nil, :io_error).merge(path: path)
  rescue StandardError
    base_result(nil, :error).merge(path: path)
  end

  def run(directory: nil, directories: nil, policy_path:, dry_run: false, backup_root: nil,
          selected_name: nil, active_directory: nil, validator: nil, auto_reload: false,
          socket: nil, requester: nil, connectivity_checker: nil, usage_profile: 3)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    unless policy.is_a?(Hash) && policy["version"] == POLICY_VERSION
      raise InvalidConfigError, "不支持的策略版本"
    end
    selected = selected_name.nil? ? selected_profile_name : selected_name
    roots = directories || (directory ? [directory] : default_profile_directories)
    active_root = active_directory || active_profile_root(roots, selected, directory)

    work_items = roots.flat_map do |root|
      paths = profile_paths(root)
      unless active_profile?(File.join(root, "config.yaml"), selected)
        paths = paths.reject { |path| File.basename(path).casecmp("config.yaml").zero? }
      end
      paths.map do |path|
        {
          path: path,
          active: active_root &&
            File.expand_path(File.dirname(path)) == File.expand_path(active_root) &&
            active_profile?(path, selected)
        }
      end
    end

    preflight = work_items.map do |item|
      result = patch_path(
        item.fetch(:path), policy, dry_run: true, backup_root: nil,
        validator: validator, usage_profile: usage_profile
      )
      result[:active] = item.fetch(:active)
      result
    end
    return preflight if dry_run

    unless preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }
      return preflight.map do |result|
        result[:status] == :updated ? result.merge(status: :batch_aborted, dry_run: false) : result
      end
    end

    results = []
    work_items.sort_by { |item| item.fetch(:active) ? 1 : 0 }.each do |item|
      path = item.fetch(:path)
        result = patch_path(
          path, policy, dry_run: dry_run, backup_root: backup_root,
          validator: validator, usage_profile: usage_profile
        )
        result[:active] = item.fetch(:active)
        if auto_reload && !dry_run && result[:active] && result[:status] == :updated
          result = activate_updated_profile(
            result,
            socket: socket,
            requester: requester,
            connectivity_checker: connectivity_checker,
            require_tun: usage_profile >= 2
          )
        end
        results << result
        next if %i[updated unchanged].include?(result[:status])

        results.reverse_each do |prior|
          next unless prior[:status] == :updated

          prior[:status] = restore_profile_bytes(prior) ? :batch_rolled_back : :batch_rollback_failed
        end
        break
    end

    results
  end

end
