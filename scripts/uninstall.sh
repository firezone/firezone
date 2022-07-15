#!/bin/sh

echo 'Removing Firezone network settings...'
firezone-ctl teardown-network

echo 'Removing all Firezone directories...'
firezone-ctl cleanse yes

echo 'Stopping ACME from renewing certificates...'
firezone-ctl stop-cert-renewal

echo 'Removing firezone package...'
if type apt-get > /dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge firezone
  rm /etc/apt/sources.list.d/firezone-firezone.list
  apt-get autoclean
  rm -rf /var/lib/apt/lists/*
  apt-get update -qy
elif type yum > /dev/null; then
  yum remove -y firezone
  rm /etc/yum.repos.d/firezone-firezone.repo
  rm /etc/yum.repos.d/firezone-firezone-source.repo
elif type zypper > /dev/null; then
  zypper --non-interactive remove -y -u firezone
  zypper --non-interactive rr firezone-firezone
  zypper --non-interactive rr firezone-firezone-source
else
  echo 'Warning: package management tool not found; not '\
    'removing installed package. This can happen if your'\
    ' package management tool (e.g. yum, apt, etc) is no'\
    't in your $PATH. Continuing...'
fi

echo 'Removing remaining directories...'
rm -rf \
  /var/opt/firezone \
  /var/log/firezone \
  /etc/firezone \
  /usr/bin/firezone-ctl \
  /opt/firezone

echo 'Done! Firezone has been uninstalled.'
