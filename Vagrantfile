# -*- mode: ruby -*-
# vi: set ft=ruby :

# This Vagrantfile is used for functional testing in the CI pipeline.
# Github Actions supports vagrant on the macos host.
Vagrant.configure('2') do |config|

  config.vm.define "amazonlinux_2" do |vm|
    vm.box = "bento/amazonlinux-2"
  end

  config.vm.define "centos_7" do |vm|
    vm.box = "generic/centos7"
  end

  config.vm.define "centos_8" do |vm|
    vm.box = "generic/centos8"
  end

  config.vm.define "debian_10" do |vm|
    vm.box = "generic/debian10"
  end

  config.vm.define "fedora_33" do |vm|
    vm.box = "generic/fedora33"
  end

  config.vm.define "fedora_34" do |vm|
    vm.box = "generic/fedora34"
  end

  config.vm.define "fedora_35" do |vm|
    vm.box = "generic/fedora35"
  end

  config.vm.define "ubuntu_18.04" do |vm|
    vm.box = "generic/ubuntu1804"
  end

  config.vm.define "ubuntu_20.04" do |vm|
    vm.box = "generic/ubuntu2004"
  end
end
