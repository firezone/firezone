#!/bin/bash
set -ex

which rpm
if [ $? -eq 0 ]; then
  sudo rpm -i pkg/firezone*.rpm
else
  sudo dpkg -i pkg/firezone*.deb
fi

# Usually fails the first time
sudo firezone-ctl reconfigure || true
sudo firezone-ctl restart
