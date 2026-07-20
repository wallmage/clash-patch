#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "optparse"
require "tempfile"
require "yaml"

module ClashPatch
  module_function

  TUN_POLICY = {
    "enable" => true,
    "stack" => "system",
    "dns-hijack" => ["any:53", "tcp://any:53"],
    "auto-route" => true,
    "auto-detect-interface" => true,
    "strict-route" => true
  }.freeze

  BROAD_PROVIDER_PATTERN = /(?:^|[-_])(ai|cn|china|direct|domestic|global|notcn|proxy)(?:$|[-_])/i

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
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

  # AI-named groups are never main-group candidates: the managed DNS and UDP
  # rules must not make the AI group target itself.
  def detect_main_group(config, policy)
    candidates = selectable_groups(config).reject { |group| ai_name?(group["name"], policy) }
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
      return group["name"] unless members.empty? || members.all? { |member| member == "DIRECT" }
    end
    nil
  end

  def ai_name?(name, policy)
    return false unless name.is_a?(String)
    return true if Array(policy["ai_group_names"]).any? { |candidate| name.casecmp(candidate).zero? }

    normalized = name.downcase
    normalized.include?("openai") || normalized.include?("人工智能") || normalized.match?(/(^|[^a-z])ai([^a-z]|$)/)
  end

  def detect_ai_group(config, policy)
    selectable_groups(config).find { |group| ai_name?(group["name"], policy) }
  end

  def token_match?(name, token)
    return false unless name.is_a?(String)
    return name.downcase.include?(token.downcase) unless %w[TW JP].include?(token)

    name.match?(/(?:^|[^A-Za-z])#{Regexp.escape(token)}(?:[^A-Za-z]|$)/i)
  end

  def home_candidate(config, policy)
    group_names = Array(config["proxy-groups"]).each_with_object([]) do |group, names|
      names << group["name"] if group.is_a?(Hash) && group["name"].is_a?(String)
    end
    candidates = []
    Array(config["proxies"]).each do |proxy|
      candidates << proxy["name"] if proxy.is_a?(Hash) && proxy["name"].is_a?(String)
    end
    Array(config["proxy-groups"]).each do |group|
      Array(group["proxies"]).each do |name|
        candidates << name if name.is_a?(String) && !group_names.include?(name)
      end
    end
    candidates.uniq!
    candidates.select! { |name| name.include?("家宽") }

    taiwan = candidates.find { |name| Array(policy["taiwan_tokens"]).any? { |token| token_match?(name, token) } }
    return taiwan if taiwan

    candidates.find { |name| Array(policy["japan_tokens"]).any? { |token| token_match?(name, token) } }
  end

  def ensure_ai_group(config, policy, main_group, candidate)
    group = detect_ai_group(config, policy)
    unless group
      name = "🤖 AI"
      name = "🤖 AI 2" if Array(config["proxy-groups"]).any? { |item| item.is_a?(Hash) && item["name"] == name }
      group = { "name" => name, "type" => "select", "proxies" => [main_group] }
      config["proxy-groups"] << group
    end

    # Invariant: a proxy group must never list itself as a member.
    proxies = Array(group["proxies"]).dup - [group["name"]]
    if candidate && candidate != group["name"]
      proxies.delete(candidate)
      proxies.unshift(candidate)
      proxies << main_group if main_group != group["name"] && !proxies.include?(main_group)
    elsif proxies.empty? && main_group != group["name"]
      proxies << main_group
    end
    group["proxies"] = proxies
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

  def patch_dns(config, policy, main_group, ai_group)
    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["ipv6"] = false
    dns["respect-rules"] = true
    dns["use-hosts"] = true
    dns["use-system-hosts"] = true

    main_resolvers = tagged_resolvers(policy, main_group)
    ai_resolvers = tagged_resolvers(policy, ai_group)
    dns["default-nameserver"] = deep_copy(policy["default_bootstrap_resolvers"])
    dns["proxy-server-nameserver"] = deep_copy(policy["proxy_bootstrap_resolvers"])
    dns["nameserver"] = main_resolvers
    dns["fallback"] = deep_copy(main_resolvers) if dns.key?("fallback")
    dns["direct-nameserver"] = deep_copy(main_resolvers) if dns.key?("direct-nameserver")

    existing = dns["nameserver-policy"].is_a?(Hash) ? dns["nameserver-policy"] : {}
    policies = {}
    existing.each do |combined, endpoints|
      combined.to_s.split(",").map(&:strip).reject(&:empty?).each do |pattern|
        values = Array(endpoints).map(&:to_s)
        safe = values.any? do |value|
          fragment = value.split("#", 2)[1].to_s.split("&").first
          fragment && !fragment.empty? && fragment != "DIRECT"
        end
        policies[pattern] = safe ? values : deep_copy(main_resolvers)
      end
    end
    ai_dns_patterns(policy).each { |pattern| policies[pattern] = deep_copy(ai_resolvers) }
    dns["nameserver-policy"] = policies
  end

  def managed_rule_identity(rule)
    parts = rule.to_s.split(",")
    return nil if parts.length < 2

    [parts[0], parts[1]]
  end

  def render_ai_rules(policy, ai_group)
    Array(policy["ai_rules"]).map { |template| template.gsub("{AI}", ai_group) }
  end

  def broad_rule?(rule)
    parts = rule.to_s.split(",")
    return true if parts[0] == "MATCH"
    return true if %w[GEOSITE GEOIP].include?(parts[0])
    return false unless parts[0] == "RULE-SET"

    provider = parts[1].to_s
    provider.match?(BROAD_PROVIDER_PATTERN) || provider.match?(/国内|国外|节点|兜底/)
  end

  def patch_rules(config, policy, main_group, ai_group)
    managed = render_ai_rules(policy, ai_group)
    identities = managed.map { |rule| managed_rule_identity(rule) }.compact
    forbidden = Array(policy["forbidden_ai_domains"])
    ai_names = Array(config["proxy-groups"]).each_with_object([]) do |group, names|
      names << group["name"] if group.is_a?(Hash) && ai_name?(group["name"], policy)
    end
    ai_names << ai_group
    ai_names.uniq!

    rules = Array(config["rules"]).reject do |rule|
      parts = rule.to_s.split(",")
      target = parts[-1] == "no-resolve" ? parts[-2] : parts[-1]
      identity = managed_rule_identity(rule)
      managed_existing = identities.include?(identity)
      forbidden_ai = %w[DOMAIN DOMAIN-SUFFIX].include?(parts[0]) && forbidden.include?(parts[1]) && ai_names.include?(target)
      generic_udp = parts[0] == "NETWORK" && parts[1] == "UDP"
      managed_existing || forbidden_ai || generic_udp
    end

    anchor = rules.index { |rule| broad_rule?(rule) } || rules.length
    rules.insert(anchor, *managed, "NETWORK,UDP,#{main_group}")
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
    return { config: config, changed: false, status: :invalid, ai_group: nil, main_group: nil, selected_home: nil } unless usable_config?(config)

    original = deep_copy(config)
    patched = deep_copy(config)
    main_group = detect_main_group(patched, policy)
    return { config: config, changed: false, status: :no_main_group, ai_group: nil, main_group: nil, selected_home: nil } unless main_group

    candidate = home_candidate(patched, policy)
    ai_group = ensure_ai_group(patched, policy, main_group, candidate)
    patched["ipv6"] = false
    patched["tun"] = {} unless patched["tun"].is_a?(Hash)
    TUN_POLICY.each { |key, value| patched["tun"][key] = deep_copy(value) }
    patch_dns(patched, policy, main_group, ai_group)
    patch_rules(patched, policy, main_group, ai_group)
    normalize_reality_short_ids(patched)

    {
      config: patched,
      changed: patched != original,
      status: patched == original ? :unchanged : :updated,
      ai_group: ai_group,
      main_group: main_group,
      selected_home: candidate
    }
  end

  def quote_short_ids(yaml)
    yaml.gsub(/^(\s*short-id:\s*)([^'"\s][^\s#]*)(\s*(?:#.*)?)$/) do
      value = Regexp.last_match(2)
      next Regexp.last_match(0) unless value.match?(/\A[0-9a-fA-F]{1,16}\z/)

      "#{Regexp.last_match(1)}'#{value}'#{Regexp.last_match(3)}"
    end
  end

  def dump_config(config)
    quote_short_ids(YAML.dump(config))
  end

  def load_yaml(text)
    YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
  rescue ArgumentError
    YAML.safe_load(text, [], [], true)
  end

  def excluded_path?(path)
    basename = File.basename(path)
    return true if basename == "config.yaml"
    return true if basename.start_with?(".") || basename.end_with?(".tmp", ".bak", ".backup")

    path.split(File::SEPARATOR).any? { |part| part.match?(/\A(?:cache|caches|backup|backups|logs?)\z/i) }
  end

  def profile_paths(directory)
    Dir.glob(File.join(directory, "**", "*.{yaml,yml}"), File::FNM_EXTGLOB).sort.reject { |path| excluded_path?(path) }
  end

  def backup_once(path, backup_root)
    FileUtils.mkdir_p(backup_root)
    FileUtils.chmod(0o700, backup_root)
    key = Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
    destination = File.join(backup_root, "#{key}-#{File.basename(path)}.backup")
    FileUtils.cp(path, destination) unless File.exist?(destination)
    FileUtils.chmod(0o600, destination)
  end

  def patch_path(path, policy, dry_run: false, backup_root: nil)
    original_text = File.read(path, encoding: "UTF-8")
    config = load_yaml(original_text)
    result = patch(config, policy)
    return result.merge(path: path) unless result[:changed]

    patched_text = dump_config(result[:config])
    return result.merge(path: path, dry_run: true) if dry_run

    backup_once(path, backup_root) if backup_root
    mode = File.stat(path).mode
    Tempfile.create([File.basename(path), ".tmp"], File.dirname(path), encoding: "UTF-8") do |temporary|
      temporary.write(patched_text)
      temporary.flush
      temporary.fsync
      load_yaml(File.read(temporary.path, encoding: "UTF-8"))
      File.chmod(mode, temporary.path)
      File.rename(temporary.path, path)
    end
    result.merge(path: path)
  rescue StandardError
    { config: nil, changed: false, status: :invalid, ai_group: nil, main_group: nil, selected_home: nil, path: path }
  end

  def selected_profile_name
    IO.popen(["/usr/bin/defaults", "read", "com.metacubex.ClashX.meta", "selectConfigName"], err: File::NULL, &:read).strip
  rescue StandardError
    ""
  end

  def controller_socket(cache_directory = File.expand_path("~/Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs"))
    Dir.glob(File.join(cache_directory, "*.yaml")).sort_by { |path| File.mtime(path) }.reverse_each do |path|
      config = load_yaml(File.read(path, encoding: "UTF-8"))
      socket = config["external-controller-unix"]
      return socket if socket.is_a?(String) && File.socket?(socket)
    rescue StandardError
      next
    end
    nil
  end

  def reload(path)
    socket = controller_socket
    return false unless socket

    body = JSON.generate("path" => path)
    system(
      "/usr/bin/curl", "-sS", "--max-time", "3", "-X", "PUT",
      "-H", "Content-Type: application/json", "--data", body,
      "--unix-socket", socket, "http://localhost/configs?force=true",
      out: File::NULL, err: File::NULL
    )
  end

  def run(directory:, policy_path:, dry_run: false, backup_root: nil, reloader: nil, selected_name: nil)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    reloader ||= method(:reload)
    selected = selected_name.nil? ? selected_profile_name : selected_name
    results = profile_paths(directory).map do |path|
      result = patch_path(path, policy, dry_run: dry_run, backup_root: backup_root)
      result[:active] = File.basename(path, File.extname(path)) == selected
      result
    end
    active = results.find { |result| result[:changed] && result[:active] }
    active[:reloaded] = reloader.call(active[:path]) if active && !dry_run
    results
  end

  def chinese_status(result)
    name = File.basename(result[:path].to_s)
    case result[:status]
    when :updated
      node = result[:selected_home] ? "；AI 已选择「#{result[:selected_home]}」" : "；没有台湾或日本家宽节点，未替你更换节点"
      "#{name}：#{updated_state(result)}#{node}"
    when :unchanged then "#{name}：无需修改"
    when :no_main_group then "#{name}：未修改，找不到可用的主代理组"
    else "#{name}：已跳过，订阅内容无效"
    end
  end

  def updated_state(result)
    return "将更新（演练，未写入文件）" if result[:dry_run]
    return "已更新，选择该订阅时生效" unless result[:active]

    result[:reloaded] ? "已更新并生效" : "已更新，等待重新加载"
  end

  def cli(argv = ARGV)
    options = {
      profile_dir: File.expand_path("~/.config/clash.meta"),
      policy: File.expand_path("../../../references/policy.json", __dir__),
      backup_root: File.expand_path("~/Library/Application Support/ClashPatch/backups"),
      dry_run: false
    }
    parser = OptionParser.new do |opts|
      opts.on("--profile-dir PATH") { |value| options[:profile_dir] = File.expand_path(value) }
      opts.on("--policy PATH") { |value| options[:policy] = File.expand_path(value) }
      opts.on("--backup-dir PATH") { |value| options[:backup_root] = File.expand_path(value) }
      opts.on("--dry-run") { options[:dry_run] = true }
    end
    parser.parse!(argv)

    unless Dir.exist?(options[:profile_dir])
      warn "没有找到 ClashX Meta 配置目录：#{options[:profile_dir]}"
      return 2
    end

    results = run(
      directory: options[:profile_dir],
      policy_path: options[:policy],
      dry_run: options[:dry_run],
      backup_root: options[:backup_root]
    )
    results.each { |result| puts chinese_status(result) }
    0
  rescue StandardError => error
    warn "Clash 补丁运行失败：#{error.class}"
    1
  end
end

exit ClashPatch.cli if $PROGRAM_NAME == __FILE__
