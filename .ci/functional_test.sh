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

# Wait for phoenix app to boot
sleep 5

echo "Trying to load homepage"
page=$(curl -i -vvv -k https://$(hostname))
echo $page

echo "Testing for sign in button"
echo $page | grep "Sign in"
