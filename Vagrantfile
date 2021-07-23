# -*- mode: ruby -*-
# vi: set ft=ruby :

# This Vagrantfile is used for functional testing in the CI pipeline.
# Github Actions supports vagrant on the macos host.
Vagrant.configure('2') do |config|

  config.vm.define "amazonlinux_2" do |amazonlinux2|
    amazonlinux2.vm.box = "bento/amazonlinux-2"
  end

  config.vm.define "centos_7" do |centos7|
    centos7.vm.box = "generic/centos7"
  end

  config.vm.define "centos_8" do |centos8|
    centos8.vm.box = "generic/centos8"
  end

  config.vm.define "debian_10" do |debian10|
    debian10.vm.box = "generic/debian10"
  end

  config.vm.define "fedora_33" do |fedora33|
    fedora33.vm.box = "generic/fedora33"
  end

  config.vm.define "fedora_34" do |fedora34|
    fedora34.vm.box = "generic/fedora34"
  end

  config.vm.define "fedora_35" do |fedora35|
    fedora35.vm.box = "generic/fedora35"
  end

  config.vm.define "ubuntu_18.04" do |ubuntu1804|
    ubuntu1804.vm.box = "generic/ubuntu1804"
  end

  config.vm.define "ubuntu_20.04" do |ubuntu2004|
    ubuntu2004.vm.box = "generic/ubuntu2004"
  end
end
