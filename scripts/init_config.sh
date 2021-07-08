#!/usr/bin/env bash
set -e

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
db_encryption_key="$(openssl rand -base64 32)"
wg_server_key="$(wg genkey)"
config="$HOME/.cloudfire/config.json"
touch  $config
chmod 0600 $config
cat <<EOT >> $config
{
  "database_url": "ecto://postgres:postgres@127.0.0.1/cloudfire",
  "secret_key_base": "${secret_key_base}",
  "live_view_signing_salt": "${live_view_signing_salt}",
  "db_encryption_key": "${db_encryption_key}",
  "ssl_cert_file": "${HOME}/.cloudfire/ssl/cert.pem",
  "ssl_key_file": "${HOME}/.cloudfire/ssl/key.pem",
  "url_host": "${hostname}",
  "wg_server_key": "$(wg genkey)"
}
EOT
