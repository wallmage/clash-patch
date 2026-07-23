module ClashPatch
  module_function

  def controller_socket
    cache_directories = [
      File.expand_path("~/Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs"),
      File.expand_path("~/Library/Caches/com.metacubex.ClashX.meta/cacheConfigs")
    ]
    cache_directories.each do |directory|
      candidates = Dir.glob(File.join(directory, "*.yaml")).each_with_object([]) do |path, entries|
        entries << [path, File.mtime(path)]
      rescue SystemCallError
        next
      end
      candidates.sort_by { |_path, modified| modified }.reverse_each do |path, _modified|
        config = load_yaml(File.read(path, encoding: "UTF-8"), path)
        socket = config["external-controller-unix"] if config.is_a?(Hash)
        return socket if socket.is_a?(String) && File.socket?(socket)
      rescue StandardError
        next
      end
    end
    nil
  end

  def controller_request(socket, method, path, body = nil)
    arguments = ["/usr/bin/curl", "-sS", "--max-time", "3", "-X", method, "--unix-socket", socket,
                 "-o", "-", "-w", "\n%{http_code}"]
    arguments.concat(["-H", "Content-Type: application/json", "--data", body]) if body
    arguments << "http://localhost#{path}"
    output, status = Open3.capture2e(*arguments)
    return [0, ""] unless status.success?

    response_body, code = output.rpartition("\n").values_at(0, 2)
    [code.to_i, response_body]
  rescue StandardError
    [0, ""]
  end

  def tun_state(socket: nil, requester: nil)
    if requester.nil?
      socket ||= controller_socket
      return :unknown unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end

    request = requester
    status, body = request.call("GET", "/configs", nil)
    return :unknown unless status == 200

    config = JSON.parse(body)
    return :unknown unless config.is_a?(Hash) && config["tun"].is_a?(Hash)

    enabled = config.dig("tun", "enable")
    return :enabled if enabled == true
    return :disabled if enabled == false

    :unknown
  rescue JSON::ParserError
    :unknown
  end

  def runtime_selections(requester)
    status, body = requester.call("GET", "/proxies", nil)
    return nil unless status == 200

    payload = JSON.parse(body)
    proxies = payload["proxies"]
    return nil unless proxies.is_a?(Hash)

    proxies.each_with_object({}) do |(name, proxy), selections|
      next unless proxy.is_a?(Hash) && proxy["now"].is_a?(String)
      next unless proxy["type"].to_s.casecmp("Selector").zero?

      selections[name] = proxy["now"]
    end
  rescue JSON::ParserError
    nil
  end

  def dns_runtime_healthy?(requester, name)
    status, body = requester.call("GET", "/dns/query?name=#{name}&type=A", nil)
    return false unless status == 200

    payload = JSON.parse(body)
    dns_status = payload["Status"] || payload["status"]
    answers = payload["Answer"] || payload["answer"]
    dns_status.to_i.zero? && answers.is_a?(Array) && !answers.empty?
  rescue JSON::ParserError
    false
  end

  def default_connectivity_healthy?
    3.times do
      _output, status = Open3.capture2e(
        "/usr/bin/curl", "-sS", "--max-time", "8", "-o", "/dev/null",
        "https://www.google.com/generate_204"
      )
      return true if status.success?
    rescue StandardError
      next
    end
    false
  end

  def restore_profile_bytes(result)
    original = result[:rollback_bytes]
    expected = result[:patched_digest]
    return false unless original.is_a?(String) && expected.is_a?(String)

    write_path = File.realpath(result.fetch(:path))
    File.open(write_path, "r+b") do |source|
      source.flock(File::LOCK_EX)
      current = source.read
      return false unless Digest::SHA256.hexdigest(current) == expected

      source.rewind
      source.write(original)
      source.truncate(original.bytesize)
      source.flush
      source.fsync
    end
    true
  rescue SystemCallError, IOError, KeyError
    false
  end

  def activate_updated_profile(result, socket: nil, requester: nil, connectivity_checker: nil, require_tun: true)
    if requester.nil?
      socket ||= controller_socket
      return result.merge(status: rollback_after_reload_failure(result, nil, nil)) unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    connectivity_checker ||= method(:default_connectivity_healthy?)

    before = runtime_selections(requester)
    return result.merge(status: rollback_after_reload_failure(result, requester, result[:path])) unless before
    preserved_tun_state = tun_state(requester: requester) if require_tun == :preserve
    if require_tun == :preserve && preserved_tun_state == :unknown
      return result.merge(status: rollback_after_reload_failure(result, nil, nil))
    end

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(result.fetch(:path)))
    )
    unless code == 204
      return result.merge(status: rollback_after_reload_failure(result, nil, nil))
    end

    caches_flushed = ["/cache/fakeip/flush", "/cache/dns/flush"].all? do |endpoint|
      cache_code, _cache_body = requester.call("POST", endpoint, nil)
      [200, 204].include?(cache_code)
    end
    unless caches_flushed
      return result.merge(status: rollback_after_reload_failure(result, requester, result[:path]))
    end

    healthy = if require_tun == :preserve
                tun_state(requester: requester) == preserved_tun_state
              else
                !require_tun || tun_state(requester: requester) == :enabled
              end
    after = healthy ? runtime_selections(requester) : nil
    healthy &&= after.is_a?(Hash)
    healthy &&= before.all? { |name, selected| after.key?(name) && after[name] == selected }
    healthy &&= dns_runtime_healthy?(requester, "www.baidu.com")
    healthy &&= dns_runtime_healthy?(requester, "www.google.com")
    healthy &&= connectivity_checker.call

    return result.merge(reloaded: true) if healthy

    result.merge(status: rollback_after_reload_failure(result, requester, result[:path]))
  rescue StandardError
    result.merge(status: rollback_after_reload_failure(result, requester, result[:path]))
  end

  def rollback_after_reload_failure(result, requester, path)
    return :reload_failed_rollback_conflict unless restore_profile_bytes(result)
    return :reload_failed_rolled_back unless requester && path

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(path))
    )
    code == 204 ? :reload_failed_rolled_back : :reload_failed_restore_pending
  rescue StandardError
    :reload_failed_restore_pending
  end

end
