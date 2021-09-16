#!/bin/bash
set -x

cd /vagrant/omnibus

which rpm
if [ $? -eq 0 ]; then
  sudo rpm -i pkg/firezone*.rpm
else
  sudo dpkg -i pkg/firezone*.deb
fi

sudo firezone-ctl reconfigure

# Usually fails the first time
sudo firezone-ctl restart

echo "Trying to load homepage"
curl -i -vvv -k https://$(hostname)
