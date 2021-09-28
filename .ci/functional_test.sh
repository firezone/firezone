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

# Wait for app to fully boot
sleep 10

# Helpful for debugging
sudo cat /var/log/firezone/phoenix/*

echo "Trying to load homepage"
page=$(curl -L -i -vvv -k https://$(hostname))
echo $page

echo "Testing for sign in button"
echo $page | grep "Sign in"
