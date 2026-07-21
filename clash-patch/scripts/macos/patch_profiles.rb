#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "psych"
require "tempfile"

module ClashPatch
  module_function

  AI_GROUP_BASE = "🤖 AI · Clash Patch".freeze
  SAFE_GROUP_BASE = "🛡 安全代理 · Clash Patch".freeze
  MIN_MIHOMO_VERSION = [1, 19, 27].freeze
  VALIDATION_TIMEOUT_SECONDS = 30
  MAX_PATCH_ATTEMPTS = 3
  POLICY_VERSION = 1
  AUTO_CORE = Object.new.freeze
  DIRECT_TYPES = %w[direct dns reject pass compatible rematch].freeze
  DIRECT_NAMES = %w[DIRECT REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH].freeze
  EXCLUDED_SAFE_TYPES = "Direct|Dns|Reject|Pass|Compatible|Rematch".freeze

  class InvalidConfigError < StandardError; end

  TUN_POLICY = {
    "enable" => true,
    "stack" => "system",
    "dns-hijack" => ["any:53", "tcp://any:53"],
    "auto-route" => true,
    "auto-detect-interface" => true,
    "strict-route" => true
  }.freeze

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
      route_group: nil,
      main_group: nil,
      ai_group_created: false,
      ai_group_reset: false
    }
  end

  def usable_config?(config)
    return false unless config.is_a?(Hash)
    return false unless config["proxy-groups"].is_a?(Array)
    return false if config.key?("rules") && !config["rules"].is_a?(Array)

    config["proxies"].is_a?(Array) || config["proxy-providers"].is_a?(Hash)
  end

  def selectable_groups(config)
    Array(config["proxy-groups"]).select do |group|
      group.is_a?(Hash) && group["name"].is_a?(String) && group["type"].to_s.downcase == "select"
    end
  end

  def managed_name?(name, base)
    name.is_a?(String) && name.match?(/\A#{Regexp.escape(base)}(?: (?:[2-9]|[1-9][0-9]+))?\z/)
  end

  def managed_group_name?(name)
    managed_name?(name, AI_GROUP_BASE) || managed_name?(name, SAFE_GROUP_BASE)
  end

  def detect_main_group(config, policy)
    candidates = selectable_groups(config).reject do |group|
      ai_name?(group["name"], policy) || managed_group_name?(group["name"])
    end
    names = candidates.map { |group| group["name"] }

    match = Array(config["rules"]).reverse.map { |rule| rule_info(rule) }.find { |info| info[:type] == "MATCH" }
    match_target = match && match[:target]
    return match_target if !direct_name?(match_target) && names.include?(match_target)

    references = Hash.new(0)
    Array(config["rules"]).each do |rule|
      next unless broad_rule?(rule)

      target = rule_info(rule)[:target]
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

  def existing_ai_group(config, policy)
    candidates = selectable_groups(config).select { |group| ai_name?(group["name"], policy) }
    candidates.find { |group| !managed_group_name?(group["name"]) } || candidates.first
  end

  def unique_group_name(config, base)
    names = Array(config["proxy-groups"]).map { |group| group["name"] if group.is_a?(Hash) }.compact
    names.concat(Array(config["proxies"]).map { |proxy| proxy["name"] if proxy.is_a?(Hash) }.compact)
    return base unless names.include?(base)

    suffix = 2
    suffix += 1 while names.include?("#{base} #{suffix}")
    "#{base} #{suffix}"
  end

  def managed_ai_group_fingerprint?(group)
    return false unless group.is_a?(Hash) && group.keys.sort == %w[name proxies type]
    return false unless group["type"].to_s.downcase == "select"

    proxies = group["proxies"]
    proxies.is_a?(Array) && proxies.length == 1 && proxies.first.is_a?(String) && proxies.first != group["name"]
  end

  def managed_safe_group_fingerprint?(group)
    expected_keys = %w[empty-fallback exclude-type include-all name proxies type]
    legacy_exclusions = [EXCLUDED_SAFE_TYPES, "Direct|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible"]
    return false unless group.is_a?(Hash) && group.keys.sort == expected_keys.sort
    return false unless group["type"].to_s.downcase == "select" && group["include-all"] == true
    return false unless group["empty-fallback"].to_s.casecmp("REJECT").zero?
    return false unless legacy_exclusions.include?(group["exclude-type"])

    proxies = group["proxies"]
    proxies.is_a?(Array) && proxies.all? { |name| name.is_a?(String) && name != group["name"] }
  end

  def owned_ai_group?(config, name, policy)
    group = selectable_groups(config).find { |item| item["name"] == name }
    return false unless managed_ai_group_fingerprint?(group)

    templates = Array(policy["ai_rules"]) + Array(policy["legacy_ai_rules"])
    keys = templates.map { |template| managed_rule_key(template) }.compact.uniq
    matches = Array(config["rules"]).count do |rule|
      info = rule_info(rule)
      info[:target] == name && keys.include?(managed_rule_key(rule))
    end
    matches >= 2
  end

  def resolver_targets(config)
    dns = config["dns"]
    return [] unless dns.is_a?(Hash)

    fields = %w[nameserver fallback direct-nameserver]
    endpoints = fields.flat_map { |field| Array(dns[field]) }
    if dns["nameserver-policy"].is_a?(Hash)
      endpoints.concat(dns["nameserver-policy"].values.flat_map { |value| Array(value) })
    end
    endpoints.map { |endpoint| resolver_target(endpoint) }.compact
  end

  def owned_safe_group?(config, name)
    group = selectable_groups(config).find { |item| item["name"] == name }
    return false unless managed_safe_group_fingerprint?(group)

    guarded = Array(config["rules"]).each_cons(2).any? do |first, second|
      first_info = rule_info(first)
      second_info = rule_info(second)
      first_info[:type] == "NETWORK" && first_info[:payload].casecmp("UDP").zero? && first_info[:target] == name &&
        second_info[:type] == "NETWORK" && second_info[:payload].casecmp("UDP").zero? &&
        second_info[:target].to_s.casecmp("REJECT").zero?
    end
    guarded && resolver_targets(config).include?(name)
  end

  def find_managed_select_group(config, base, kind, policy = nil)
    selectable_groups(config).find do |group|
      next false unless managed_name?(group["name"], base)

      kind == :ai ? owned_ai_group?(config, group["name"], policy) : owned_safe_group?(config, group["name"])
    end
  end

  def ensure_ai_group(config, main_group, candidate, policy)
    group = find_managed_select_group(config, AI_GROUP_BASE, :ai, policy)
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

  def owned_managed_group_names(config, policy)
    ai_names = selectable_groups(config).map { |group| group["name"] }.select do |name|
      managed_name?(name, AI_GROUP_BASE) && owned_ai_group?(config, name, policy)
    end
    safe_names = selectable_groups(config).map { |group| group["name"] }.select do |name|
      managed_name?(name, SAFE_GROUP_BASE) && owned_safe_group?(config, name)
    end
    [ai_names, safe_names]
  end

  def remove_owned_managed_groups(config, names)
    owned = names.each_with_object({}) { |name, memo| memo[name] = true }
    config["proxy-groups"] = Array(config["proxy-groups"]).reject do |group|
      group.is_a?(Hash) && owned[group["name"]]
    end
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

  def legacy_ai_dns_patterns(policy)
    Array(policy["legacy_ai_rules"]).each_with_object([]) do |template, patterns|
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

    return false unless Array(group["use"]).empty?
    return false if group["include-all"] == true || group["include-all-proxies"] == true || group["include-all-providers"] == true

    members = Array(group["proxies"])
    exclusion = group["exclude-filter"].to_s
    unless exclusion.empty?
      # Mihomo applies exclude-filter to explicit members too. Accept only the
      # common RE2-compatible subset so a runtime regex cannot remove every
      # safe member while our check still sees one.
      return false if exclusion.match?(/\(\?(?!i\))/) || exclusion.match?(/\\[1-9]/)

      begin
        matcher = Regexp.new(exclusion)
      rescue RegexpError
        return false
      end
      members = members.reject { |member| matcher.match?(member.to_s) }
    end

    if members.empty?
      # Mihomo defaults an empty group to COMPATIBLE. Only an explicitly named
      # safe inline proxy is acceptable here; proxy groups are not allowed by
      # Mihomo's empty-fallback field.
      return safe_proxy_target?(config, group["empty-fallback"])
    end

    members.all? do |member|
      safe_proxy_target?(config, member) || group_cannot_reach_direct?(config, member, visiting + [target])
    end
  end

  def resolver_target(endpoint)
    fragment = endpoint.to_s.split("#", 2)[1]
    return nil if fragment.nil? || fragment.empty?

    target = fragment.split("&", 2).first.to_s
    return nil if target.empty? || target.include?("=")

    target
  end

  def safe_resolver_endpoint?(config, endpoint)
    return false unless endpoint.to_s.match?(/\A(?:https|tls|quic):\/\//i)

    options = endpoint.to_s.split("#", 2)[1].to_s.split("&").drop(1)
    options.each do |option|
      key, value = option.split("=", 2)
      normalized = key.to_s.downcase
      return false if %w[ecs ecs-override].include?(normalized)
      return false if normalized == "skip-cert-verify" && value.to_s.casecmp("true").zero?
    end

    target = resolver_target(endpoint)
    return false if target.nil? || direct_name?(target)

    safe_proxy_target?(config, target) || group_cannot_reach_direct?(config, target)
  end

  def patch_dns(config, policy, route_group, owned_safe_names = [])
    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["ipv6"] = false
    dns["respect-rules"] = true
    dns["use-hosts"] = true
    dns["use-system-hosts"] = true

    safe_resolvers = tagged_resolvers(policy, route_group)
    fallback_bootstrap = deep_copy(policy["bootstrap_fallback_resolvers"])
    legacy_default = ["1.1.1.1", "8.8.8.8"]
    legacy_proxy = [
      ["1.1.1.1", "8.8.8.8"],
      ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
    ]
    current_proxy = Array(dns["proxy-server-nameserver"])
    if current_proxy.empty? || legacy_proxy.include?(current_proxy)
      dns["proxy-server-nameserver"] = fallback_bootstrap
    end
    if Array(dns["default-nameserver"]) == legacy_default
      dns["default-nameserver"] = deep_copy(fallback_bootstrap)
    end
    dns["nameserver"] = deep_copy(safe_resolvers)
    dns["fallback"] = deep_copy(safe_resolvers) if dns.key?("fallback")

    existing = dns["nameserver-policy"].is_a?(Hash) ? dns["nameserver-policy"] : {}
    policies = {}
    legacy_patterns = legacy_ai_dns_patterns(policy)
    existing.each do |combined, endpoints|
      combined.to_s.split(",").map(&:strip).reject(&:empty?).each do |pattern|
        values = Array(endpoints).map(&:to_s)
        legacy_owned = legacy_patterns.include?(pattern) && !values.empty? &&
                       values.all? { |value| owned_safe_names.include?(resolver_target(value)) }
        next if legacy_owned

        references_old_group = values.any? { |value| owned_safe_names.include?(resolver_target(value)) }
        policies[pattern] = !references_old_group && !values.empty? && values.all? { |value| safe_resolver_endpoint?(config, value) } ? values : deep_copy(safe_resolvers)
      end
    end
    ai_dns_patterns(policy).each { |pattern| policies[pattern] = deep_copy(safe_resolvers) }
    dns["nameserver-policy"] = policies
  end

  def split_rule_fields(rule)
    fields = []
    buffer = +""
    depth = 0
    rule.to_s.each_char do |character|
      case character
      when "("
        depth += 1
        buffer << character
      when ")"
        depth -= 1 if depth.positive?
        buffer << character
      when ","
        if depth.zero?
          fields << buffer.strip
          buffer = +""
        else
          buffer << character
        end
      else
        buffer << character
      end
    end
    fields << buffer.strip
    fields
  end

  def rule_info(rule)
    parts = split_rule_fields(rule)
    type = parts[0].to_s.upcase
    no_resolve = parts.last.to_s.casecmp("no-resolve").zero?
    target_index = no_resolve ? parts.length - 2 : parts.length - 1
    target = target_index.positive? ? parts[target_index] : nil
    { parts: parts, type: type, payload: parts[1].to_s, target: target }
  end

  def managed_rule_key(rule)
    info = rule_info(rule)
    return nil if info[:type].empty? || info[:payload].empty?

    [info[:type], info[:payload].downcase]
  end

  def managed_rule_identity(rule)
    info = rule_info(rule)
    key = managed_rule_key(rule)
    key && info[:target] ? key + [info[:target]] : nil
  end

  def render_ai_rules(policy, ai_group)
    Array(policy["ai_rules"]).map { |template| template.sub("{AI}") { ai_group } }
  end

  def broad_rule?(rule)
    %w[MATCH GEOSITE GEOIP RULE-SET].include?(rule_info(rule)[:type])
  end

  def patch_rules(config, policy, ai_group, route_group, owned_ai_names = [], owned_safe_names = [])
    managed = render_ai_rules(policy, ai_group)
    managed_keys = managed.map { |rule| managed_rule_key(rule) }.compact
    managed_identities = managed.map { |rule| managed_rule_identity(rule) }.compact
    legacy_keys = Array(policy["legacy_ai_rules"]).map { |rule| managed_rule_key(rule) }.compact
    forbidden = Array(policy["forbidden_ai_domains"])

    original_rules = Array(config["rules"])
    owned_udp_indexes = []
    original_rules.each_with_index do |rule, index|
      info = rule_info(rule)
      next unless info[:type] == "NETWORK" && info[:payload].casecmp("UDP").zero? &&
                  (owned_safe_names.include?(info[:target]) || info[:target] == route_group)

      owned_udp_indexes << index
      next_info = rule_info(original_rules[index + 1]) if index + 1 < original_rules.length
      if next_info && next_info[:type] == "NETWORK" && next_info[:payload].casecmp("UDP").zero? &&
         next_info[:target].to_s.casecmp("REJECT").zero?
        owned_udp_indexes << index + 1
      end
    end

    user_overrides = []
    remaining = []
    original_rules.each_with_index do |rule, index|
      next if owned_udp_indexes.include?(index)

      info = rule_info(rule)
      key = managed_rule_key(rule)
      patch_owned_ai = owned_ai_names.include?(info[:target]) && managed_keys.include?(key)
      exact_current_ai = managed_identities.include?(managed_rule_identity(rule))
      legacy_owned_ai = legacy_keys.include?(key) && owned_ai_names.include?(info[:target])
      forbidden_ai = %w[DOMAIN DOMAIN-SUFFIX].include?(info[:type]) &&
                     forbidden.any? { |domain| domain.casecmp(info[:payload]).zero? } &&
                     owned_ai_names.include?(info[:target])
      next if patch_owned_ai || exact_current_ai || legacy_owned_ai || forbidden_ai

      if managed_keys.include?(key)
        user_overrides << rule
      else
        remaining << rule
      end
    end

    config["rules"] = ["NETWORK,UDP,#{route_group}", "NETWORK,UDP,REJECT"] + user_overrides + managed + remaining
  end

  def normalize_reality_short_ids(value)
    stack = [value]
    until stack.empty?
      current = stack.pop
      case current
      when Hash
        current.each do |key, child|
          if key.to_s == "short-id" && child.is_a?(String) && child.match?(/\A[0-9a-fA-F]{1,16}\z/)
            current[key] = child.dup
          else
            stack << child
          end
        end
      when Array
        stack.concat(current)
      end
    end
    value
  end

  def patch(config, policy)
    return base_result(config, :invalid_policy) unless policy.is_a?(Hash) && policy["version"] == POLICY_VERSION
    return base_result(config, :invalid) unless usable_config?(config)

    original = deep_copy(config)
    patched = deep_copy(config)
    patched["rules"] ||= []
    main_group = detect_main_group(patched, policy)
    return base_result(config, :no_main_group) unless main_group

    owned_ai_names, owned_safe_names = owned_managed_group_names(patched, policy)
    existing_ai = existing_ai_group(patched, policy)
    ai_group_created = existing_ai.nil?
    ai_group_reset = existing_ai && owned_ai_names.include?(existing_ai["name"])
    ai_group = if existing_ai
                 if ai_group_reset
                   existing_ai.keys.each { |key| existing_ai.delete(key) unless %w[name type].include?(key) }
                   existing_ai["type"] = "select"
                   existing_ai["proxies"] = [main_group]
                 end
                 existing_ai["name"]
               else
                 ensure_ai_group(patched, main_group, nil, policy)
               end
    route_group = main_group
    patched["ipv6"] = false
    patched["tun"] = {} unless patched["tun"].is_a?(Hash)
    TUN_POLICY.each { |key, value| patched["tun"][key] = deep_copy(value) }
    patch_dns(patched, policy, route_group, owned_safe_names)
    patch_rules(patched, policy, ai_group, route_group, owned_ai_names, owned_safe_names)
    remove_owned_managed_groups(patched, (owned_ai_names - [ai_group]) + owned_safe_names)
    normalize_reality_short_ids(patched)

    {
      config: patched,
      changed: patched != original,
      status: patched == original ? :unchanged : :updated,
      ai_group: ai_group,
      route_group: route_group,
      main_group: main_group,
      ai_group_created: ai_group_created,
      ai_group_reset: !!ai_group_reset
    }
  end

  def dump_config(config)
    visitor = Psych::Visitors::YAMLTree.create({})
    visitor << config
    tag_reality_short_ids(visitor.tree).yaml
  end

  def tag_reality_short_ids(node)
    stack = [node]
    until stack.empty?
      current = stack.pop
      case current
      when Psych::Nodes::Mapping
        current.children.each_slice(2) do |key, value|
          if key.is_a?(Psych::Nodes::Scalar) && key.value == "short-id" &&
             value.is_a?(Psych::Nodes::Scalar) && value.value.match?(/\A[0-9a-fA-F]{1,16}\z/)
            value.tag = "tag:yaml.org,2002:str"
            value.plain = false
            value.quoted = true
            value.style = Psych::Nodes::Scalar::DOUBLE_QUOTED
          end
          stack << value
        end
      when Psych::Nodes::Document, Psych::Nodes::Sequence, Psych::Nodes::Stream
        stack.concat(current.children)
      end
    end
    node
  end

  def yaml_alias?(node)
    stack = [node]
    until stack.empty?
      current = stack.pop
      return true if current.is_a?(Psych::Nodes::Alias)

      stack.concat(Array(current.children)) if current.respond_to?(:children)
    end
    false
  end

  def load_yaml(text, filename = nil)
    # REALITY short-id is schema-defined text, but a valid hexadecimal value
    # can also resemble a YAML number (for example 0906152e4 or 12345678).
    # Tag only that field as text before scalar resolution so unrelated YAML
    # 1.2 exponent values keep their numeric meaning.
    stream = Psych.parse_stream(text, filename: filename)
    documents = stream.children
    return nil if documents.empty?
    raise InvalidConfigError, "YAML 必须只包含一个文档" unless documents.length == 1

    document = documents.first
    raise InvalidConfigError, "YAML 别名不受支持" if yaml_alias?(document)

    tag_reality_short_ids(document)

    class_loader = Psych::ClassLoader::Restricted.new([], [])
    scanner = YAML12ScalarScanner.new(class_loader)
    Psych::Visitors::ToRuby.new(scanner, class_loader).accept(document)
  end

  def excluded_path?(path)
    basename = File.basename(path)
    basename.start_with?(".") || basename.match?(/(?:^|[._-])(?:bak|backup|clash-patch)(?:[._-]|\z)/i) ||
      basename.match?(/(?:\.tmp|\.bak|\.backup)\z/i)
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

  def backup_once(path, backup_root, content: nil)
    FileUtils.mkdir_p(backup_root)
    FileUtils.chmod(0o700, backup_root)
    key = Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
    destination = File.join(backup_root, "#{key}-#{File.basename(path)}.backup")
    begin
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |backup|
        if content
          backup.write(content)
        else
          File.open(path, "rb") { |source| IO.copy_stream(source, backup) }
        end
        backup.flush
        backup.fsync
      end
    rescue Errno::EEXIST
      # The first complete patch attempt owns the one-time backup.
    end
    FileUtils.chmod(0o600, destination)
  end

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

  def locked_source_current?(source, path, write_path)
    return false unless File.realpath(path) == write_path

    source_stat = source.stat
    path_stat = File.stat(write_path)
    source_stat.dev == path_stat.dev && source_stat.ino == path_stat.ino
  rescue SystemCallError, IOError
    false
  end

  def patch_path_once(path, policy, dry_run:, backup_root:, validator:)
    write_path = File.realpath(path)
    outcome = nil
    File.open(write_path, dry_run ? "rb" : "r+b") do |source|
      source.flock(File::LOCK_EX)
      original_bytes = source.read
      original_text = original_bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidConfigError, "配置不是有效的 UTF-8" unless original_text.valid_encoding?

      config = load_yaml(original_text, path)
      result = patch(config, policy)
      return result.merge(path: path) unless result[:changed]

      patched_text = dump_config(result[:config])
      candidate_config = load_yaml(patched_text, path)
      second_pass = patch(candidate_config, policy)
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
          backup_once(path, backup_root, content: original_bytes) if backup_root
          source.rewind
          if !locked_source_current?(source, path, write_path) || source.read != original_bytes
            outcome = :retry
          else
            # Write through the locked descriptor. If the subscription client
            # atomically replaces the path after our identity check, this
            # descriptor still names the old inode and cannot overwrite the
            # newly refreshed file. The post-write identity check then retries.
            patched_bytes = File.binread(temporary.path)
            source.rewind
            source.write(patched_bytes)
            source.truncate(patched_bytes.bytesize)
            source.flush
            source.fsync
            outcome = locked_source_current?(source, path, write_path) ? result.merge(path: path) : :retry
          end
        end
      end
    end
    outcome
  end

  def patch_path(path, policy, dry_run: false, backup_root: nil, validator: nil)
    MAX_PATCH_ATTEMPTS.times do
      outcome = patch_path_once(path, policy, dry_run: dry_run, backup_root: backup_root, validator: validator)
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
    storage_mode == :icloud
  end

  def storage_mode(value = defaults_read("kUserEnableiCloud"))
    normalized = value.to_s.strip.downcase
    return :icloud if %w[1 true yes].include?(normalized)
    return :local if %w[0 false no].include?(normalized)

    :unknown
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

  def run(directory: nil, directories: nil, policy_path:, dry_run: false, backup_root: nil,
          selected_name: nil, active_directory: nil, validator: nil)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    unless policy.is_a?(Hash) && policy["version"] == POLICY_VERSION
      raise InvalidConfigError, "不支持的策略版本"
    end
    selected = selected_name.nil? ? selected_profile_name : selected_name
    roots = directories || (directory ? [directory] : default_profile_directories)
    active_root = active_directory || active_profile_root(roots, selected, directory)

    results = roots.flat_map do |root|
      profile_paths(root).map do |path|
        result = patch_path(path, policy, dry_run: dry_run, backup_root: backup_root, validator: validator)
        result[:active] = active_root && File.expand_path(File.dirname(path)) == File.expand_path(active_root) && active_profile?(path, selected)
        result
      end
    end

    results
  end

  def chinese_status(result)
    name = safe_label(File.basename(result[:path].to_s))
    case result[:status]
    when :updated
      "#{name}：#{updated_state(result)}#{ai_state(result)}"
    when :unchanged then "#{name}：无需修改"
    when :no_main_group then "#{name}：未修改：找不到可用的主代理组"
    when :validation_failed then "#{name}：已跳过：内核校验失败"
    when :validation_timeout then "#{name}：已跳过：订阅响应超时"
    when :non_idempotent then "#{name}：已跳过：二次转换不一致"
    when :invalid_policy then "#{name}：已跳过：策略版本无效"
    when :concurrent_change then "#{name}：已跳过：订阅正在刷新，稍后重试"
    when :io_error then "#{name}：已跳过：读取或写入失败"
    when :error then "#{name}：已跳过：处理失败"
    else "#{name}：已跳过：订阅内容无效"
    end
  end

  def ai_state(result)
    ai_group = safe_label(result[:ai_group])
    return "；已创建 AI 分组「#{ai_group}」并跟随主代理组，节点由你选择" if result[:ai_group_created]
    return "；已保留 AI 分组「#{ai_group}」并改为跟随主代理组，节点由你选择" if result[:ai_group_reset]

    "；已复用 AI 分组「#{ai_group}」，只补全规则，节点未改"
  end

  def safe_label(value)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    text = text.gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
    text = text.gsub(/[\p{Cc}\p{Cf}]/, "")
    text = text.gsub(/\b(?:password|passwd|token|secret|uuid)\s*[=:]\s*\S+/i, "[已隐藏]")
    text = text.gsub(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, "[已隐藏]")
    text = text.gsub(%r{\b[A-Za-z][A-Za-z0-9+.-]*://\S+}, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^/\s]*}, "[路径已隐藏]")
    text = text.gsub(/\b[A-Za-z]:[\\\/](?:[^\\\/\s]+[\\\/])+[^\\\/\s]*/, "[路径已隐藏]")
    text = text.strip
    text = "未命名" if text.empty?
    text.each_char.take(120).join
  end

  def updated_state(result)
    return "将更新（演练，未写入文件）" if result[:dry_run]
    return "已更新，选择该订阅时生效" unless result[:active]

    "已更新，等待用户手动重新加载"
  end

  def cli(argv = ARGV)
    options = {
      profile_dirs: [],
      policy: File.expand_path("../../references/policy.json", __dir__),
      backup_root: File.expand_path("~/Library/Application Support/ClashPatch/backups"),
      dry_run: false,
      print_tun_state: false,
      print_core_status: false
    }
    parser = OptionParser.new do |opts|
      opts.banner = "用法：patch_profiles.rb [选项]"
      opts.on("--profile-dir PATH", "添加一个订阅目录，可重复使用") { |value| options[:profile_dirs] << File.expand_path(value) }
      opts.on("--policy PATH", "指定策略文件") { |value| options[:policy] = File.expand_path(value) }
      opts.on("--backup-dir PATH", "指定备份目录") { |value| options[:backup_root] = File.expand_path(value) }
      opts.on("--dry-run", "只预览，不写入文件") { options[:dry_run] = true }
      opts.on("--print-tun-state", "输出当前运行内核的 TUN 状态") { options[:print_tun_state] = true }
      opts.on("--print-core-status", "检查 Mihomo 内核是否满足最低版本") { options[:print_core_status] = true }
      opts.on("-h", "--help", "显示帮助") do
        puts opts
        return 0
      end
    end
    parser.parse!(argv)

    if options[:print_core_status]
      status = mihomo_core_status
      puts status
      return status == :supported ? 0 : 1
    end

    if options[:print_tun_state]
      puts tun_state
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
  rescue Errno::ENOENT
    warn "Clash 补丁运行失败：找不到所需文件。"
    1
  rescue JSON::ParserError
    warn "Clash 补丁运行失败：策略文件不是有效的 JSON。"
    1
  rescue InvalidConfigError => error
    warn "Clash 补丁运行失败：#{safe_label(error.message)}。"
    1
  rescue StandardError => error
    warn "Clash 补丁运行失败：#{safe_label(error.message)}（#{error.class}）"
    1
  end
end

exit ClashPatch.cli if $PROGRAM_NAME == __FILE__
