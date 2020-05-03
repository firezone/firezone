# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure('2') do |config|
  config.vm.box = 'ubuntu/bionic64'

  config.vm.provider 'virtualbox' do |vb|
    vb.cpus = 4
    vb.memory = '2048'
  end

  # WireGuard
  config.vm.network 'forwarded_port', guest: 51820, host: 51820, protocol: 'udp'

  # App
  config.vm.network 'forwarded_port', guest: 4000, host: 4000, protocol: 'tcp'

  # Postgres, by default, this listens to 127.0.0.1 within the VM only. If you'd
  # like to be able to access Postgres from the host, uncomment this line and configure
  # it to listen to 0.0.0.0 within the VM.
  # config.vm.network 'forwarded_port', guest: 5432, host: 5432, protocol: 'tcp'

  config.vm.provision 'shell', path: 'provision_deps.sh', privileged: true
  config.vm.provision 'shell', path: 'provision_runtimes.sh', privileged: false

  # Copy WireGuard config into place
  config.vm.provision 'file', source: 'sample_conf/wg-server.conf', destination: '/etc/wireguard/wgdev.conf'
end
