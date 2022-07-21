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
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  apt-get -qqy update
elif type yum > /dev/null; then
  yum remove -y firezone
  rm /etc/yum.repos.d/firezone-firezone.repo
  # some distros (eg, CentOS 7) do not include this repo file
  # silence if it can't be found for removal
  rm /etc/yum.repos.d/firezone-firezone-source.repo 2> /dev/null
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

if tput bold; then
  bold=$(tput bold)
else
  bold=''
fi
if tput sgr0; then
  normal=$(tput sgr0)
else
  normal=''
fi

echo $bold
echo 'We rely on feedback from users to steer development.' \
  'Would you mind taking a minute to share product feedback in exchange' \
  'for some Firezone stickers?'
echo "https://firezone.dev/feedback#source=uninstall-script"
echo $normal
