# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure('2') do |config|
  config.vm.define "server" do |server|
    server.vm.box = 'hashicorp/bionic64'
    server.vm.hostname = 'server'

    # Link to client
    server.vm.network 'private_network', ip: '172.16.1.2'

    server.vm.network 'forwarded_port', guest: 4000, host: 4000, protocol: 'tcp'

    # Install dependencies
    server.vm.provision 'shell', path: 'vagrant/provision_deps.sh'
    server.vm.provision 'shell', path: 'vagrant/provision_runtimes.sh'

    # Copy WireGuard server into place
    server.vm.provision 'file', source: 'vagrant/sample_conf/wg-server.conf', destination: '/tmp/wg0.conf'
    server.vm.provision 'shell', inline: 'mv /tmp/wg0.conf /etc/wireguard/'

    server.vm.provision 'shell', privileged: true, inline: <<~SHELL
      echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
      echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
      sysctl -p
    SHELL
  end

  config.vm.define "client" do |client|
    client.vm.box = 'hashicorp/bionic64'
    client.vm.hostname = 'client'
  
    # Link to server
    client.vm.network 'private_network', ip: '172.16.1.3'

    # Install dependencies
    client.vm.provision 'shell', path: 'vagrant/provision_deps.sh'
    client.vm.provision 'shell', path: 'vagrant/provision_runtimes.sh'

    # Copy WireGuard client into place
    client.vm.provision 'file', source: 'vagrant/sample_conf/wg-client.conf', destination: '/tmp/wg0.conf'
    client.vm.provision 'shell', inline: 'mv /tmp/wg0.conf /etc/wireguard/', privileged: true
  end
end
