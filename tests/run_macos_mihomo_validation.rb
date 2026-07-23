#!/usr/bin/env ruby

require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
TEST_NAME = "test_generated_profile_passes_installed_mihomo_validation".freeze

environment = { "CLASH_PATCH_REQUIRE_REAL_MIHOMO" => "1" }
stdout, stderr, status = Open3.capture3(
  environment,
  RbConfig.ruby,
  "tests/test_macos_patcher.rb",
  "--name",
  TEST_NAME,
  chdir: ROOT
)
$stdout.write(stdout)
$stderr.write(stderr)

summary = stdout.lines.find { |line| line.include?(" runs, ") && line.include?(" assertions, ") }
assertions = (summary&.match(/,\s*(\d+) assertions,?/)&.captures&.first || "0").to_i
complete = status.success? &&
           summary&.include?("1 runs") &&
           summary.include?("0 failures") &&
           summary.include?("0 errors") &&
           summary.include?("0 skips") &&
           assertions.positive?

warn "real Mihomo validation did not execute exactly one complete test case" unless complete
exit(complete ? 0 : 1)
