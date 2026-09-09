# Record the actual rebuilt component release in Omnibus inventory.
require 'json'
file='/opt/gitlab/version-manifest.json'
data=JSON.parse(File.read(file))
component=data.fetch('software').fetch('prometheus')
raise 'Unexpected Prometheus release' unless component.fetch('locked_version')=='f0f0fdd679dcd6df320b0558b20919f7cd44c407'
component['locked_version']='eb173f5256d4022afba1e9bc3d19740a76859fae'
component['locked_source']={'git'=>'https://github.com/prometheus/prometheus.git','depth'=>1}
component['described_version']='v3.11.3'
component['display_version']='v3.11.3'
File.write(file,JSON.pretty_generate(data)+"\n")
file='/opt/gitlab/version-manifest.txt'
text=File.read(file)
text=text.lines.map {|line| line.start_with?('prometheus ') ? line.gsub('v3.11.2','v3.11.3').gsub('f0f0fdd679dcd6df320b0558b20919f7cd44c407','eb173f5256d4022afba1e9bc3d19740a76859fae') : line}.join
File.write(file,text)
