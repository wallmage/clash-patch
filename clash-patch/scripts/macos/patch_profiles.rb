#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "base64"
require "open3"
require "optparse"
require "psych"
require "tempfile"
require "time"

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
  LEGACY_QUIC_REJECT_RULE = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT".freeze

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
    return false unless group.is_a?(Hash)
    return false unless (group.keys - %w[name proxies type use]).empty?
    return false unless %w[name proxies type].all? { |key| group.key?(key) }
    return false unless group["type"].to_s.downcase == "select"

    proxies = group["proxies"]
    providers = group.key?("use") ? group["use"] : []
    return false unless proxies.is_a?(Array) && providers.is_a?(Array)
    return false if proxies.empty? && providers.empty?

    proxies.all? { |name| name.is_a?(String) && name != group["name"] } &&
      providers.all? { |name| name.is_a?(String) && !name.empty? }
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

  def ai_group_sources(config)
    proxies = Array(config["proxies"]).each_with_object([]) do |proxy, names|
      next unless proxy.is_a?(Hash) && proxy["name"].is_a?(String)
      next if proxy["name"].empty? || direct_name?(proxy["name"])
      next if DIRECT_TYPES.include?(proxy["type"].to_s.downcase)

      names << proxy["name"] unless names.include?(proxy["name"])
    end.uniq
    providers = if config["proxy-providers"].is_a?(Hash)
                  config["proxy-providers"].each_with_object([]) do |(name, provider), names|
                    names << name if name.is_a?(String) && !name.empty? && provider.is_a?(Hash)
                  end
                else
                  []
                end
    [proxies, providers]
  end

  def configure_managed_ai_group(group, config)
    proxies, providers = ai_group_sources(config)
    return false if proxies.empty? && providers.empty?

    group.keys.each { |key| group.delete(key) unless %w[name type].include?(key) }
    group["type"] = "select"
    group["proxies"] = proxies
    group["use"] = providers unless providers.empty?
    true
  end

  def ensure_ai_group(config, policy)
    group = find_managed_select_group(config, AI_GROUP_BASE, :ai, policy)
    unless group
      group = { "name" => unique_group_name(config, AI_GROUP_BASE), "type" => "select" }
      config["proxy-groups"] << group
    end

    configure_managed_ai_group(group, config) ? group["name"] : nil
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

  def normalized_resolver_endpoints(config, policy, values)
    return nil unless values.all? { |value| safe_resolver_endpoint?(config, value) }

    values.flat_map do |value|
      fragment = value.to_s.split("#", 2)[1]
      Array(policy["resolvers"]).map { |resolver| "#{resolver}##{fragment}" }
    end.uniq
  end

  def patch_dns(config, policy, route_group, ai_group, owned_safe_names = [])
    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["ipv6"] = false
    dns["respect-rules"] = true
    dns["use-hosts"] = true
    dns["use-system-hosts"] = true

    safe_resolvers = tagged_resolvers(policy, route_group)
    ai_resolvers = tagged_resolvers(policy, ai_group)
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
    dns["direct-nameserver"] = deep_copy(policy["direct_resolvers"])
    dns["direct-nameserver-follow-policy"] = false

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
        normalized = !references_old_group && !values.empty? ? normalized_resolver_endpoints(config, policy, values) : nil
        policies[pattern] = normalized || deep_copy(safe_resolvers)
      end
    end
    policies["geosite:cn"] = deep_copy(policy["direct_resolvers"])
    ai_dns_patterns(policy).each { |pattern| policies[pattern] = deep_copy(ai_resolvers) }
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
      if rule.to_s.gsub(/\s+/, "").casecmp(LEGACY_QUIC_REJECT_RULE).zero?
        owned_udp_indexes << index
        next
      end

      info = rule_info(rule)
      next unless info[:type] == "NETWORK" && info[:payload].casecmp("UDP").zero? &&
                  (owned_safe_names.include?(info[:target]) || [route_group, ai_group].include?(info[:target]))

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
      main_group_ai = managed_keys.include?(key) && info[:target] == route_group
      next if patch_owned_ai || exact_current_ai || legacy_owned_ai || forbidden_ai || main_group_ai

      if managed_keys.include?(key)
        user_overrides << rule
      else
        remaining << rule
      end
    end

    config["rules"] = ["NETWORK,UDP,#{ai_group}", "NETWORK,UDP,REJECT"] + user_overrides + managed + remaining
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
                   return base_result(config, :no_ai_nodes) unless configure_managed_ai_group(existing_ai, patched)
                 end
                 existing_ai["name"]
               else
                 ensure_ai_group(patched, policy)
               end
    return base_result(config, :no_ai_nodes) unless ai_group
    route_group = main_group
    patched["ipv6"] = false
    patched["tun"] = {} unless patched["tun"].is_a?(Hash)
    TUN_POLICY.each { |key, value| patched["tun"][key] = deep_copy(value) }
    patch_dns(patched, policy, route_group, ai_group, owned_safe_names)
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

  def backup_key(path)
    Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
  end

  def secure_backup_root!(backup_root)
    root = File.expand_path(backup_root)
    raise InvalidConfigError, "备份目录不能是符号链接" if File.symlink?(root)
    raise InvalidConfigError, "备份位置不是目录" if File.exist?(root) && !File.directory?(root)

    FileUtils.mkdir_p(root, mode: 0o700)
    FileUtils.chmod(0o700, root)
    Dir.children(root).each do |name|
      path = File.join(root, name)
      next unless name.end_with?(".backup") && File.file?(path) && !File.symlink?(path)

      FileUtils.chmod(0o600, path)
    rescue SystemCallError
      next
    end
    root
  end

  def backup_entries_for(path, backup_root, reason: nil)
    root = File.expand_path(backup_root)
    return [] unless File.directory?(root) && !File.symlink?(root)

    key = backup_key(path)
    suffix = "--#{key}--#{File.basename(path)}.backup"
    reason_token = reason && "--#{reason}--#{key}--"
    Dir.children(root).select do |name|
      name.end_with?(suffix) && (!reason_token || name.include?(reason_token)) &&
        File.file?(File.join(root, name)) && !File.symlink?(File.join(root, name))
    end.sort.map { |name| File.join(root, name) }
  end

  def create_versioned_backup(path, backup_root, content: nil, reason: "prewrite")
    raise InvalidConfigError, "备份原因无效" unless reason.match?(/\A[a-z][a-z0-9-]{0,31}\z/)

    root = secure_backup_root!(backup_root)
    bytes = content.nil? ? File.binread(File.realpath(path)) : content.b
    key = backup_key(path)
    destination = nil
    100.times do
      timestamp = Time.now.strftime("%Y-%m-%d_%H-%M-%S.%9N%z")
      candidate = File.join(root, "#{timestamp}--#{reason}--#{key}--#{File.basename(path)}.backup")
      begin
        File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |backup|
          backup.write(bytes)
          backup.flush
          backup.fsync
        end
        destination = candidate
        break
      rescue Errno::EEXIST
        Thread.pass
      end
    end
    raise IOError, "无法创建唯一的版本化备份" unless destination

    FileUtils.chmod(0o600, destination)
    destination
  rescue StandardError
    FileUtils.rm_f(destination) if destination && File.exist?(destination)
    raise
  end

  def snapshot_initial_profiles(directories, backup_root)
    directories.each_with_object([]) do |directory, snapshots|
      profile_paths(directory).each do |path|
        if backup_entries_for(path, backup_root, reason: "initial").empty?
          snapshots << create_versioned_backup(path, backup_root, reason: "initial")
        end
      end
    end
  end

  def list_backups(backup_root)
    root = File.expand_path(backup_root)
    return [] unless File.directory?(root) && !File.symlink?(root)

    Dir.children(root).select do |name|
      path = File.join(root, name)
      name.match?(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4}--[a-z][a-z0-9-]{0,31}--[0-9a-f]{16}--.+\.backup\z/) &&
        !name.include?("--preference--") &&
        File.file?(path) && !File.symlink?(path)
    end.sort.reverse
  end

  def resolve_backup_id(backup_id, backup_root)
    raise InvalidConfigError, "备份编号无效" unless backup_id == File.basename(backup_id.to_s) && backup_id.end_with?(".backup")

    root = File.expand_path(backup_root)
    path = File.join(root, backup_id)
    raise InvalidConfigError, "找不到指定备份" unless File.file?(path) && !File.symlink?(path)

    path
  end

  def find_backup_target(backup_id, directories)
    matches = directories.flat_map { |directory| profile_paths(directory) }.select do |path|
      backup_id.include?("--#{backup_key(path)}--") && backup_id.end_with?("--#{File.basename(path)}.backup")
    end
    raise InvalidConfigError, "备份无法对应到当前存储位置中的唯一配置" unless matches.length == 1

    matches.first
  end

  def redacted_changed_paths(before, after, prefix = nil, output = [], limit = 200)
    return output if output.length >= limit || before == after

    if before.is_a?(Hash) && after.is_a?(Hash)
      (before.keys | after.keys).map(&:to_s).sort.each do |key|
        break if output.length >= limit
        path = prefix ? "#{prefix}.#{key}" : key
        before_key = before.key?(key) ? key : before.keys.find { |candidate| candidate.to_s == key }
        after_key = after.key?(key) ? key : after.keys.find { |candidate| candidate.to_s == key }
        if before_key.nil? || after_key.nil?
          output << path
        else
          redacted_changed_paths(before[before_key], after[after_key], path, output, limit)
        end
      end
    else
      output << (prefix || "配置")
    end
    output
  end

  def compare_backup(backup_id, directories:, backup_root:)
    backup_path = resolve_backup_id(backup_id, backup_root)
    target = find_backup_target(backup_id, directories)
    backup_bytes = File.binread(backup_path)
    current_bytes = File.binread(File.realpath(target))
    backup_config = load_yaml(backup_bytes.dup.force_encoding(Encoding::UTF_8), backup_id)
    current_config = load_yaml(current_bytes.dup.force_encoding(Encoding::UTF_8), target)
    {
      backup_id: backup_id,
      profile: File.basename(target),
      same: backup_bytes == current_bytes,
      backup_sha256: Digest::SHA256.hexdigest(backup_bytes),
      current_sha256: Digest::SHA256.hexdigest(current_bytes),
      changes: redacted_changed_paths(backup_config, current_config)
    }
  end

  def restore_backup(backup_id, directories:, backup_root:, expected_current_sha256:, validator:)
    return { status: :restore_conflict } unless expected_current_sha256.to_s.match?(/\A[0-9a-f]{64}\z/i)

    backup_path = resolve_backup_id(backup_id, backup_root)
    target = find_backup_target(backup_id, directories)
    write_path = File.realpath(target)
    backup_bytes = File.binread(backup_path)
    backup_text = backup_bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "备份不是有效的 UTF-8" unless backup_text.valid_encoding?

    load_yaml(backup_text, backup_id)
    Tempfile.create([File.basename(write_path), ".restore"], File.dirname(write_path)) do |temporary|
      temporary.binmode
      temporary.write(backup_bytes)
      temporary.flush
      temporary.fsync
      validation = validator.call(temporary.path)
      return { status: :validation_timeout, path: target } if validation == :timeout
      return { status: :validation_failed, path: target } unless validation == true
    end

    current_bytes = File.binread(write_path)
    return { status: :restore_conflict, path: target } unless Digest::SHA256.hexdigest(current_bytes).casecmp(expected_current_sha256).zero?
    return { status: :no_change, path: target } if current_bytes == backup_bytes

    create_versioned_backup(target, backup_root, content: current_bytes, reason: "pre-restore")
    File.open(write_path, "r+b") do |source|
      source.flock(File::LOCK_EX)
      locked_bytes = source.read
      unless locked_source_current?(source, target, write_path) &&
             Digest::SHA256.hexdigest(locked_bytes).casecmp(expected_current_sha256).zero?
        return { status: :restore_conflict, path: target }
      end
      source.rewind
      source.write(backup_bytes)
      source.truncate(backup_bytes.bytesize)
      source.flush
      source.fsync
    end
    {
      status: :updated,
      path: target,
      rollback_bytes: current_bytes,
      patched_digest: Digest::SHA256.hexdigest(backup_bytes),
      restored_backup: backup_id
    }
  rescue Psych::Exception, InvalidConfigError, SystemStackError
    { status: :invalid_backup }
  rescue SystemCallError, IOError
    { status: :io_error }
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
            source.rewind
            source.write(patched_bytes)
            source.truncate(patched_bytes.bytesize)
            source.flush
            source.fsync
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
      runner.call("/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "true")
      raise IOError, "无法关闭 ClashX Meta 订阅自动更新：#{error.to_s.strip}"
    end

    verified_export = defaults_export_domain(runner: runner)
    verified_value = if verified_export && verified_export.fetch(:domain) == domain
                       plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
                     else
                       ""
                     end
    unless subscription_auto_update_state(verified_value) == :disabled
      runner.call("/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "true")
      raise IOError, "ClashX Meta 订阅自动更新设置回读失败，已经恢复原值"
    end

    { status: :disabled, domain: domain, backup: created_backup }
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
    candidate = config
    if usage_profile == 3
      patched = patch(config, policy)
      raise InvalidConfigError, "远程订阅无法应用档位 3 补丁" unless %i[updated unchanged].include?(patched.fetch(:status))
      candidate = patched.fetch(:config)
    end
    output = dump_config(candidate).b
    reparsed = load_yaml(output.dup.force_encoding(Encoding::UTF_8), target.fetch(:name))
    if usage_profile == 3
      second = patch(reparsed, policy)
      raise InvalidConfigError, "远程订阅二次转换不一致" if second.fetch(:changed) || dump_config(second.fetch(:config)).b != output
    end

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
      source.rewind
      source.write(bytes)
      source.truncate(bytes.bytesize)
      source.flush
      source.fsync
    end
  end

  def default_safe_update_activation(items, usage_profile, selected_name = selected_profile_name)
    active = items.find { |item| active_profile?(item.fetch(:path), selected_name) }
    return true unless active

    result = {
      path: active.fetch(:path), status: :updated, active: true,
      rollback_bytes: active.fetch(:original), patched_digest: Digest::SHA256.hexdigest(active.fetch(:candidate))
    }
    activate_updated_profile(result, require_tun: usage_profile >= 2).fetch(:reloaded, false)
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

    handles = []
    begin
      items.sort_by { |item| File.expand_path(item.fetch(:path)) }.each do |item|
        handle = File.open(File.realpath(item.fetch(:path)), "r+b")
        handle.flock(File::LOCK_EX)
        handles << [item, handle]
      end
      unless handles.all? { |item, handle| handle.rewind && handle.read == item.fetch(:original) }
        return { status: :aborted, failed_profile: "", reason: :concurrent_change }
      end

      handles.each do |item, _handle|
        create_versioned_backup(item.fetch(:path), backup_root, content: item.fetch(:original), reason: "pre-update")
      end
      handles.each do |item, handle|
        handle.rewind
        handle.write(item.fetch(:candidate))
        handle.truncate(item.fetch(:candidate).bytesize)
        handle.flush
        handle.fsync
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
        return { status: :rollback_failed, failed_profile: rollback_failures.first, reason: :write_failed }
      end
      return { status: :aborted, failed_profile: "", reason: :write_failed }
    ensure
      handles.each { |_item, handle| handle.close rescue nil }
    end

    activation ||= ->(updated_items) { default_safe_update_activation(updated_items, usage_profile, selected_name) }
    activated = begin
      activation.call(items)
    rescue StandardError
      false
    end
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

    healthy = !require_tun || tun_state(requester: requester) == :enabled
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

  def run(directory: nil, directories: nil, policy_path:, dry_run: false, backup_root: nil,
          selected_name: nil, active_directory: nil, validator: nil, auto_reload: false,
          socket: nil, requester: nil, connectivity_checker: nil)
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
        result = patch_path(path, policy, dry_run: dry_run, backup_root: backup_root, validator: validator)
        result[:active] = active_root && File.expand_path(File.dirname(path)) == File.expand_path(active_root) && active_profile?(path, selected)
        if auto_reload && !dry_run && result[:active] && result[:status] == :updated
          result = activate_updated_profile(
            result,
            socket: socket,
            requester: requester,
            connectivity_checker: connectivity_checker
          )
        end
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
    when :no_ai_nodes then "#{name}：未修改：找不到可用的 AI 节点"
    when :validation_failed then "#{name}：已跳过：内核校验失败"
    when :validation_timeout then "#{name}：已跳过：订阅响应超时"
    when :non_idempotent then "#{name}：已跳过：二次转换不一致"
    when :invalid_policy then "#{name}：已跳过：策略版本无效"
    when :concurrent_change then "#{name}：已跳过：订阅正在刷新，稍后重试"
    when :io_error then "#{name}：已跳过：读取或写入失败"
    when :reload_failed_rolled_back then "#{name}：自动刷新失败，已恢复原配置"
    when :reload_failed_restore_pending then "#{name}：自动刷新失败；文件已恢复，运行内核恢复失败"
    when :reload_failed_rollback_conflict then "#{name}：自动刷新失败；订阅同时发生变化，未覆盖新内容"
    when :error then "#{name}：已跳过：处理失败"
    else "#{name}：已跳过：订阅内容无效"
    end
  end

  def ai_state(result)
    ai_group = safe_label(result[:ai_group])
    return "；已创建独立 AI 分组「#{ai_group}」，包含全部可用节点和代理提供者，节点由你选择" if result[:ai_group_created]
    return "；已升级 AI 分组「#{ai_group}」为独立节点选择器，节点由你选择" if result[:ai_group_reset]

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
    return "已更新并自动生效" if result[:reloaded]

    "已更新，尚未自动刷新"
  end

  def cli(argv = ARGV)
    options = {
      profile_dirs: [],
      policy: File.expand_path("../../references/policy.json", __dir__),
      backup_root: File.expand_path("~/Library/Application Support/ClashPatch/backups"),
      dry_run: false,
      auto_reload: true,
      print_tun_state: false,
      print_core_status: false,
      print_subscription_auto_update_state: false,
      disable_subscription_auto_update: false,
      snapshot_initial: false,
      list_backups: false,
      compare_backup: nil,
      restore_backup: nil,
      expected_current_sha256: nil,
      safe_update_all: false,
      usage_profile: nil
    }
    parser = OptionParser.new do |opts|
      opts.banner = "用法：patch_profiles.rb [选项]"
      opts.on("--profile-dir PATH", "添加一个订阅目录，可重复使用") { |value| options[:profile_dirs] << File.expand_path(value) }
      opts.on("--policy PATH", "指定策略文件") { |value| options[:policy] = File.expand_path(value) }
      opts.on("--backup-dir PATH", "指定备份目录") { |value| options[:backup_root] = File.expand_path(value) }
      opts.on("--dry-run", "只预览，不写入文件") { options[:dry_run] = true }
      opts.on("--no-reload", "只更新文件，不自动刷新当前订阅") { options[:auto_reload] = false }
      opts.on("--print-tun-state", "输出当前运行内核的 TUN 状态") { options[:print_tun_state] = true }
      opts.on("--print-core-status", "检查 Mihomo 内核是否满足最低版本") { options[:print_core_status] = true }
      opts.on("--print-subscription-auto-update-state", "输出订阅自动更新状态") { options[:print_subscription_auto_update_state] = true }
      opts.on("--disable-subscription-auto-update", "关闭订阅自动更新并回读确认") { options[:disable_subscription_auto_update] = true }
      opts.on("--snapshot-initial", "为当前存储位置创建一次初始快照") { options[:snapshot_initial] = true }
      opts.on("--list-backups", "按时间倒序列出可用备份") { options[:list_backups] = true }
      opts.on("--compare-backup ID", "比较指定备份与当前配置") { |value| options[:compare_backup] = value }
      opts.on("--restore-backup ID", "恢复指定备份") { |value| options[:restore_backup] = value }
      opts.on("--expected-current-sha256 SHA256", "恢复前要求当前配置哈希匹配") { |value| options[:expected_current_sha256] = value }
      opts.on("--safe-update-all", "安全更新当前存储位置中的全部远程订阅") { options[:safe_update_all] = true }
      opts.on("--usage-profile N", Integer, "安全更新采用的用途档位") { |value| options[:usage_profile] = value }
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

    if options[:print_subscription_auto_update_state]
      puts subscription_auto_update_state
      return 0
    end

    if options[:disable_subscription_auto_update]
      begin
        result = disable_subscription_auto_update(backup_root: options[:backup_root])
        puts result.fetch(:status)
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        warn error.message
        return 1
      end
    end

    if options[:list_backups]
      puts list_backups(options[:backup_root])
      return 0
    end

    directories = options[:profile_dirs].empty? ? default_profile_directories : options[:profile_dirs]
    if directories.empty?
      warn "没有找到 ClashX Meta 配置目录。"
      return 2
    end

    if options[:snapshot_initial]
      snapshot_initial_profiles(directories, options[:backup_root]).each { |path| puts File.basename(path) }
      return 0
    end

    if options[:compare_backup]
      puts JSON.generate(compare_backup(options[:compare_backup], directories: directories, backup_root: options[:backup_root]))
      return 0
    end

    if options[:restore_backup]
      result = restore_backup(
        options[:restore_backup], directories: directories, backup_root: options[:backup_root],
        expected_current_sha256: options[:expected_current_sha256], validator: method(:validate_with_mihomo)
      )
      puts JSON.generate(result.reject { |key, _value| key == :rollback_bytes })
      return result[:status] == :updated || result[:status] == :no_change ? 0 : 1
    end

    if options[:safe_update_all]
      unless [1, 2, 3].include?(options[:usage_profile])
        warn "安全更新必须指定用途档位 1、2 或 3。"
        return 64
      end
      policy = JSON.parse(File.read(options[:policy], encoding: "UTF-8"))
      targets = remote_subscription_targets(directories)
      result = safe_update_all(
        targets: targets, policy: policy, backup_root: options[:backup_root],
        usage_profile: options[:usage_profile], selected_name: selected_profile_name
      )
      if result[:status] == :updated
        puts "全部远程订阅已安全更新：#{result.fetch(:count)} 份。"
        result.fetch(:profiles).each { |name| puts "已更新：#{safe_label(name)}" }
        return 0
      end
      if result[:status] == :rollback_failed
        warn "安全更新失败，且至少一份订阅未能恢复；请立即按备份记录处理。"
        return 1
      end
      warn "安全更新失败；全部订阅保持原样。"
      return 1
    end

    results = run(
      directories: directories,
      policy_path: options[:policy],
      dry_run: options[:dry_run],
      backup_root: options[:backup_root],
      validator: options[:dry_run] ? nil : method(:validate_with_mihomo),
      auto_reload: options[:auto_reload] && !options[:dry_run]
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
