#!/bin/bash
set -x

# This script should be run from the app root

if type rpm > /dev/null; then
  sudo rpm -i omnibus/pkg/firezone*.rpm
elif type dpkg > /dev/null; then
  sudo dpkg -i omnibus/pkg/firezone*.deb
else
  echo 'Neither rpm nor dpkg found'
  exit 1
fi

sudo firezone-ctl reconfigure

# Wait for app to fully boot
sleep 10

# Helpful for debugging
sudo cat /var/log/firezone/**/*

echo "Trying to load homepage"
page=$(curl -L -i -vvv -k https://$(hostname))
echo $page

echo "Testing for sign in button"
echo $page | grep "Sign in"
