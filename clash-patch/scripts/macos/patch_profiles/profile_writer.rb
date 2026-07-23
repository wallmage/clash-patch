module ClashPatch
  module_function

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
      source.flock(File::LOCK_EX)
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
      return result.merge(path: path, dry_run: true) if dry_run

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

        source.rewind
        if !locked_source_current?(source, path, write_path) || source.read != original_bytes
          outcome = :retry
        else
          create_versioned_backup(path, backup_root, content: original_bytes, reason: "prewrite") if backup_root
          source.rewind
          if !locked_source_current?(source, path, write_path) || source.read != original_bytes
            outcome = :retry
          else
            # Write through the locked descriptor. If the subscription client
            # atomically replaces the path after our identity check, this
            # descriptor still names the old inode and cannot overwrite the
            # newly refreshed file. The post-write identity check then retries.
            patched_bytes = File.binread(temporary.path)
            write_locked_bytes(source, patched_bytes, original_bytes)
            outcome = if locked_source_current?(source, path, write_path)
                        result.merge(
                          path: path,
                          rollback_bytes: original_bytes,
                          patched_digest: Digest::SHA256.hexdigest(patched_bytes)
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

    results = roots.flat_map do |root|
      paths = profile_paths(root)
      unless active_profile?(File.join(root, "config.yaml"), selected)
        paths = paths.reject { |path| File.basename(path).casecmp("config.yaml").zero? }
      end
      paths.map do |path|
        result = patch_path(
          path, policy, dry_run: dry_run, backup_root: backup_root,
          validator: validator, usage_profile: usage_profile
        )
        result[:active] = active_root && File.expand_path(File.dirname(path)) == File.expand_path(active_root) && active_profile?(path, selected)
        if auto_reload && !dry_run && result[:active] && result[:status] == :updated
          result = activate_updated_profile(
            result,
            socket: socket,
            requester: requester,
            connectivity_checker: connectivity_checker,
            require_tun: usage_profile >= 2
          )
        end
        result
      end
    end

    results
  end

end
