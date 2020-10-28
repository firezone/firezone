# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure('2') do |config|
  config.vm.provider 'virtualbox' do |vbox|
    # Speed up compiles
    vbox.cpus = 4
  end

  config.vm.box = 'ubuntu/focal64'
  config.vm.hostname = 'fireguard.local'

  # Web
  config.vm.network 'forwarded_port', guest: 4000, host: 4000, protocol: 'tcp'

  # VPN
  config.vm.network 'forwarded_port', guest: 51820, host: 51820, protocol: 'udp'

  config.vm.provision 'ansible' do |ansible|
    ansible.playbook = 'ansible/playbook.yml'
    ansible.verbose = true
  end
end
