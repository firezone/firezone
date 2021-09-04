#!/bin/bash
set -ex

# Build omnibus package
cd /vagrant/omnibus
sudo mkdir -p /opt/firezone
sudo chown -R ${USER} /opt/firezone
bin/omnibus build firezone
