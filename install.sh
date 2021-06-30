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

echo 'Downloading the latest release...'
mkdir -p $HOME/.cloudfire/bin
curl https://github.com/CloudFire-LLC/cloudfire/releases/download/latest/cloudfire_amd64 > $HOME/.cloudfire/bin/cloudfire

echo 'Setting Linux capabilities on the binary... sudo is required'
sudo bash -c 'setcap "cap_net_admin,cap_net_raw,cap_dac_read_search" $HOME/.cloudfire/bin/cloudfire'

echo 'Initializing default configuration...'
mkdir -p $HOME/.cloudfire/ssl
hostname=$(hostname)
openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
    -keyout $HOME/.cloudfire/ssl/key.pem \
    -out $HOME/.cloudfire/ssl/cert.pem \
    -days 365 -subj "/CN=${hostname}"
chmod 0600 $HOME/.cloudfire/ssl/key.pem
chmod 0644 $HOME/.cloudfire/ssl/cert.pem
secret_key_base="$(openssl rand -base64 48)"
live_view_signing_salt="$(openssl rand -base64 24)"
db_key="$(openssl rand -base64 32)"
wg_server_key="$(wg genkey)"
echo "{
  \"database_url\": \"ecto://postgres:postgres@127.0.0.1/cloudfire\",
  \"secret_key_base\": \"${secret_key_base}\",
  \"live_view_signing_salt\": \"${live_view_signing_salt}\",
  \"db_key\": \"${db_key}\",
  \"ssl_cert_file\": \"${$HOME}/.cloudfire/ssl/cert.pem\",
  \"ssl_key_file\": \"${HOME}/.cloudfire/ssl/key.pem\",
  \"url_host\": \"${hostname}\",
  \"wg_server_key\": \"$(wg genkey)\"
}" > $HOME/.cloudfire/config.json
chmod 0600 $HOME/.cloudfire/config.json
