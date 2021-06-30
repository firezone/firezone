#!/usr/bin/env bash
set -e

echo "Setting capabilities"
sudo setcap "cap_net_admin,cap_net_raw,cap_dac_read_search+ep" cloudfire
mkdir $HOME/.cache
chmod +x cloudfire

echo "Initializing default config..."
curl https://raw.githubusercontent.com/CloudFire-LLC/cloudfire/${GITHUB_SHA}/scripts/init_config.sh | bash -

# Create DB
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
sudo -E -i -u postgres psql -h localhost -c "CREATE DATABASE cloudfire;"

# Start by running migrations always
./cloudfire eval "CfHttp.Release.migrate"

# Start in the background
./cloudfire &

# Wait for app to start
sleep 5

echo "Trying to load homepage..."
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit
