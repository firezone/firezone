# -*- mode: ruby -*-
# vi: set ft=ruby :

# This Vagrantfile is used for functional testing in the CI pipeline.
# Github Actions supports vagrant on the macos host.
Vagrant.configure('2') do |config|
  config.vm.define "centos_7" do |centos7|
    centos7.vm.box = "generic/centos7"
    centos7.vm.network "forwarded_port", guest: 8800, host: 8800
    source_file = Dir["_build/firezone*centos_7*.tar.gz"].first
    if source_file
      centos7.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    centos7.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    centos7.vm.provision "shell", path: "scripts/provision/centos_7.sh"
  end

  config.vm.define "centos_8" do |centos8|
    centos8.vm.box = "generic/centos8"
    centos8.vm.network "forwarded_port", guest: 8800, host: 8801
    source_file = Dir["_build/firezone*centos_8*.tar.gz"].first
    if source_file
      centos8.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    centos8.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    centos8.vm.provision "shell", path: "scripts/provision/centos_8.sh"
  end

  config.vm.define "debian_10" do |debian10|
    debian10.vm.box = "generic/debian10"
    debian10.vm.network "forwarded_port", guest: 8800, host: 8802
    source_file = Dir["_build/firezone*debian_10*.tar.gz"].first
    if source_file
      debian10.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    debian10.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    debian10.vm.provision "shell", path: "scripts/provision/debian_10.sh"
  end

  config.vm.define "fedora_33" do |fedora33|
    fedora33.vm.box = "generic/fedora33"
    fedora33.vm.network "forwarded_port", guest: 8800, host: 8803
    source_file = Dir["_build/firezone*fedora_33*.tar.gz"].first
    if source_file
      fedora33.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    fedora33.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    fedora33.vm.provision "shell", path: "scripts/provision/fedora_33.sh"
  end

  config.vm.define "fedora_34" do |fedora34|
    fedora34.vm.box = "generic/fedora34"
    fedora34.vm.network "forwarded_port", guest: 8800, host: 8804
    source_file = Dir["_build/firezone*fedora_34*.tar.gz"].first
    if source_file
      fedora34.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    fedora34.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    fedora34.vm.provision "shell", path: "scripts/provision/fedora_34.sh"
  end

  config.vm.define "ubuntu_18.04" do |ubuntu1804|
    ubuntu1804.vm.box = "generic/ubuntu1804"
    ubuntu1804.vm.network "forwarded_port", guest: 8800, host: 8805
    source_file = Dir["_build/firezone*ubuntu_18.04*.tar.gz"].first
    if source_file
      ubuntu1804.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    ubuntu1804.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    ubuntu1804.vm.provision "shell", path: "scripts/provision/ubuntu_18.04.sh"
  end

  config.vm.define "ubuntu_20.04" do |ubuntu2004|
    ubuntu2004.vm.box = "generic/ubuntu2004"
    ubuntu2004.vm.network "forwarded_port", guest: 8800, host: 8806
    source_file = Dir["_build/firezone*ubuntu_20.04*.tar.gz"].first
    if source_file
      ubuntu2004.vm.provision "file", source: source_file, destination: "/tmp/"
    end
    ubuntu2004.vm.provision "file", source: "scripts/install.sh", destination: "/tmp/"
    ubuntu2004.vm.provision "shell", path: "scripts/provision/ubuntu_20.04.sh"
  end
end
