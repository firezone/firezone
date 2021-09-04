# -*- mode: ruby -*-
# vi: set ft=ruby :

# This Vagrantfile is used for functional testing in the CI pipeline.
Vagrant.configure("2") do |config|
    # Github Actions MacOS hosts have 14 GB RAM and 3 CPU cores :-D
    config.vm.provider "virtualbox" do |virtualbox|
      virtualbox.memory = 8_192

      if ENV["CI"]
        virtualbox.cpus = 3
      else
        # Be sure to only run one VM at a time on local dev server
        virtualbox.cpus = 11
      end
    end

  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", "_build/", "**/deps/", "**/node_modules/"]

  config.vm.define "centos_7" do |centos7|
    centos7.vm.box = "generic/centos7"
    centos7.vm.box_url = "https://home.cloudfirenetwork.com/vb/centos7.box"
    centos7.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8800)

    # Set up base OS
    centos7.vm.provision "shell", path: ".ci/provision/centos_7.sh", privileged: false

    # Set up ruby
    centos7.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    centos7.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Install a newer kernel with proper nftables support
    centos7.vm.provision "shell", reboot: true, inline: <<~SHELL
      yum install -y elrepo-release
      yum --enablerepo=elrepo-kernel install -y kernel-lt
    SHELL

    # Initialize and start
    centos7.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "centos_8" do |centos8|
    centos8.vm.box = "generic/centos8"
    centos8.vm.box_url = "https://home.cloudfirenetwork.com/vb/centos8.box"
    centos8.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8801)
    centos8.vm.provision "shell", path: ".ci/provision/centos_8.sh", privileged: false

    # Set up ruby
    centos8.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    centos8.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Initialize and start
    centos8.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "debian_10" do |debian10|
    debian10.vm.box = "generic/debian10"
    debian10.vm.box_url = "https://home.cloudfirenetwork.com/vb/debian10.box"
    debian10.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8802)
    debian10.vm.provision "shell", path: ".ci/provision/debian_10.sh", privileged: false

    # Set up ruby
    debian10.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    debian10.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Install newer kernel
    debian10.vm.provision "shell", reboot: true, inline: <<~SHELL
      sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge apt-listchanges

      # Add Backports repo
      sudo bash -c 'echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list'
      sudo apt-get -q update

      # Install newer kernel
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y -t buster-backports dist-upgrade
    SHELL

    # Initialize and start
    debian10.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "fedora_33" do |fedora33|
    fedora33.vm.box = "generic/fedora33"
    fedora33.vm.box_url = "https://home.cloudfirenetwork.com/vb/fedora33.box"
    fedora33.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8803)
    fedora33.vm.provision "shell", path: ".ci/provision/fedora_33.sh", privileged: false

    # Set up ruby
    fedora33.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    fedora33.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Initialize and start
    fedora33.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "fedora_34" do |fedora34|
    fedora34.vm.box = "generic/fedora34"
    fedora34.vm.box_url = "https://home.cloudfirenetwork.com/vb/fedora34.box"
    fedora34.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8804)
    fedora34.vm.provision "shell", path: ".ci/provision/fedora_34.sh", privileged: false

    # Set up ruby
    fedora34.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    fedora34.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Initialize and start
    fedora34.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "ubuntu_18.04" do |ubuntu1804|
    ubuntu1804.vm.box = "generic/ubuntu1804"
    ubuntu1804.vm.box_url = "https://home.cloudfirenetwork.com/vb/ubuntu1804.box"
    ubuntu1804.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8805)
    ubuntu1804.vm.provision "shell", path: ".ci/provision/ubuntu_18.04.sh", privileged: false

    # Set up ruby
    ubuntu1804.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    ubuntu1804.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Upgrade kernel
    ubuntu1804.vm.provision "shell", reboot: true, inline: <<~SHELL
      export DEBIAN_FRONTEND=noninteractive
      sudo apt-get -q update
      sudo apt-get install -y linux-image-generic-hwe-18.04 linux-headers-generic-hwe-18.04
    SHELL

    # Initialize and start
    ubuntu1804.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "ubuntu_20.04" do |ubuntu2004|
    ubuntu2004.vm.box = "generic/ubuntu2004"
    ubuntu2004.vm.box_url = "https://home.cloudfirenetwork.com/vb/ubuntu2004.box"
    ubuntu2004.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8806)
    ubuntu2004.vm.provision "shell", path: ".ci/provision/ubuntu_20.04.sh", privileged: false

    # Set up ruby
    ubuntu2004.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    ubuntu2004.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Initialize and start
    ubuntu2004.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end

  config.vm.define "debian_11" do |debian11|
    debian11.vm.box = "generic/debian11"
    debian11.vm.box_url = "https://home.cloudfirenetwork.com/vb/debian11.box"
    debian11.vm.network "forwarded_port", guest: 8800, host: ENV.fetch("PORT", 8807)
    debian11.vm.provision "shell", path: ".ci/provision/debian_11.sh", privileged: false

    # Set up ruby
    debian11.vm.provision "shell", path: ".ci/provision/ruby.sh", privileged: false

    # Build FireZone
    debian11.vm.provision "shell", path: ".ci/provision/build.sh", privileged: false

    # Initialize and start
    debian11.vm.provision "shell", path: ".ci/provision/initialize.sh", privileged: false
  end
end
