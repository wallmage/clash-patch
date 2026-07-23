#!/usr/bin/env ruby

require "coverage"

COVERAGE_ROOT = File.expand_path("..", __dir__)
MACOS_RUBY_ROOT = File.join(COVERAGE_ROOT, "clash-patch/scripts/macos")
TARGETS = Dir.glob(File.join(MACOS_RUBY_ROOT, "**", "*.rb")).sort.freeze
VERIFY_ROUTES_PATH = File.join(MACOS_RUBY_ROOT, "verify_routes.rb")
TRANSFORM_PATH = File.join(MACOS_RUBY_ROOT, "patch_profiles", "transform.rb")
PRODUCTION_AGGREGATE_TARGETS = TARGETS.select do |path|
  path != VERIFY_ROUTES_PATH
end.freeze
MINIMUM_PATCHER_LINE_COVERAGE = 90.0
MINIMUM_MODULE_LINE_COVERAGE = 80.0
MINIMUM_VERIFY_LINE_COVERAGE = 100.0
MINIMUM_TRANSFORM_LINE_COVERAGE = 100.0

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
    required = if path == VERIFY_ROUTES_PATH
                 MINIMUM_VERIFY_LINE_COVERAGE
               elsif path == TRANSFORM_PATH
                 MINIMUM_TRANSFORM_LINE_COVERAGE
               else
                 MINIMUM_MODULE_LINE_COVERAGE
               end
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

  abort "Ruby production coverage is below its required threshold" unless failures.empty?
end
