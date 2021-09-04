#!/bin/bash
set -ex

# CentOS 7 comes with GCC 4.8.5 which does not fully support C++14, so we need
# a newer toolchain.
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-9
source /opt/rh/devtoolset-9/enable

# Build omnibus package
. $HOME/.asdf/asdf.sh
cd /vagrant
cd omnibus
sudo mkdir -p /opt/firezone
sudo chown -R ${USER} /opt/firezone
bin/omnibus build firezone
