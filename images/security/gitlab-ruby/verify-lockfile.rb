#!/usr/bin/env ruby
# A conservative Bundler update may still downgrade another dependency to
# satisfy new constraints. Reject that tradeoff in this security image.
require 'bundler'

before = Bundler::LockfileParser.new(File.read(ARGV.fetch(0))).specs.group_by(&:name)
after = Bundler::LockfileParser.new(File.read(ARGV.fetch(1))).specs.group_by(&:name)
after.each do |name, specs|
  next unless before.key?(name)
  previous = before.fetch(name).map(&:version).max
  current = specs.map(&:version).min
  abort "Dependency downgrade rejected: #{name} #{previous} -> #{current}" if current < previous
end
puts 'Dependency lockfile contains no version downgrades'
