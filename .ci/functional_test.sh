#!/bin/bash
set -ex

export TELEMETRY_ENABLED=false

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
sudo firezone-ctl create-or-reset-admin

# XXX: Add more commands here to test

# Wait for app to fully boot
sleep 10

# Helpful for debugging
sudo cat /var/log/firezone/nginx/current
sudo cat /var/log/firezone/postgresql/current
sudo cat /var/log/firezone/phoenix/current

echo "Trying to load homepage"
page=$(curl -L -i -vvv -k https://localhost)
echo $page

echo "Testing for sign in button"
echo $page | grep '<button class="button" type="submit">Sign In</button>'
