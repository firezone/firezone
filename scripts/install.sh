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
os=`uname`
if [ ! $os = "Linux" ]; then
  echo "${os} unsupported. Only Linux is supported."
  exit -1
fi

# Exit if already installed
bin="$HOME/.cloudfire/bin/cloudfire"
if [ -f $bin ]; then
  echo "${bin} exists. Aborting. If you'd like to upgrade your installation run\
        cloudfire --upgrade"
  exit 0
fi

echo 'Initializing default configuration...'
if [ -f "init_config.sh" ]; then
  ./init_config.sh
else
  curl https://raw.githubusercontent.com/CloudFire-LLC/cloudfire/master/scripts/init_config.sh | bash -
fi

echo 'Downloading the latest release...'
mkdir -p $HOME/.cloudfire/bin
curl https://github.com/CloudFire-LLC/cloudfire/releases/download/latest/cloudfire_amd64 > $HOME/.cloudfire/bin/cloudfire

echo 'Setting Linux capabilities on the binary... sudo is required'
sudo bash -c 'setcap "cap_net_admin,cap_net_raw,cap_dac_read_search" $HOME/.cloudfire/bin/cloudfire'
