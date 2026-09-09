#!/usr/bin/env ruby
# Update the default gem's actual implementation and specification together.
require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'rubygems/package'
require 'tmpdir'

assets = File.dirname(__FILE__)
lock = JSON.parse(File.read(File.join(assets, 'resolv-lock.json')))
Dir.mktmpdir('resolv-security-') do |directory|
  packages = {}
  lock.each do |version, artifact|
    archive = File.join(assets, "resolv-#{version}.gem")
    abort 'Resolv checksum mismatch' unless Digest::SHA256.file(archive).hexdigest == artifact.fetch('sha256')
    package = Gem::Package.new(archive)
    abort 'Unexpected Resolv package' unless package.spec.name == 'resolv' && package.spec.version.to_s == version
    package.extract_files(File.join(directory, version))
    packages[version] = package
  end
  old = Gem::Specification.find_all_by_name('resolv').find(&:default_gem?)
  abort 'Expected default Resolv 0.3.1' unless old && old.version.to_s == '0.3.1'
  destination = File.join(RbConfig::CONFIG.fetch('rubylibdir'), 'resolv.rb')
  original = File.join(directory, '0.3.1/lib/resolv.rb')
  abort 'Vendor Resolv implementation differs from original gem' unless File.binread(destination) == File.binread(original)
  replacement = packages.fetch('0.3.2').spec
  abort 'Unexpected Resolv payload' unless replacement.files.grep(%r{\Alib/}) == ['lib/resolv.rb'] && replacement.runtime_dependencies.empty?
  FileUtils.cp(File.join(directory, '0.3.2/lib/resolv.rb'), destination)
  replacement.files = ['resolv.rb']
  File.write(File.join(File.dirname(old.loaded_from), replacement.full_name + '.gemspec'), replacement.to_ruby)
  FileUtils.rm(old.loaded_from)
end
