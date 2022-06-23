#!/bin/bash

set -xe

rm -rf /etc/wireguard
mkdir -p /etc/wireguard
ln -s /config/wg-firezone.conf /etc/wireguard/wg-firezone.conf

mkdir -p /config/server
if [ ! -f /config/server/privatekey-server ]; then
  umask 077
  wg genkey | tee /config/server/privatekey-server | wg pubkey > /config/server/publickey-server
fi

cat <<END > /config/wg-firezone.conf
[Interface]
ListenPort = 51820
PrivateKey = $(cat /config/server/privatekey-server)
END

mix start
