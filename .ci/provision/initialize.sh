#!/bin/bash
set -x

cd /vagrant/omnibus

which rpm
if [ $? -eq 0 ]; then
  sudo rpm -i pkg/firezone*.rpm
else
  sudo dpkg -i pkg/firezone*.deb
fi

# Usually fails the first time
sudo firezone-ctl reconfigure
sudo firezone-ctl restart
