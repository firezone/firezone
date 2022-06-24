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
Address = 10.3.2.1/32
PrivateKey = $(cat /config/server/privatekey-server)
PostUp = iptables -A FORWARD -i wg-firezone -j ACCEPT; iptables -A FORWARD -o wg-firezone -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-firezone -j ACCEPT; iptables -D FORWARD -o wg-firezone -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
END

wg-quick up /config/wg-firezone.conf

mix start
