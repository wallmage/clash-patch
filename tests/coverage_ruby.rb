#!/usr/bin/env ruby

require "coverage"

COVERAGE_ROOT = File.expand_path("..", __dir__)
TARGETS = [
  File.join(COVERAGE_ROOT, "clash-patch/scripts/macos/patch_profiles.rb"),
  File.join(COVERAGE_ROOT, "clash-patch/scripts/macos/verify_routes.rb")
].freeze
MINIMUM_LINE_COVERAGE = {
  File.join(COVERAGE_ROOT, "clash-patch/scripts/macos/patch_profiles.rb") => 90.0,
  File.join(COVERAGE_ROOT, "clash-patch/scripts/macos/verify_routes.rb") => 100.0
}.freeze
TRANSFORM_CORE_METHODS = %i[
  deep_copy base_result usable_config? selectable_groups managed_name? managed_group_name?
  detect_main_group ai_name? existing_ai_group unique_group_name managed_ai_group_fingerprint?
  managed_safe_group_fingerprint? owned_ai_group? resolver_targets owned_safe_group?
  find_managed_select_group ai_group_sources configure_managed_ai_group ensure_ai_group direct_name?
  owned_managed_group_names remove_owned_managed_groups tagged_resolvers ai_dns_patterns
  legacy_ai_dns_patterns safe_proxy_target? group_cannot_reach_direct? resolver_target
  safe_resolver_endpoint? normalized_resolver_endpoints patch_dns split_rule_fields rule_info
  managed_rule_key managed_rule_identity render_ai_rules broad_rule? patch_rules
  normalize_reality_short_ids patch dump_config tag_reality_short_ids yaml_alias? load_yaml
].freeze

Coverage.start(lines: true)
load File.join(__dir__, "test_macos_patcher.rb")

Minitest.after_run do
  result = Coverage.result
  failures = TARGETS.each_with_object([]) do |path, failed|
    lines = result.fetch(path).fetch(:lines)
    relevant = lines.compact
    covered = relevant.count(&:positive?)
    percentage = covered * 100.0 / relevant.length
    minimum = MINIMUM_LINE_COVERAGE.fetch(path)
    puts format("%s: %.2f%% (%d/%d), required %.2f%%", path.sub("#{COVERAGE_ROOT}/", ""), percentage, covered, relevant.length, minimum)
    next if percentage >= minimum

    missing = lines.each_index.each_with_object([]) { |index, items| items << index + 1 if lines[index] == 0 }
    warn format("%s: %.2f%% below %.2f%% (%d/%d), uncovered lines: %s", path, percentage, minimum, covered, relevant.length, missing.join(", "))
    failed << path
  end


  patcher_path = TARGETS.first
  patcher_lines = result.fetch(patcher_path).fetch(:lines)
  core_methods = TRANSFORM_CORE_METHODS.map { |name| ClashPatch.method(name) }
  core_methods << ClashPatch::YAML12ScalarScanner.instance_method(:tokenize)
  core_line_numbers = core_methods.flat_map do |method|
    ast = RubyVM::AbstractSyntaxTree.of(method)
    (ast.first_lineno..ast.last_lineno).select { |line_number| !patcher_lines[line_number - 1].nil? }
  end.uniq
  covered_core = core_line_numbers.count { |line_number| patcher_lines[line_number - 1].positive? }
  core_percentage = covered_core * 100.0 / core_line_numbers.length
  puts format("macOS transform core: %.2f%% (%d/%d), required 100.00%%", core_percentage, covered_core, core_line_numbers.length)
  failures << "macOS transform core" unless covered_core == core_line_numbers.length

  abort "Ruby production coverage is below its required threshold" unless failures.empty?
end
