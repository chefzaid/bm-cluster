#!/usr/bin/env ruby
# Omnibus removes development headers from its runtime image. Regenerate the
# matching release's headers only; never replace its interpreter or libruby.
require 'digest'
require 'fileutils'
require 'rbconfig'
require 'shellwords'

abort 'Expected vendor Ruby 3.3.12' unless RUBY_VERSION == '3.3.12'
archive = ARGV.fetch(0)
expected = 'b06d63beae271933033e27f0a389bc582a009e7845357d44365c39de525a051b'
abort 'Ruby source checksum mismatch' unless Digest::SHA256.file(archive).hexdigest == expected
FileUtils.mkdir_p('/tmp/ruby-headers')
system('tar', '-xzf', archive, '--strip-components=1', '-C', '/tmp/ruby-headers', exception: true)
Dir.chdir('/tmp/ruby-headers') do
  configure = Shellwords.split(RbConfig::CONFIG.fetch('configure_args')).map do |arg|
    arg.sub('--without-ext=', '--with-out-ext=')
  end
  system('./configure', *configure,
         '--enable-yjit', exception: true)
  headers = RbConfig::CONFIG.fetch('rubyhdrdir')
  architecture = RbConfig::CONFIG.fetch('rubyarchhdrdir')
  FileUtils.mkdir_p(headers)
  FileUtils.cp_r(Dir.glob('include/*'), headers)
  FileUtils.mkdir_p(File.join(architecture, 'ruby'))
  generated = Dir.glob('.ext/include/*/ruby/config.h')
  abort 'Expected one generated Ruby configuration header' unless generated.length == 1
  FileUtils.cp(generated.first, File.join(architecture, 'ruby/config.h'))
end
FileUtils.rm_rf('/tmp/ruby-headers')
