#!/bin/sh
set -ex

sudo apt-get remove -y --purge firezone || true
sudo yum remove -y firezone || true

sudo rm -rf \
  /var/opt/firezone \
  /var/log/firezone \
  /etc/firezone \
  /usr/bin/firezone-ctl \
  /opt/firezone
