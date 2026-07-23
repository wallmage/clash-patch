#!/usr/bin/env ruby

require "coverage"

COVERAGE_ROOT = File.expand_path("..", __dir__)
MACOS_RUBY_ROOT = File.join(COVERAGE_ROOT, "clash-patch/scripts/macos")
TARGETS = Dir.glob(File.join(MACOS_RUBY_ROOT, "**", "*.rb")).sort.freeze
VERIFY_ROUTES_PATH = File.join(MACOS_RUBY_ROOT, "verify_routes.rb")
PRODUCTION_AGGREGATE_TARGETS = TARGETS.select do |path|
  path != VERIFY_ROUTES_PATH
end.freeze
MINIMUM_PATCHER_LINE_COVERAGE = 90.0
MINIMUM_MODULE_LINE_COVERAGE = 80.0
MINIMUM_VERIFY_LINE_COVERAGE = 100.0
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
  failures = []
  TARGETS.each do |path|
    lines = result.fetch(path).fetch(:lines)
    relevant = lines.compact
    covered = relevant.count(&:positive?)
    percentage = covered * 100.0 / relevant.length
    required = path == VERIFY_ROUTES_PATH ? MINIMUM_VERIFY_LINE_COVERAGE : MINIMUM_MODULE_LINE_COVERAGE
    puts format(
      "%s: %.2f%% (%d/%d), required %.2f%%",
      path.sub("#{COVERAGE_ROOT}/", ""), percentage, covered, relevant.length, required
    )
    failures << path if percentage < required
  end

  production_relevant = PRODUCTION_AGGREGATE_TARGETS.sum { |path| result.fetch(path).fetch(:lines).compact.length }
  production_covered = PRODUCTION_AGGREGATE_TARGETS.sum { |path| result.fetch(path).fetch(:lines).compact.count(&:positive?) }
  production_percentage = production_covered * 100.0 / production_relevant
  puts format(
    "macOS Ruby production aggregate: %.2f%% (%d/%d), required %.2f%%",
    production_percentage, production_covered, production_relevant, MINIMUM_PATCHER_LINE_COVERAGE
  )
  failures << "macOS Ruby production aggregate" if production_percentage < MINIMUM_PATCHER_LINE_COVERAGE

  core_methods = TRANSFORM_CORE_METHODS.map { |name| ClashPatch.method(name) }
  core_methods << ClashPatch::YAML12ScalarScanner.instance_method(:tokenize)
  core_line_references = core_methods.flat_map do |method|
    path = method.source_location.fetch(0)
    ast = RubyVM::AbstractSyntaxTree.of(method)
    unless ast
      failures << "macOS transform core AST: #{method.name}"
      next []
    end
    (ast.first_lineno..ast.last_lineno).each_with_object([]) do |line_number, references|
      references << [path, line_number] unless result.fetch(path).fetch(:lines)[line_number - 1].nil?
    end
  end.uniq
  covered_core = core_line_references.count do |path, line_number|
    result.fetch(path).fetch(:lines)[line_number - 1].positive?
  end
  core_percentage = covered_core * 100.0 / core_line_references.length
  puts format("macOS transform core: %.2f%% (%d/%d), required 100.00%%", core_percentage, covered_core, core_line_references.length)
  failures << "macOS transform core" unless covered_core == core_line_references.length

  abort "Ruby production coverage is below its required threshold" unless failures.empty?
end
