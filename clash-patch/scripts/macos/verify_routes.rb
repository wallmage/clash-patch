#!/usr/bin/env ruby

require "json"
require "socket"
require "stringio"

module ClashRouteBootstrap
  module_function

  def load_dependencies(loader:, argv:, output:)
    %w[patch_profiles result_contract].each { |path| loader.call(path) }
    true
  rescue LoadError
    raise unless argv.include?("--json")

    output.write(JSON.generate(
      "schema" => "clash-patch.result", "version" => 1, "command" => "verify_routes",
      "platform" => "macos", "client" => "clashx-meta", "operation" => "load",
      "ok" => false, "status" => "failed", "code" => "incomplete_package", "exit_code" => 1,
      "summary_zh" => "安装包不完整。", "profile" => nil, "changes" => [], "checks" => [],
      "items" => [], "messages" => [], "warnings" => []
    ) + "\n")
    false
  end
end

dependencies_loaded = ClashRouteBootstrap.load_dependencies(
  loader: ->(path) { require_relative path }, argv: ARGV, output: $stdout
)
exit 1 unless dependencies_loaded

module ClashRouteVerifier
  module_function

  TARGETS = [
    ["Google", "https://www.google.com/search?q=clash-route-verification", :main, /(?:\A|\.)google\.com\z/i],
    ["OpenAI", "https://openai.com/", :ai, /(?:\A|\.)openai\.com\z/i],
    ["Anthropic", "https://www.anthropic.com/", :ai, /(?:\A|\.)anthropic\.com\z/i],
    ["Claude", "https://claude.ai/", :ai, /(?:\A|\.)claude\.ai\z/i]
  ].freeze

  def get_json(socket, endpoint)
    code, body = ClashPatch.controller_request(socket, "GET", endpoint)
    return nil unless code == 200

    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def active_profile
    selected = ClashPatch.selected_profile_name
    ClashPatch.default_profile_directories.each do |directory|
      path = ClashPatch.profile_paths(directory).find { |candidate| ClashPatch.active_profile?(candidate, selected) }
      return path if path
    end
    nil
  end

  def reserve_local_port
    listener = TCPServer.new("127.0.0.1", 0)
    listener.local_address.ip_port
  ensure
    listener&.close
  end

  def observe_connection(socket, url, host_pattern)
    existing = Array(get_json(socket, "/connections")&.fetch("connections", [])).map { |entry| entry["id"] }
    source_port = reserve_local_port
    pid = Process.spawn(
      "/usr/bin/curl", "--http1.1", "-L", "--max-time", "15", "--limit-rate", "2k",
      "--local-port", source_port.to_s, url,
      out: File::NULL, err: File::NULL
    )
    100.times do
      sleep 0.1
      connections = Array(get_json(socket, "/connections")&.fetch("connections", []))
      observed = connections.find do |entry|
        metadata = entry["metadata"] || {}
        !existing.include?(entry["id"]) &&
          metadata["host"].to_s.match?(host_pattern) &&
          metadata["network"].to_s.casecmp("tcp").zero? &&
          metadata["sourcePort"].to_i == source_port
      end
      return observed if observed
    end
    nil
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def route_passes?(chains, proxies:, kind:, expected_group:, expected_selection:, ai_group:)
    return false if chains.include?("DIRECT") || expected_selection == "DIRECT"
    return chains.include?(expected_group) && chains.include?(expected_selection) if kind == :ai
    return false if chains.include?(ai_group)
    return true if chains.include?(expected_group) && chains.include?(expected_selection)

    chains.any? do |name|
      next false unless name.match?(/google/i)

      selection = proxies.dig(name, "now").to_s
      !selection.empty? && selection != "DIRECT" && chains.include?(selection)
    end
  end

  def run(output: $stdout, details: nil)
    socket = ClashPatch.controller_socket
    path = active_profile
    return false unless socket && path

    policy_path = File.expand_path("../../references/policy.json", __dir__)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    config = ClashPatch.load_yaml(File.read(path, encoding: "UTF-8"), path)
    main_group = ClashPatch.detect_main_group(config, policy)
    ai_group = ClashPatch.existing_ai_group(config, policy)&.fetch("name", nil)
    return false unless main_group && ai_group

    proxies = get_json(socket, "/proxies")&.fetch("proxies", {})
    return false unless proxies.is_a?(Hash)

    expected = { main: main_group, ai: ai_group }
    selections = {
      main: proxies.dig(main_group, "now").to_s,
      ai: proxies.dig(ai_group, "now").to_s
    }
    return false if selections.values.any? { |selection| selection.empty? || selection == "DIRECT" }

    output.puts "主代理组：#{ClashPatch.safe_label(main_group)} → #{ClashPatch.safe_label(selections.fetch(:main))}"
    output.puts "AI 分组：#{ClashPatch.safe_label(ai_group)} → #{ClashPatch.safe_label(selections.fetch(:ai))}"

    checks = TARGETS.map do |label, url, kind, host_pattern|
      connection = observe_connection(socket, url, host_pattern)
      chains = Array(connection && connection["chains"])
      ok = route_passes?(
        chains, proxies: proxies, kind: kind, expected_group: expected.fetch(kind),
        expected_selection: selections.fetch(kind), ai_group: ai_group
      )
      selected = chains.first
      output.puts "#{label}：#{ok ? '通过' : '失败'}（#{ClashPatch.safe_label(selected)}）"
      details[:checks] << { "name" => label.downcase, "ok" => ok } if details
      ok
    end
    checks.all?
  rescue StandardError
    false
  end

  def cli(argv = ARGV, output: $stdout)
    unknown = argv.reject { |argument| argument == "--json" }
    unless unknown.empty?
      json_mode = argv.include?("--json")
      if json_mode
        ClashPatchResult.write(
          output: output, command: "verify_routes", operation: "verify_routes", ok: false,
          status: "invalid_request", code: "invalid_arguments", exit_code: 64,
          summary_zh: "参数错误。", profile: nil, changes: [], checks: [], items: [],
          messages: [], warnings: []
        )
      end
      return 64
    end
    json_mode = argv.include?("--json")
    details = { checks: [] }
    ok = run(output: json_mode ? StringIO.new : output, details: details)
    exit_code = ok ? 0 : 1
    if json_mode
      ClashPatchResult.write(
        output: output, command: "verify_routes", operation: "verify_routes", ok: ok,
        status: ok ? "ok" : "failed", code: ok ? "routes_verified" : "route_verification_failed",
        exit_code: exit_code, summary_zh: ok ? "实时分流验证通过。" : "实时分流验证未通过。",
        profile: nil, changes: [], checks: details.fetch(:checks), items: [], messages: [], warnings: []
      )
    end
    exit_code
  end
end

exit ClashRouteVerifier.cli if $PROGRAM_NAME == __FILE__
