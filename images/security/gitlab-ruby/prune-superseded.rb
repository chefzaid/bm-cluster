#!/usr/bin/env ruby
# Remove complete superseded installations, retaining every locked version and
# dependencies needed by other Omnibus gems. Do not use bundle clean: Rails and
# the administration commands intentionally share this gem home.
require 'bundler'
require 'fileutils'
require 'set'

locked = Set.new
Dir.glob('/opt/gitlab/embedded/service/*/Gemfile.lock').each do |file|
  Dir.chdir(File.dirname(file)) do
    Bundler::LockfileParser.new(File.read(file)).specs.each do |spec|
      locked.add([spec.name, spec.version])
    end
  end
end
specs = Gem::Specification.to_a
by_name = specs.group_by(&:name)
removable = specs.select do |spec|
  !spec.default_gem? && spec.name != 'bundler' &&
    by_name.fetch(spec.name).length > 1 &&
    !locked.include?([spec.name, spec.version])
end.to_set

# Retaining an older package may itself require another older dependency.
loop do
  retained = nil
  (specs - removable.to_a).each do |spec|
    spec.runtime_dependencies.each do |dependency|
      installed = specs.select { |candidate| dependency.match?(candidate.name, candidate.version) }
      next if installed.empty? || installed.any? { |candidate| !removable.include?(candidate) }
      retained = installed.max_by(&:version)
      break
    end
    break if retained
  end
  break unless retained
  removable.delete(retained)
end

home = File.realpath(Gem.dir) + '/'
removable.sort_by(&:full_name).each do |spec|
  paths = [spec.full_gem_path, spec.loaded_from, spec.extension_dir,
           File.join(Gem.dir, 'cache', spec.full_name + '.gem')]
  paths.each do |path|
    abort "Unexpected gem path: #{path}" unless File.expand_path(path).start_with?(home)
    FileUtils.rm_rf(path)
  end
  puts "Removed superseded gem #{spec.full_name}"
end
Gem::Specification.reset
