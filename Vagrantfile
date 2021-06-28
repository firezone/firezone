# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure('2') do |config|
  config.vm.provider 'virtualbox' do |vbox|
    # Speed up compiles
    vbox.cpus = 4
  end

  config.vm.box = 'ubuntu/focal64'
  config.vm.hostname = 'cloudfire.local'

  # Web
  config.vm.network 'forwarded_port', guest: 8800, host: 8800, protocol: 'tcp'

  # VPN
  config.vm.network 'forwarded_port', guest: 51820, host: 51820, protocol: 'udp'

  # Disabling Ansible provisioner for now in favor of a vanilla Ubuntu VM.
  # config.vm.provision 'ansible' do |ansible|
  #   ansible.playbook = 'ansible/playbook.yml'
  #   ansible.verbose = true
  # end
end
