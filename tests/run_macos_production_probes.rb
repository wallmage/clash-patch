#!/usr/bin/env ruby

require "rbconfig"

ROOT = File.expand_path("..", __dir__)
PROBE_FILTER = "/production_probe/".freeze

current_ruby = ENV.fetch("CLASH_PATCH_CURRENT_RUBY", RbConfig.ruby)
system_ruby = ENV.fetch("CLASH_PATCH_SYSTEM_RUBY", "/usr/bin/ruby")
probe_environment = { "CLASH_PATCH_RUN_PRODUCTION_PROBES" => "1" }.freeze
commands = [
  [current_ruby, "tests/test_macos_patcher.rb"],
  [current_ruby, "tests/test_macos_wrappers.rb"],
  [system_ruby, "tests/test_macos_patcher.rb"],
  [system_ruby, "tests/test_macos_wrappers.rb"]
]

failed = false
commands.each do |ruby, suite|
  success = system(
    probe_environment, ruby, suite, "--name", PROBE_FILTER,
    chdir: ROOT
  )
  failed ||= !success
end

exit(failed ? 1 : 0)
