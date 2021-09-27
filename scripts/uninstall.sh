#!/bin/sh

echo 'Removing all Firezone configuration data...'
firezone-ctl cleanse yes

apt=`which apt-get`
yum=`which yum`

echo 'Removing firezone package...'
if [ -f $apt ]; then
  apt-get remove -y --purge firezone
elif [ -f $yum ]; then
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
