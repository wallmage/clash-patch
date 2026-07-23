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
MINIMUM_PATCHER_LINE_COVERAGE = 100.0
MINIMUM_MODULE_LINE_COVERAGE = 100.0
MINIMUM_VERIFY_LINE_COVERAGE = 100.0
MINIMUM_TRANSFORM_LINE_COVERAGE = 100.0
MINIMUM_PRODUCTION_BRANCH_COVERAGE = 75.0

def uncovered_line_ranges(lines)
  missing = lines.each_index.select { |index| lines[index] == 0 }.map { |index| index + 1 }
  missing.slice_when { |left, right| right != left + 1 }.map do |range|
    range.length == 1 ? range.first.to_s : "#{range.first}-#{range.last}"
  end
end

def branch_counts(coverage)
  coverage.fetch(:branches).values.flat_map(&:values)
end

def uncovered_branch_lines(coverage)
  coverage.fetch(:branches).values.flat_map do |branches|
    branches.select { |_branch, count| count.zero? }.keys.map { |branch| branch.fetch(2) }
  end.uniq.sort
end

Coverage.start(lines: true, branches: true)
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
    missing = uncovered_line_ranges(lines)
    puts "  uncovered: #{missing.join(', ')}" unless missing.empty?
    branches = branch_counts(result.fetch(path))
    branch_covered = branches.count(&:positive?)
    branch_percentage = branch_covered * 100.0 / branches.length
    puts format("  branches: %.2f%% (%d/%d)", branch_percentage, branch_covered, branches.length)
    missing_branches = uncovered_branch_lines(result.fetch(path))
    puts "  uncovered branch lines: #{missing_branches.join(', ')}" unless missing_branches.empty?
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

  production_branches = TARGETS.flat_map { |path| branch_counts(result.fetch(path)) }
  production_branch_covered = production_branches.count(&:positive?)
  production_branch_percentage = production_branch_covered * 100.0 / production_branches.length
  puts format(
    "macOS Ruby production branch aggregate: %.2f%% (%d/%d), required %.2f%%",
    production_branch_percentage, production_branch_covered, production_branches.length,
    MINIMUM_PRODUCTION_BRANCH_COVERAGE
  )
  if production_branch_percentage < MINIMUM_PRODUCTION_BRANCH_COVERAGE
    failures << "macOS Ruby production branch aggregate"
  end

  abort "Ruby production coverage is below its required threshold" unless failures.empty?
end
