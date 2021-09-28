#!/bin/sh

echo 'Removing all Firezone configuration data...'
firezone-ctl cleanse yes

echo 'Removing firezone package...'
if type apt-get > /dev/null; then
  apt-get remove -y --purge firezone
elif type yum > /dev/null; then
  yum remove -y firezone
else
  echo 'apt-get or yum not found'
  exit 1
fi

echo 'Removing remaining directories...'
rm -rf \
  /var/opt/firezone \
  /var/log/firezone \
  /etc/firezone \
  /usr/bin/firezone-ctl \
  /opt/firezone

echo 'Done! Firezone has been uninstalled.'
