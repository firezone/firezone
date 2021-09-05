# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: network
#
# Copyright:: 2021, FireZone, All Rights Reserved.

# Set up wireguard interface, default routes, and firewall
# rules so that FireZone can run without a hitch.
#
# This recipe basically performs the work of wg-quick without having to
# have a configuration file.

include_recipe 'firezone::config'

require 'mixlib/shellout'

wg_path = "#{node['firezone']['install_directory']}/embedded/bin/wg"
nft_path = "#{node['firezone']['install_directory']}/embedded/sbin/nft"
awk_path = "#{node['firezone']['install_directory']}/embedded/bin/awk"
wg_interface = node['firezone']['wireguard']['interface_name']
private_key_path = "#{node['firezone']['var_directory']}/cache/wg_private_key"

egress_cmd = Mixlib::ShellOut.new("route | grep '^default' | grep -o '[^ ]*$'")
egress_interface = egress_cmd.run_command.stdout.chomp

# Set default endpoint ip to default egress ip
egress_cmd = "ip address show dev #{egress_interface} | grep 'inet ' | #{awk_path} '{print $2}'"
egress_ip = Mixlib::ShellOut.new(egress_cmd)
egress_ip.run_command
node.default['firezone']['wireguard']['endpoint_ip'] =
  egress_ip.stdout.chomp.gsub(%r{/.*}, '')

# Create wireguard interface if missing
wg_exists = Mixlib::ShellOut.new("ip link show dev #{wg_interface}")
wg_exists.run_command
if wg_exists.status.exitstatus == 1
  execute 'create_wireguard_interface' do
    command "ip link add #{wg_interface} type wireguard"
  end
end

execute 'setup_wireguard_ip' do
  # XXX: Make this configurable
  if_addr = '10.3.2.254/24'
  command "ip address replace #{if_addr} dev #{wg_interface}"
end

file 'write_private_key_file' do
  path private_key_path
  owner 'root'
  group 'root'
  mode '0600'
  content node['firezone']['wireguard_private_key']
  action :create_if_missing
end

execute 'set_wireguard_interface_private_key' do
  command "#{wg_path} set #{wg_interface} private-key #{private_key_path}"
end

execute 'set_listen_port' do
  listen_port = node['firezone']['wireguard']['port']
  command "#{wg_path} set #{wg_interface} listen-port #{listen_port}"
end

execute 'set_mtu' do
  command "ip link set mtu 1420 up dev #{wg_interface}"
end

route '10.3.2.0/24' do
  # XXX: Make this configurable
  device wg_interface
end

# XXX: Idempotent?
execute 'setup_firezone_firewall_table' do
  command "#{nft_path} add table inet firezone"
end

# XXX: Idempotent?
execute 'setup_firezone_forwarding_chain' do
  command "#{nft_path} 'add chain inet firezone forward { type filter hook forward priority 0 ; }'"
end

# XXX: Idempotent?
execute 'setup_firezone_postrouting_chain' do
  command "#{nft_path} 'add chain inet firezone postrouting { type nat hook postrouting priority 100 ; }'"
end

# XXX: Idempotent?
execute 'enable_packet_counters' do
  command "#{nft_path} add rule inet firezone forward counter accept"
end

# XXX: Idempotent?
execute 'enable_masquerading' do
  command "#{nft_path} add rule inet firezone postrouting oifname \"#{egress_interface}\" masquerade random,persistent"
end
