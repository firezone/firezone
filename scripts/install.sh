#!/usr/bin/env bash
set -e

# 1. Detect OS
# 2.
# 3. Download latest release
# 4. Set capabilities with sudo
# 5. Init config file
# 6. Display welcome message:
  # - Edit config to configure your DB access and SSL certs
  # - Add to PATH
  # - How to launch CloudFire
bin="$HOME/.cloudfire/bin/cloudfire"
os=`uname`
if [ ! $os = "Linux" ]; then
  echo "${os} unsupported. Only Linux is supported."
  exit -1
fi


# Exit if already installed
if [ -f $bin ]; then
  echo "${bin} exists. Aborting. If you'd like to upgrade your installation run\
        $bin --upgrade"
  exit 0
fi

echo 'Initializing default configuration...'
if [ -f "init_config.sh" ]; then
  ./init_config.sh
else
  curl https://raw.githubusercontent.com/CloudFire-LLC/cloudfire/master/scripts/init_config.sh | bash -
fi

echo 'Downloading the latest release...'
# XXX: Detect architecture and download appropriate binary
mkdir -p $HOME/.cloudfire/bin
curl https://github.com/CloudFire-LLC/cloudfire/releases/download/latest/cloudfire_amd64 > $bin

# Ambient capabilities handles this
# echo 'Setting Linux capabilities on the binary... sudo is required'
# sudo bash -c "setcap 'cap_net_admin,cap_net_raw,cap_dac_read_search' $bin"
