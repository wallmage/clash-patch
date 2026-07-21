#!/usr/bin/env ruby

require "json"
require_relative "patch_profiles"

module ClashRouteVerifier
  module_function

  TARGETS = [
    ["Google", "https://www.google.com/search?q=clash-route-verification", :main, /google/i],
    ["OpenAI", "https://openai.com/", :ai, /openai/i],
    ["Anthropic", "https://www.anthropic.com/", :ai, /anthropic/i],
    ["Claude", "https://claude.ai/", :ai, /claude/i]
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

  def observe_connection(socket, url, host_pattern)
    existing = Array(get_json(socket, "/connections")&.fetch("connections", [])).map { |entry| entry["id"] }
    pid = Process.spawn(
      "/usr/bin/curl", "--http1.1", "-L", "--max-time", "15", "--limit-rate", "2k", url,
      out: File::NULL, err: File::NULL
    )
    100.times do
      sleep 0.1
      connections = Array(get_json(socket, "/connections")&.fetch("connections", []))
      observed = connections.find do |entry|
        !existing.include?(entry["id"]) && entry.dig("metadata", "host").to_s.match?(host_pattern)
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

  def run(output: $stdout)
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
    output.puts "主代理组：#{ClashPatch.safe_label(main_group)} → #{ClashPatch.safe_label(proxies.dig(main_group, 'now'))}"
    output.puts "AI 分组：#{ClashPatch.safe_label(ai_group)} → #{ClashPatch.safe_label(proxies.dig(ai_group, 'now'))}"

    checks = TARGETS.map do |label, url, kind, host_pattern|
      connection = observe_connection(socket, url, host_pattern)
      chains = Array(connection && connection["chains"])
      ok = chains.include?(expected.fetch(kind))
      selected = chains.first
      output.puts "#{label}：#{ok ? '通过' : '失败'}（#{ClashPatch.safe_label(selected)}）"
      ok
    end
    checks.all?
  rescue StandardError
    false
  end
end

exit(ClashRouteVerifier.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
