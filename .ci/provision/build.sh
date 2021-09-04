#!/bin/bash
set -ex

# Build omnibus package
. $HOME/.asdf/asdf.sh
cd /vagrant
cd omnibus
sudo mkdir -p /opt/firezone
sudo chown -R ${USER} /opt/firezone
bin/omnibus build firezone
