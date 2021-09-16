#!/bin/bash
set -x

# This script should be run from the app root

which rpm
if [ $? -eq 0 ]; then
  sudo rpm -i omnibus/pkg/firezone*.rpm
else
  sudo dpkg -i omnibus/pkg/firezone*.deb
fi

sudo firezone-ctl reconfigure

# Usually fails the first time
sudo firezone-ctl restart

echo "Trying to load homepage"
curl -i -vvv -k https://$(hostname)
