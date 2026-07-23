module ClashPatch
  module_function

  def defaults_export_domain(runner: Open3.method(:capture3))
    %w[com.metacubex.ClashX.meta com.MetaCubeX.ClashX.meta].each do |domain|
      plist, _export_error, export_status = runner.call("/usr/bin/defaults", "export", domain, "-")
      next unless export_status.success? && !plist.empty?

      return { domain: domain, plist: plist }
    rescue StandardError
      next
    end
    nil
  end

  def plist_raw_value(plist, key, runner: Open3.method(:capture3))
    value, _extract_error, extract_status = runner.call(
      "/usr/bin/plutil", "-extract", key, "raw", "-o", "-", "-", stdin_data: plist
    )
    value = value.to_s.strip
    extract_status.success? && !value.empty? ? value : ""
  rescue StandardError
    ""
  end

  def defaults_read(key, runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    return "" unless exported

    plist_raw_value(exported.fetch(:plist), key, runner: runner)
  end

  def disable_subscription_auto_update(backup_root:, runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless exported

    domain = exported.fetch(:domain)
    original = plist_raw_value(exported.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    state = subscription_auto_update_state(original)
    return { status: :already_disabled, domain: domain } if state == :disabled
    raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态" unless state == :enabled

    backup = {
      "Version" => 1,
      "Domain" => domain,
      "Key" => "kAutoUpdateEnable",
      "Value" => original,
      "RecordedAt" => Time.now.iso8601
    }
    backup_path = File.join(backup_root, "clashx-meta-kAutoUpdateEnable.json")
    created_backup = create_versioned_backup(
      backup_path, backup_root, content: JSON.generate(backup) + "\n", reason: "preference"
    )

    _output, error, write_status = runner.call(
      "/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "false"
    )
    unless write_status.success?
      begin
        enable_subscription_auto_update(runner: runner)
      rescue InvalidConfigError, SystemCallError, IOError => restore_error
        raise IOError, "无法关闭订阅自动更新，且恢复原值失败：#{restore_error.message}"
      end
      raise IOError, "无法关闭 ClashX Meta 订阅自动更新：#{error.to_s.strip}"
    end

    verified_export = defaults_export_domain(runner: runner)
    verified_value = if verified_export && verified_export.fetch(:domain) == domain
                       plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
                     else
                       ""
                     end
    unless subscription_auto_update_state(verified_value) == :disabled
      begin
        enable_subscription_auto_update(runner: runner)
      rescue InvalidConfigError, SystemCallError, IOError => restore_error
        raise IOError, "订阅自动更新设置回读失败，且恢复原值失败：#{restore_error.message}"
      end
      raise IOError, "ClashX Meta 订阅自动更新设置回读失败，已经恢复原值"
    end

    { status: :disabled, domain: domain, backup: created_backup }
  end

  def enable_subscription_auto_update(runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless exported

    domain = exported.fetch(:domain)
    current = plist_raw_value(exported.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    state = subscription_auto_update_state(current)
    return { status: :already_enabled, domain: domain } if state == :enabled
    raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态" unless state == :disabled

    _output, error, write_status = runner.call(
      "/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "true"
    )
    raise IOError, "无法恢复 ClashX Meta 订阅自动更新：#{error.to_s.strip}" unless write_status.success?

    verified_export = defaults_export_domain(runner: runner)
    verified_value = if verified_export && verified_export.fetch(:domain) == domain
                       plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
                     else
                       ""
                     end
    raise IOError, "ClashX Meta 订阅自动更新恢复后回读失败" unless subscription_auto_update_state(verified_value) == :enabled

    { status: :enabled, domain: domain }
  end

  def selected_profile_name
    defaults_read("selectConfigName")
  end

  def icloud_enabled?
    storage_mode == :icloud
  end

  def storage_mode(value = defaults_read("kUserEnableiCloud"))
    normalized = value.to_s.strip.downcase
    return :icloud if %w[1 true yes].include?(normalized)
    return :local if %w[0 false no].include?(normalized)

    :unknown
  end

  def subscription_auto_update_state(value = defaults_read("kAutoUpdateEnable"))
    normalized = value.to_s.strip.downcase
    return :disabled if %w[0 false no].include?(normalized)
    return :enabled if %w[1 true yes].include?(normalized)

    :unknown
  end

  def remote_subscription_records(raw = defaults_read("kRemoteConfigs"))
    decoded = Base64.strict_decode64(raw.to_s.strip)
    records = JSON.parse(decoded)
    raise InvalidConfigError, "远程订阅清单无效" unless records.is_a?(Array) && !records.empty?

    records.map do |record|
      name = record.is_a?(Hash) ? record["name"].to_s.strip : ""
      url = record.is_a?(Hash) ? record["url"].to_s.strip : ""
      raise InvalidConfigError, "远程订阅清单缺少名称或地址" if name.empty? || url.empty?
      raise InvalidConfigError, "远程订阅地址不是 HTTPS" unless url.start_with?("https://")
      raise InvalidConfigError, "远程订阅名称包含非法字符" if name.include?("/") || name.include?("\\") || name.include?("\0")

      { name: name, url: url }
    end
  rescue ArgumentError, JSON::ParserError
    raise InvalidConfigError, "远程订阅清单无效"
  end

  def remote_subscription_targets(directories, records = remote_subscription_records)
    paths = directories.flat_map { |directory| profile_paths(directory) }
    targets = records.map do |record|
      matches = paths.select do |path|
        basename = File.basename(path)
        stem = basename.sub(/\.ya?ml\z/i, "")
        basename.casecmp(record.fetch(:name)).zero? || stem.casecmp(record.fetch(:name)).zero?
      end
      raise InvalidConfigError, "远程订阅无法对应到唯一配置文件" unless matches.length == 1

      record.merge(path: matches.first)
    end
    raise InvalidConfigError, "多个远程订阅对应到同一配置文件" unless targets.map { |target| File.expand_path(target.fetch(:path)) }.uniq.length == targets.length

    targets
  end

  def curl_config_value(value)
    raise InvalidConfigError, "远程订阅地址无效" if value.include?("\r") || value.include?("\n")

    value.gsub("\\", "\\\\").gsub('"', '\\"')
  end

  def fetch_remote_subscription(target, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    config = <<~CURL
      url = "#{curl_config_value(target.fetch(:url))}"
      silent
      show-error
      fail
      location
      proto = "=https"
      max-time = #{Integer(timeout_seconds)}
    CURL
    stdout, _stderr, status = Open3.capture3(
      "/usr/bin/curl", "--config", "-", stdin_data: config, binmode: true
    )
    raise InvalidConfigError, "远程订阅下载失败" unless status.success? && !stdout.empty?

    stdout
  rescue KeyError, ArgumentError
    raise InvalidConfigError, "远程订阅下载失败"
  end

  def build_update_candidate(target, source, policy, usage_profile, validator)
    bytes = source.to_s.b
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "远程订阅内容不是有效 UTF-8" unless text.valid_encoding?

    config = load_yaml(text, target.fetch(:name))
    raise InvalidConfigError, "远程订阅内容无效" unless usable_config?(config)
    patched = patch(config, policy, usage_profile: usage_profile)
    raise InvalidConfigError, "远程订阅无法应用共享补丁" unless %i[updated unchanged].include?(patched.fetch(:status))
    candidate = patched.fetch(:config)
    output = dump_config(candidate).b
    reparsed = load_yaml(output.dup.force_encoding(Encoding::UTF_8), target.fetch(:name))
    second = patch(reparsed, policy, usage_profile: usage_profile)
    raise InvalidConfigError, "远程订阅二次转换不一致" if second.fetch(:changed) || dump_config(second.fetch(:config)).b != output

    Tempfile.create([".clash-patch-update-", ".yaml"], File.dirname(File.realpath(target.fetch(:path)))) do |temporary|
      temporary.binmode
      temporary.write(output)
      temporary.flush
      temporary.fsync
      validation = validator.call(temporary.path)
      raise InvalidConfigError, "远程订阅校验超时" if validation == :timeout
      raise InvalidConfigError, "远程订阅未通过 Mihomo 校验" unless validation == true
    end
    output
  end

  def replace_profile_bytes(path, bytes)
    write_path = File.realpath(path)
    File.open(write_path, "r+b") do |source|
      source.flock(File::LOCK_EX)
      write_locked_profile(source, bytes)
    end
  end

  def write_locked_profile(handle, bytes)
    handle.rewind
    handle.write(bytes)
    handle.truncate(bytes.bytesize)
    handle.flush
    handle.fsync
  end

  def locked_profile_current?(handle, path)
    opened = handle.stat
    current = File.stat(File.realpath(path))
    opened.dev == current.dev && opened.ino == current.ino
  rescue StandardError
    false
  end

  def default_safe_update_activation(items, usage_profile, selected_name = selected_profile_name)
    active = items.find { |item| active_profile?(item.fetch(:path), selected_name) }
    return true unless active

    result = {
      path: active.fetch(:path), status: :updated, active: true,
      rollback_bytes: active.fetch(:original), patched_digest: Digest::SHA256.hexdigest(active.fetch(:candidate))
    }
    activate_updated_profile(result, require_tun: usage_profile >= 2)
  end

  def safe_update_all(targets:, policy:, backup_root:, usage_profile:, fetcher: method(:fetch_remote_subscription),
                      validator: method(:validate_with_mihomo), activation: nil, selected_name: nil)
    raise InvalidConfigError, "用途档位无效" unless [1, 2, 3].include?(usage_profile)
    raise InvalidConfigError, "没有可更新的远程订阅" unless targets.is_a?(Array) && !targets.empty?

    items = targets.map do |target|
      path = target.fetch(:path)
      original = File.binread(File.realpath(path))
      source = fetcher.call(target)
      candidate = build_update_candidate(target, source, policy, usage_profile, validator)
      { name: target.fetch(:name), path: path, original: original, candidate: candidate }
    rescue StandardError
      return { status: :aborted, failed_profile: target[:name].to_s, reason: :download_or_validation_failed }
    end

    identities = items.map do |item|
      stat = File.stat(File.realpath(item.fetch(:path)))
      [stat.dev, stat.ino]
    end
    if identities.uniq.length != identities.length
      return { status: :aborted, failed_profile: "", reason: :duplicate_target }
    end

    handles = []
    concurrent_change = false
    begin
      items.sort_by { |item| File.expand_path(item.fetch(:path)) }.each do |item|
        handle = File.open(File.realpath(item.fetch(:path)), "r+b")
        handle.flock(File::LOCK_EX)
        handles << [item, handle]
      end
      unless handles.all? do |item, handle|
               locked_profile_current?(handle, item.fetch(:path)) &&
                 handle.rewind && handle.read == item.fetch(:original)
             end
        return { status: :aborted, failed_profile: "", reason: :concurrent_change }
      end

      handles.each do |item, _handle|
        create_versioned_backup(item.fetch(:path), backup_root, content: item.fetch(:original), reason: "pre-update")
      end
      handles.each do |item, handle|
        unless locked_profile_current?(handle, item.fetch(:path))
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        write_locked_profile(handle, item.fetch(:candidate))
        unless locked_profile_current?(handle, item.fetch(:path))
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
      end
      unless handles.all? do |item, handle|
               locked_profile_current?(handle, item.fetch(:path)) &&
                 handle.rewind && handle.read == item.fetch(:candidate)
             end
        concurrent_change = true
        raise IOError, "subscription path changed during safe update"
      end
    rescue StandardError
      rollback_failures = []
      handles.each do |item, handle|
        begin
          handle.rewind
          handle.write(item.fetch(:original))
          handle.truncate(item.fetch(:original).bytesize)
          handle.flush
          handle.fsync
        rescue StandardError
          rollback_failures << item.fetch(:name)
        end
      end
      unless rollback_failures.empty?
        reason = concurrent_change ? :concurrent_change : :write_failed
        return { status: :rollback_failed, failed_profile: rollback_failures.first, reason: reason }
      end
      reason = concurrent_change ? :concurrent_change : :write_failed
      return { status: :aborted, failed_profile: "", reason: reason }
    ensure
      handles.each { |_item, handle| handle.close rescue nil }
    end

    activation ||= ->(updated_items) { default_safe_update_activation(updated_items, usage_profile, selected_name) }
    activation_result = begin
      activation.call(items)
    rescue StandardError
      false
    end
    activated = activation_result == true ||
                (activation_result.is_a?(Hash) && activation_result[:reloaded] == true)
    runtime_status = activation_result[:status] if activation_result.is_a?(Hash)
    unless activated
      rollback_failures = []
      items.each do |item|
        restored = begin
          current = File.binread(File.realpath(item.fetch(:path)))
          current == item.fetch(:original) ||
            (current == item.fetch(:candidate) && replace_profile_bytes(item.fetch(:path), item.fetch(:original)))
        rescue StandardError
          false
        end
        rollback_failures << item.fetch(:name) unless restored
      end
      unless rollback_failures.empty?
        return { status: :rollback_failed, failed_profile: rollback_failures.first, reason: :activation_failed }
      end
      if %i[reload_failed_restore_pending reload_failed_rollback_conflict].include?(runtime_status)
        return {
          status: :runtime_restore_pending, failed_profile: "", reason: :activation_failed,
          runtime_status: runtime_status
        }
      end
      return { status: :aborted, failed_profile: "", reason: :activation_failed }
    end

    { status: :updated, count: items.length, profiles: items.map { |item| item.fetch(:name) } }
  rescue InvalidConfigError
    raise
  rescue StandardError
    { status: :aborted, failed_profile: "", reason: :unexpected_error }
  end

  def clashx_app_paths
    ["/Applications/ClashX Meta.app", File.expand_path("~/Applications/ClashX Meta.app")].select { |path| Dir.exist?(path) }
  end

  def icloud_container_ids(app_paths = clashx_app_paths)
    ids = %w[iCloud.com.metacubex.ClashX iCloud.com.west2online.ClashX]
    app_paths.each do |app|
      plist = File.join(app, "Contents", "Info.plist")
      next unless File.file?(plist)

      json, status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", plist)
      next unless status.success?

      containers = JSON.parse(json)["NSUbiquitousContainers"]
      ids.concat(containers.keys) if containers.is_a?(Hash)
    rescue StandardError
      next
    end
    ids.uniq
  end

  def icloud_container_roots(home: Dir.home, app_paths: clashx_app_paths)
    base = File.join(home, "Library", "Mobile Documents")
    icloud_container_ids(app_paths).map do |identifier|
      File.join(base, identifier.tr(".", "~"))
    end.uniq
  end

  def default_profile_directories(home: Dir.home, app_paths: clashx_app_paths, cloud_enabled: nil, selected: nil)
    local = File.join(home, ".config", "clash.meta")
    clouds = icloud_container_roots(home: home, app_paths: app_paths).map { |root| File.join(root, "Documents") }
    mode = cloud_enabled.nil? ? storage_mode : (cloud_enabled ? :icloud : :local)
    return [] if mode == :unknown
    return Dir.exist?(local) ? [local] : [] if mode == :local

    selected = selected_profile_name if selected.nil?
    existing_clouds = clouds.select { |path| Dir.exist?(path) }.uniq
    matching = existing_clouds.select do |root|
      profile_paths(root).any? { |path| active_profile?(path, selected) }
    end
    return [] if matching.empty? && existing_clouds.length > 1

    candidates = matching.empty? ? existing_clouds : matching
    chosen = candidates.max_by do |root|
      selected_paths = profile_paths(root).select { |path| active_profile?(path, selected) }
      selected_paths.map { |path| File.mtime(path).to_f }.max || 0
    end
    chosen ? [chosen] : []
  end

  def active_profile?(path, selected)
    selected_name = File.basename(selected.to_s)
    selected_name = "config.yaml" if selected_name.empty?
    selected_stem = selected_name.sub(/\.ya?ml\z/i, "")
    profile_name = File.basename(path)
    profile_stem = profile_name.sub(/\.ya?ml\z/i, "")
    profile_name.casecmp(selected_name).zero? || profile_stem.casecmp(selected_stem).zero?
  end

  def active_profile_root(roots, selected, directory = nil)
    return directory if directory
    return roots.first if roots.length == 1

    matching = roots.select { |root| profile_paths(root).any? { |path| active_profile?(path, selected) } }
    candidates = matching.empty? ? roots : matching
    preferred = if icloud_enabled?
                  candidates.find { |path| path.include?("/Library/Mobile Documents/") }
                else
                  candidates.find { |path| path.end_with?("/.config/clash.meta") }
                end
    preferred || matching.first
  end

end
