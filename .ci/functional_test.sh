#!/bin/bash
set -ex
# This script should be run from the app root

# Disable telemetry
sudo mkdir -p /opt/firezone/
sudo touch /opt/firezone/.disable-telemetry

if type rpm > /dev/null; then
  sudo -E rpm -i omnibus/pkg/firezone*.rpm
elif type dpkg > /dev/null; then
  sudo -E dpkg -i omnibus/pkg/firezone*.deb
else
  echo 'Neither rpm nor dpkg found'
  exit 1
fi

# Fixes setcap not found on centos 7
PATH=/usr/sbin/:$PATH

sudo -E firezone-ctl reconfigure
sudo -E bash -c "echo \"default['firezone']['connectivity_checks']['enabled'] = false\" >> /etc/firezone/firezone.rb"
sudo -E firezone-ctl reconfigure

sudo -E firezone-ctl create-or-reset-admin

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


echo "Testing telemetry_id survives reconfigures"
tid1=`sudo cat /var/opt/firezone/cache/telemetry_id`
sudo firezone-ctl reconfigure
tid2=`sudo cat /var/opt/firezone/cache/telemetry_id`

if [ "$tid1" = "$tid2" ]; then
  echo "telemetry_ids match!"
else
  echo "telemetry_ids differ:"
  echo $tid1
  echo $tid2
  exit 1
fi
