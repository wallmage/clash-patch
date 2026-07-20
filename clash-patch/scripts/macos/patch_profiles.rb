#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "psych"
require "tempfile"
require "uri"

module ClashPatch
  module_function

  AI_GROUP_BASE = "🤖 AI · Clash Patch".freeze
  SAFE_GROUP_BASE = "🛡 安全代理 · Clash Patch".freeze
  DIRECT_TYPES = %w[direct reject pass compatible].freeze
  DIRECT_NAMES = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE].freeze
  EXCLUDED_SAFE_TYPES = "Direct|Reject|Pass|Compatible".freeze

  TUN_POLICY = {
    "enable" => true,
    "stack" => "system",
    "dns-hijack" => ["any:53", "tcp://any:53"],
    "auto-route" => true,
    "auto-detect-interface" => true,
    "strict-route" => true
  }.freeze

  BROAD_PROVIDER_PATTERN = /(?:^|[-_])(ai|cn|china|direct|domestic|global|notcn|proxy)(?:$|[-_])/i

  class YAML12ScalarScanner < Psych::ScalarScanner
    INTEGER = /\A[-+]?(?:0|[1-9][0-9_]*|0o[0-7_]+|0x[0-9a-fA-F_]+|0b[01_]+)\z/.freeze
    FLOAT = /\A[-+]?(?:(?:[0-9][0-9_]*)?\.[0-9_]+|[0-9][0-9_]*\.[0-9_]*|[0-9][0-9_]*(?:\.[0-9_]*)?[eE][-+]?[0-9]+)\z/.freeze

    def tokenize(string)
      return nil if string.empty? || string.match?(/\A(?:~|null)\z/i)
      return true if string.match?(/\Atrue\z/i)
      return false if string.match?(/\Afalse\z/i)
      return Float::INFINITY if string.match?(/\A\+?\.inf\z/i)
      return -Float::INFINITY if string.match?(/\A-\.inf\z/i)
      return Float::NAN if string.match?(/\A\.nan\z/i)

      clean = string.delete("_")
      return Integer(clean) if string.match?(INTEGER)
      return Float(clean) if string.match?(FLOAT)

      string
    rescue ArgumentError
      string
    end
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def base_result(config, status, changed: false)
    {
      config: config,
      changed: changed,
      status: status,
      ai_group: nil,
      safe_group: nil,
      main_group: nil,
      selected_home: nil
    }
  end

  def usable_config?(config)
    return false unless config.is_a?(Hash)
    return false unless config["proxy-groups"].is_a?(Array)
    return false unless config["rules"].is_a?(Array)

    config["proxies"].is_a?(Array) || config["proxy-providers"].is_a?(Hash)
  end

  def selectable_groups(config)
    Array(config["proxy-groups"]).select do |group|
      group.is_a?(Hash) && group["name"].is_a?(String) && group["type"].to_s.downcase == "select"
    end
  end

  def managed_name?(name, base)
    name.is_a?(String) && name.match?(/\A#{Regexp.escape(base)}(?: [2-9][0-9]*)?\z/)
  end

  def managed_group_name?(name)
    managed_name?(name, AI_GROUP_BASE) || managed_name?(name, SAFE_GROUP_BASE)
  end

  def detect_main_group(config, policy)
    candidates = selectable_groups(config).reject do |group|
      ai_name?(group["name"], policy) || managed_group_name?(group["name"])
    end
    names = candidates.map { |group| group["name"] }

    match_rule = Array(config["rules"]).reverse.find { |rule| rule.to_s.start_with?("MATCH,") }
    match_target = match_rule.to_s.split(",", 2)[1]
    return match_target if match_target != "DIRECT" && names.include?(match_target)

    references = Hash.new(0)
    Array(config["rules"]).each do |rule|
      next unless broad_rule?(rule)

      parts = rule.to_s.split(",")
      target = parts[-1]
      target = parts[-2] if target == "no-resolve"
      references[target] += 1 if names.include?(target)
    end
    frequent = references.max_by { |name, count| [count, -names.index(name)] }
    return frequent[0] if frequent && frequent[1] > 1

    Array(policy["main_group_names"]).each do |preferred|
      found = names.find { |name| name.casecmp(preferred).zero? }
      return found if found
    end

    candidates.each do |group|
      return group["name"] unless Array(group["use"]).empty?

      members = Array(group["proxies"])
      return group["name"] unless members.empty? || members.all? { |member| direct_name?(member) }
    end
    nil
  end

  def ai_name?(name, policy)
    return false unless name.is_a?(String)
    return true if Array(policy["ai_group_names"]).any? { |candidate| name.casecmp(candidate).zero? }

    normalized = name.downcase
    normalized.include?("openai") || normalized.include?("人工智能") || normalized.match?(/(^|[^a-z])ai([^a-z]|$)/)
  end

  def token_match?(name, token)
    return false unless name.is_a?(String)
    return name.downcase.include?(token.downcase) unless %w[TW JP].include?(token)

    name.match?(/(?:^|[^A-Za-z])#{Regexp.escape(token)}(?:[^A-Za-z]|$)/i)
  end

  def home_candidate(config, policy)
    group_names = Array(config["proxy-groups"]).map do |group|
      group["name"] if group.is_a?(Hash) && group["name"].is_a?(String)
    end.compact
    candidates = Array(config["proxies"]).map do |proxy|
      proxy["name"] if proxy.is_a?(Hash) && proxy["name"].is_a?(String)
    end.compact
    Array(config["proxy-groups"]).each do |group|
      Array(group["proxies"]).each do |name|
        candidates << name if name.is_a?(String) && !group_names.include?(name)
      end
    end
    candidates = candidates.uniq.select { |name| name.include?("家宽") }

    taiwan = candidates.find { |name| Array(policy["taiwan_tokens"]).any? { |token| token_match?(name, token) } }
    return taiwan if taiwan

    candidates.find { |name| Array(policy["japan_tokens"]).any? { |token| token_match?(name, token) } }
  end

  def unique_group_name(config, base)
    names = Array(config["proxy-groups"]).map { |group| group["name"] if group.is_a?(Hash) }.compact
    return base unless names.include?(base)

    suffix = 2
    suffix += 1 while names.include?("#{base} #{suffix}")
    "#{base} #{suffix}"
  end

  def find_managed_select_group(config, base)
    selectable_groups(config).find { |group| managed_name?(group["name"], base) }
  end

  def ensure_ai_group(config, main_group, candidate)
    group = find_managed_select_group(config, AI_GROUP_BASE)
    unless group
      group = { "name" => unique_group_name(config, AI_GROUP_BASE), "type" => "select" }
      config["proxy-groups"] << group
    end

    group.keys.each { |key| group.delete(key) unless %w[name type].include?(key) }
    group["type"] = "select"
    group["proxies"] = [candidate || main_group].reject { |name| name == group["name"] }
    group["name"]
  end

  def direct_name?(name)
    DIRECT_NAMES.any? { |candidate| candidate.casecmp(name.to_s).zero? }
  end

  def safe_inline_proxies(config)
    Array(config["proxies"]).map do |proxy|
      next unless proxy.is_a?(Hash) && proxy["name"].is_a?(String)
      next if DIRECT_TYPES.include?(proxy["type"].to_s.downcase)

      proxy["name"]
    end.compact.uniq
  end

  def ensure_safe_group(config, candidate)
    group = find_managed_select_group(config, SAFE_GROUP_BASE)
    unless group
      group = { "name" => unique_group_name(config, SAFE_GROUP_BASE), "type" => "select" }
      config["proxy-groups"] << group
    end

    proxies = safe_inline_proxies(config)
    if candidate && proxies.delete(candidate)
      proxies.unshift(candidate)
    end
    group.keys.each { |key| group.delete(key) unless %w[name type].include?(key) }
    group["type"] = "select"
    group["proxies"] = proxies.reject { |name| name == group["name"] }
    group["include-all"] = true
    group["exclude-type"] = EXCLUDED_SAFE_TYPES
    group["empty-fallback"] = "REJECT"
    group["name"]
  end

  def tagged_resolvers(policy, group)
    Array(policy["resolvers"]).map { |resolver| "#{resolver}##{group}" }
  end

  def ai_dns_patterns(policy)
    Array(policy["ai_rules"]).each_with_object([]) do |template, patterns|
      type, value, = template.split(",")
      case type
      when "DOMAIN-SUFFIX" then patterns << "+.#{value}"
      when "DOMAIN" then patterns << value
      end
    end.uniq
  end

  def safe_proxy_target?(config, target)
    Array(config["proxies"]).any? do |proxy|
      proxy.is_a?(Hash) && proxy["name"] == target && !DIRECT_TYPES.include?(proxy["type"].to_s.downcase)
    end
  end

  def group_cannot_reach_direct?(config, target, visiting = [])
    return false if direct_name?(target) || visiting.include?(target)

    group = Array(config["proxy-groups"]).find { |item| item.is_a?(Hash) && item["name"] == target }
    return false unless group

    members = Array(group["proxies"])
    member_safe = members.all? do |member|
      safe_proxy_target?(config, member) || group_cannot_reach_direct?(config, member, visiting + [target])
    end
    provider_safe = Array(group["use"]).all? { |name| config.fetch("proxy-providers", {}).key?(name) }
    provider_safe &&= !Array(group["use"]).empty?
    include_all_safe = group["include-all"] == true && group["exclude-type"].to_s.downcase.include?("direct")

    member_safe && (!members.empty? || provider_safe || include_all_safe)
  end

  def safe_resolver_endpoint?(config, endpoint)
    fragment = endpoint.to_s.split("#", 2)[1]
    return false if fragment.nil? || fragment.empty?

    target = fragment.split("&", 2).first.to_s
    return false if target.empty? || target.include?("=") || direct_name?(target)

    safe_proxy_target?(config, target) || group_cannot_reach_direct?(config, target)
  end

  def patch_dns(config, policy, safe_group)
    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["ipv6"] = false
    dns["respect-rules"] = true
    dns["use-hosts"] = true
    dns["use-system-hosts"] = true

    safe_resolvers = tagged_resolvers(policy, safe_group)
    dns["default-nameserver"] = deep_copy(policy["default_bootstrap_resolvers"])
    dns["proxy-server-nameserver"] = deep_copy(policy["proxy_bootstrap_resolvers"])
    dns["nameserver"] = deep_copy(safe_resolvers)
    dns["fallback"] = deep_copy(safe_resolvers) if dns.key?("fallback")
    dns["direct-nameserver"] = deep_copy(safe_resolvers) if dns.key?("direct-nameserver")

    existing = dns["nameserver-policy"].is_a?(Hash) ? dns["nameserver-policy"] : {}
    policies = {}
    existing.each do |combined, endpoints|
      combined.to_s.split(",").map(&:strip).reject(&:empty?).each do |pattern|
        values = Array(endpoints).map(&:to_s)
        policies[pattern] = !values.empty? && values.all? { |value| safe_resolver_endpoint?(config, value) } ? values : deep_copy(safe_resolvers)
      end
    end
    ai_dns_patterns(policy).each { |pattern| policies[pattern] = deep_copy(safe_resolvers) }
    dns["nameserver-policy"] = policies
  end

  def managed_rule_identity(rule)
    parts = rule.to_s.split(",")
    parts.length < 2 ? nil : [parts[0], parts[1]]
  end

  def render_ai_rules(policy, ai_group)
    Array(policy["ai_rules"]).map { |template| template.sub("{AI}") { ai_group } }
  end

  def broad_rule?(rule)
    parts = rule.to_s.split(",")
    return true if parts[0] == "MATCH"
    return true if %w[GEOSITE GEOIP].include?(parts[0])
    return false unless parts[0] == "RULE-SET"

    provider = parts[1].to_s
    provider.match?(BROAD_PROVIDER_PATTERN) || provider.match?(/国内|国外|节点|兜底/)
  end

  def patch_rules(config, policy, ai_group, safe_group)
    managed = render_ai_rules(policy, ai_group)
    identities = managed.map { |rule| managed_rule_identity(rule) }.compact
    forbidden = Array(policy["forbidden_ai_domains"])
    ai_names = Array(config["proxy-groups"]).map do |group|
      group["name"] if group.is_a?(Hash) && ai_name?(group["name"], policy)
    end.compact
    ai_names << ai_group
    ai_names.uniq!

    rules = Array(config["rules"]).reject do |rule|
      parts = rule.to_s.split(",")
      target = parts[-1] == "no-resolve" ? parts[-2] : parts[-1]
      managed_existing = identities.include?(managed_rule_identity(rule))
      forbidden_ai = %w[DOMAIN DOMAIN-SUFFIX].include?(parts[0]) && forbidden.include?(parts[1]) && ai_names.include?(target)
      generic_udp = parts[0] == "NETWORK" && parts[1] == "UDP"
      managed_existing || forbidden_ai || generic_udp
    end

    anchor = rules.index { |rule| broad_rule?(rule) } || rules.length
    rules.insert(anchor, *managed, "NETWORK,UDP,#{safe_group}", "NETWORK,UDP,REJECT")
    config["rules"] = rules
  end

  def normalize_reality_short_ids(value)
    case value
    when Hash
      value.each do |key, child|
        if key.to_s == "short-id" && child.is_a?(String) && child.match?(/\A[0-9a-fA-F]{1,16}\z/)
          value[key] = child.dup
        else
          normalize_reality_short_ids(child)
        end
      end
    when Array
      value.each { |child| normalize_reality_short_ids(child) }
    end
    value
  end

  def patch(config, policy)
    return base_result(config, :invalid) unless usable_config?(config)

    original = deep_copy(config)
    patched = deep_copy(config)
    main_group = detect_main_group(patched, policy)
    return base_result(config, :no_main_group) unless main_group

    candidate = home_candidate(patched, policy)
    ai_group = ensure_ai_group(patched, main_group, candidate)
    safe_group = ensure_safe_group(patched, candidate)
    patched["ipv6"] = false
    patched["tun"] = {} unless patched["tun"].is_a?(Hash)
    TUN_POLICY.each { |key, value| patched["tun"][key] = deep_copy(value) }
    patch_dns(patched, policy, safe_group)
    patch_rules(patched, policy, ai_group, safe_group)
    normalize_reality_short_ids(patched)

    {
      config: patched,
      changed: patched != original,
      status: patched == original ? :unchanged : :updated,
      ai_group: ai_group,
      safe_group: safe_group,
      main_group: main_group,
      selected_home: candidate
    }
  end

  def dump_config(config)
    Psych.dump(config)
  end

  def tag_reality_short_ids(node)
    case node
    when Psych::Nodes::Mapping
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar) && key.value == "short-id" &&
           value.is_a?(Psych::Nodes::Scalar) && value.value.match?(/\A[0-9a-fA-F]{1,16}\z/)
          value.tag = "tag:yaml.org,2002:str"
        end
        tag_reality_short_ids(value)
      end
    when Psych::Nodes::Document, Psych::Nodes::Sequence, Psych::Nodes::Stream
      node.children.each { |child| tag_reality_short_ids(child) }
    end
    node
  end

  def load_yaml(text, filename = nil)
    # REALITY short-id is schema-defined text, but a valid hexadecimal value
    # can also resemble a YAML number (for example 0906152e4 or 12345678).
    # Tag only that field as text before scalar resolution so unrelated YAML
    # 1.2 exponent values keep their numeric meaning.
    document = Psych.parse(text, filename)
    return nil unless document
    tag_reality_short_ids(document)

    class_loader = Psych::ClassLoader::Restricted.new([], [])
    scanner = YAML12ScalarScanner.new(class_loader)
    Psych::Visitors::ToRuby.new(scanner, class_loader).accept(document)
  end

  def excluded_path?(path)
    basename = File.basename(path)
    basename.start_with?(".") || basename.match?(/(?:\.tmp|\.bak|\.backup)\z/i)
  end

  def profile_paths(directory)
    return [] unless Dir.exist?(directory)

    Dir.children(directory).sort.map do |basename|
      path = File.join(directory, basename)
      next if excluded_path?(path)
      next unless basename.match?(/\.ya?ml\z/i) && File.file?(path)

      path
    end.compact
  end

  def backup_once(path, backup_root)
    FileUtils.mkdir_p(backup_root)
    FileUtils.chmod(0o700, backup_root)
    key = Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
    destination = File.join(backup_root, "#{key}-#{File.basename(path)}.backup")
    FileUtils.cp(path, destination) unless File.exist?(destination)
    FileUtils.chmod(0o600, destination)
  end

  def validate_with_mihomo(path)
    core = mihomo_core_path
    return true unless core

    system(core, "-d", mihomo_validation_directory(path), "-t", "-f", path, out: File::NULL, err: File::NULL)
  end

  def mihomo_validation_directory(path)
    local = File.expand_path("~/.config/clash.meta")
    Dir.exist?(local) ? local : File.dirname(path)
  end

  def mihomo_core_path
    candidates = [
      File.expand_path("~/Library/Application Support/com.metacubex.ClashX.meta/.private_core/com.metacubex.ClashX.ProxyConfigHelper.meta"),
      "/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta",
      File.expand_path("~/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta")
    ]
    candidates.find { |path| File.file?(path) && File.executable?(path) }
  end

  def patch_path(path, policy, dry_run: false, backup_root: nil, validator: nil)
    write_path = File.realpath(path)
    original_text = File.read(write_path, encoding: "UTF-8")
    config = load_yaml(original_text, path)
    result = patch(config, policy)
    return result.merge(path: path) unless result[:changed]

    patched_text = dump_config(result[:config])
    return result.merge(path: path, dry_run: true) if dry_run

    mode = File.stat(write_path).mode & 0o777
    Tempfile.create([File.basename(write_path), ".tmp"], File.dirname(write_path), encoding: "UTF-8") do |temporary|
      temporary.write(patched_text)
      temporary.flush
      temporary.fsync
      load_yaml(File.read(temporary.path, encoding: "UTF-8"), temporary.path)
      unless validator.nil? || validator.call(temporary.path)
        return base_result(config, :validation_failed).merge(path: path)
      end

      backup_once(path, backup_root) if backup_root
      File.chmod(mode, temporary.path)
      File.rename(temporary.path, write_path)
    end
    result.merge(path: path)
  rescue Psych::Exception, JSON::ParserError
    base_result(nil, :invalid).merge(path: path)
  rescue SystemCallError, IOError
    base_result(nil, :io_error).merge(path: path)
  rescue StandardError
    base_result(nil, :error).merge(path: path)
  end

  def defaults_read(key)
    %w[com.metacubex.ClashX.meta com.MetaCubeX.ClashX.meta].each do |domain|
      value = IO.popen(["/usr/bin/defaults", "read", domain, key], err: File::NULL, &:read).strip
      return value unless value.empty?
    rescue StandardError
      next
    end
    ""
  end

  def selected_profile_name
    defaults_read("selectConfigName")
  end

  def icloud_enabled?
    %w[1 true yes].include?(defaults_read("kUserEnableiCloud").downcase)
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

  def default_profile_directories(home: Dir.home, app_paths: clashx_app_paths)
    local = File.join(home, ".config", "clash.meta")
    clouds = icloud_container_roots(home: home, app_paths: app_paths).map { |root| File.join(root, "Documents") }
    ([local] + clouds).select { |path| Dir.exist?(path) }.uniq
  end

  def default_watch_paths(home: Dir.home, app_paths: clashx_app_paths)
    local = File.join(home, ".config", "clash.meta")
    roots = icloud_container_roots(home: home, app_paths: app_paths).select { |path| Dir.exist?(path) }
    cloud_paths = roots.flat_map { |root| [root, File.join(root, "Documents")] }
    ([local] + cloud_paths).select { |path| Dir.exist?(path) }.uniq
  end

  def active_profile?(path, selected)
    selected_name = File.basename(selected.to_s)
    selected_stem = selected_name.sub(/\.ya?ml\z/i, "")
    profile_name = File.basename(path)
    profile_stem = profile_name.sub(/\.ya?ml\z/i, "")
    profile_name.casecmp(selected_name).zero? || profile_stem.casecmp(selected_stem).zero?
  end

  def controller_socket
    cache_directories = [
      File.expand_path("~/Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs"),
      File.expand_path("~/Library/Caches/com.metacubex.ClashX.meta/cacheConfigs")
    ]
    cache_directories.each do |directory|
      Dir.glob(File.join(directory, "*.yaml")).sort_by { |path| File.mtime(path) }.reverse_each do |path|
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

  def reload(path, socket: nil, requester: nil)
    socket ||= controller_socket
    return false unless socket

    request = requester || ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    status, = request.call("PUT", "/configs?force=true", JSON.generate("path" => path))
    status == 204
  end

  def tun_state(socket: nil, requester: nil)
    socket ||= controller_socket
    return :unknown unless socket

    request = requester || ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
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

  def select_proxy(group, candidate, socket: nil, requester: nil)
    socket ||= controller_socket
    return false unless socket

    encoded = URI.encode_www_form_component(group).gsub("+", "%20")
    request = requester || ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    put_status, = request.call("PUT", "/proxies/#{encoded}", JSON.generate("name" => candidate))
    return false unless put_status == 204

    get_status, body = request.call("GET", "/proxies/#{encoded}", nil)
    get_status == 200 && JSON.parse(body)["now"] == candidate
  rescue JSON::ParserError
    false
  end

  def run(directory: nil, directories: nil, policy_path:, dry_run: false, backup_root: nil, reloader: nil,
          selector: nil, selected_name: nil, active_directory: nil, validator: nil)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    reloader ||= method(:reload)
    selector ||= method(:select_proxy)
    selected = selected_name.nil? ? selected_profile_name : selected_name
    roots = directories || (directory ? [directory] : default_profile_directories)
    active_root = active_directory
    if active_root.nil?
      active_root = directory if directory
      active_root ||= if icloud_enabled?
                        roots.find { |path| path.include?("/Library/Mobile Documents/") }
                      else
                        roots.find { |path| path.end_with?("/.config/clash.meta") }
                      end
    end

    results = roots.flat_map do |root|
      profile_paths(root).map do |path|
        result = patch_path(path, policy, dry_run: dry_run, backup_root: backup_root, validator: validator)
        result[:active] = active_root && File.expand_path(File.dirname(path)) == File.expand_path(active_root) && active_profile?(path, selected)
        result
      end
    end

    active = results.find { |result| result[:active] && %i[updated unchanged].include?(result[:status]) }
    if active && !dry_run
      active[:reloaded] = reloader.call(active[:path]) if active[:changed]
      runtime_ready = !active[:changed] || active[:reloaded]
      if runtime_ready && active[:selected_home]
        active[:selection_verified] = selector.call(active[:ai_group], active[:selected_home])
      end
    end
    results
  end

  def chinese_status(result)
    name = File.basename(result[:path].to_s)
    case result[:status]
    when :updated
      "#{name}：#{updated_state(result)}#{ai_state(result)}"
    when :unchanged
      suffix = result[:selection_verified] ? "；AI 节点已确认" : ""
      "#{name}：无需修改#{suffix}"
    when :no_main_group then "#{name}：未修改：找不到可用的主代理组"
    when :validation_failed then "#{name}：已跳过：内核校验失败"
    when :io_error then "#{name}：已跳过：读取或写入失败"
    when :error then "#{name}：已跳过：处理失败"
    else "#{name}：已跳过：订阅内容无效"
    end
  end

  def ai_state(result)
    return "；没有台湾或日本家宽节点，未替你更换节点" unless result[:selected_home]
    return "；AI 将使用「#{result[:selected_home]}」" unless result[:active]
    return "；AI 已切换到「#{result[:selected_home]}」" if result[:selection_verified]

    "；AI 组已写入「#{result[:selected_home]}」，等待运行配置生效"
  end

  def updated_state(result)
    return "将更新（演练，未写入文件）" if result[:dry_run]
    return "已更新，选择该订阅时生效" unless result[:active]

    result[:reloaded] ? "已更新并生效" : "已更新，等待重新加载"
  end

  def cli(argv = ARGV)
    options = {
      profile_dirs: [],
      policy: File.expand_path("../../../references/policy.json", __dir__),
      backup_root: File.expand_path("~/Library/Application Support/ClashPatch/backups"),
      dry_run: false,
      print_watch_paths: false,
      print_tun_state: false
    }
    parser = OptionParser.new do |opts|
      opts.banner = "用法：patch_profiles.rb [选项]"
      opts.on("--profile-dir PATH", "添加一个订阅目录，可重复使用") { |value| options[:profile_dirs] << File.expand_path(value) }
      opts.on("--policy PATH", "指定策略文件") { |value| options[:policy] = File.expand_path(value) }
      opts.on("--backup-dir PATH", "指定备份目录") { |value| options[:backup_root] = File.expand_path(value) }
      opts.on("--dry-run", "只预览，不写入文件") { options[:dry_run] = true }
      opts.on("--print-watch-paths", "输出 LaunchAgent 应监视的目录") { options[:print_watch_paths] = true }
      opts.on("--print-tun-state", "输出当前运行内核的 TUN 状态") { options[:print_tun_state] = true }
      opts.on("-h", "--help", "显示帮助") do
        puts opts
        return 0
      end
    end
    parser.parse!(argv)

    if options[:print_tun_state]
      puts tun_state
      return 0
    end

    if options[:print_watch_paths]
      default_watch_paths.each { |path| puts path }
      return 0
    end

    directories = options[:profile_dirs].empty? ? default_profile_directories : options[:profile_dirs]
    if directories.empty?
      warn "没有找到 ClashX Meta 配置目录。"
      return 2
    end

    results = run(
      directories: directories,
      policy_path: options[:policy],
      dry_run: options[:dry_run],
      backup_root: options[:backup_root],
      validator: options[:dry_run] ? nil : method(:validate_with_mihomo)
    )
    results.each { |result| puts chinese_status(result) }
    0
  rescue OptionParser::ParseError => error
    warn "参数错误：#{error.message}"
    warn parser
    64
  rescue StandardError => error
    warn "Clash 补丁运行失败：#{error.class}"
    1
  end
end

exit ClashPatch.cli if $PROGRAM_NAME == __FILE__
