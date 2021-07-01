#!/usr/bin/env bash
set -e

echo "Setting capabilities"
chmod +x cloudfire
sudo setcap "cap_net_admin,cap_net_raw,cap_dac_read_search+i" `which ip`
sudo setcap "cap_net_admin,cap_net_raw,cap_dac_read_search+ep" cloudfire

echo "Capabilities:"
sudo getcap cloudfire

mkdir $HOME/.cache

echo "Initializing default config..."
curl https://raw.githubusercontent.com/CloudFire-LLC/cloudfire/${GITHUB_SHA}/scripts/init_config.sh | bash -

# Create DB
export PGPASSWORD=postgres # used by psql
sudo -E -u postgres psql -d postgres -h localhost -c "CREATE DATABASE cloudfire;"

# Start by running migrations always
./cloudfire eval "CfHttp.Release.migrate"

# Start in the background
./cloudfire &

# Wait for app to start
sleep 10

echo "Trying to load homepage..."
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit
