#!/bin/bash
set -ex
# This script should be run from the app root

# Disable telemetry
sudo mkdir -p /opt/firezone/
sudo touch /opt/firezone/.disable-telemetry

if type rpm > /dev/null; then
  sudo -E rpm -i omnibus/pkg/firezone*.rpm
elif type dpkg > /dev/null; then
  sudo -E dpkg -i omnibus/pkg/firezone*.deb
else
  echo 'Neither rpm nor dpkg found'
  exit 1
fi

# Fixes setcap not found on centos 7
PATH=/usr/sbin/:$PATH

# Disable connectivity checks
conf="/opt/firezone/embedded/cookbooks/firezone/attributes/default.rb"
search="default\['firezone']\['connectivity_checks']\['enabled'] = true"
replace="default['firezone']['connectivity_checks']['enabled'] = false"
sudo -E sed -i "s/$search/$replace/" $conf

# Disable telemetry
search="default\['firezone']\['telemetry']\['enabled'] = true"
search="default['firezone']['telemetry']['enabled'] = false"
sudo -E sed -i "s/$search/$replace/" $conf

# Bootstrap config
sudo -E firezone-ctl reconfigure

# Wait for app to fully boot
sleep 5

# Helpful for debugging
sudo cat /var/log/firezone/nginx/current
sudo cat /var/log/firezone/postgresql/current
sudo cat /var/log/firezone/phoenix/current
sudo cat /var/log/firezone/wireguard/current

# Create admin; requires application to be up
sudo -E firezone-ctl create-or-reset-admin

# XXX: Add more commands here to test

echo "Trying to load homepage"
page=$(curl -L -i -vvv -k https://localhost)
echo $page

echo "Testing for sign in button"
echo $page | grep '<a class="button" href="/auth/identity">Sign in with email</a>'

echo "Testing telemetry_id survives reconfigures"
tid1=`sudo cat /var/opt/firezone/cache/telemetry_id`
sudo firezone-ctl reconfigure
tid2=`sudo cat /var/opt/firezone/cache/telemetry_id`

if [ "$tid1" = "$tid2" ]; then
  echo "telemetry_ids match!"
else
  echo "telemetry_ids differ:"
  echo $tid1
  echo $tid2
  exit 1
fi

echo "Testing FzVpn.Interface module works with WireGuard"
fz_bin="/opt/firezone/embedded/service/firezone/bin/firezone"
ok_res=":ok"
set_interface=`sudo $fz_bin rpc "IO.inspect(FzVpn.Interface.set(\"wg-fz-test\", %{}))"`
del_interface=`sudo $fz_bin rpc "IO.inspect(FzVpn.Interface.delete(\"wg-fz-test\"))"`

if [[ "$set_interface" != $ok_res || "$del_interface" != $ok_res ]]; then
    echo "WireGuard test failed!"
    exit 1
fi

echo "Testing Firewall Rules"
fz_bin="/opt/firezone/embedded/service/firezone/bin/firezone"
nft_bin="/opt/firezone/embedded/sbin/nft"
ok_res=":ok"
user_id="5" # Picking a high enough user_id so there is no overlap
device="%{ip: \"10.0.0.1\", ip6: \"fd00::3:2:1\", user_id: $user_id}"
rule="%{destination: \"10.0.0.2\", user_id: $user_id, action: :drop, port_type: nil, port_range: nil}"
add_user=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_user($user_id))"`
add_device=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_device($device))"`
add_rule=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.add_rule($rule))"`
del_rule=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_rule($rule))"`
del_device=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_device($device))"`
del_user=`$fz_bin rpc "IO.inspect(FzWall.CLI.Live.delete_user($user_id))"`

if [[ "$add_user" != $ok_res || "$add_device" != $ok_res || "$add_rule" != $ok_res || "$del_rule" != $ok_res || "$del_device" != $ok_res || "$del_user" != $ok_res ]]; then
    echo "Firewall test failed!"
    exit 1
fi
