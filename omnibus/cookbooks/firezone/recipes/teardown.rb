# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: teardown
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Teardown all the network settings. Used during uninstall.

include_recipe 'firezone::config'

require 'mixlib/shellout'

wg_interface = node['firezone']['wireguard']['interface_name']
nft_path = "#{node['firezone']['install_directory']}/embedded/sbin/nft"
bin_path = "#{node['firezone']['install_directory']}/embedded/bin"

# Delete wireguard interface if exists
wg_exists = Mixlib::ShellOut.new("ip link show dev #{wg_interface}")
wg_exists.run_command
if wg_exists.status.exitstatus.zero?
  execute 'delete_wireguard_interface' do
    command "ip link delete dev #{wg_interface}"
  end
end

# Delete firewall table
table_exists_cmd = Mixlib::ShellOut.new("#{nft_path} list table inet firezone")
table_exists_cmd.run_command
if table_exists_cmd.status.exitstatus.zero?
  execute 'delete_firewall_table' do
    command "#{nft_path} delete table inet firezone"
  end
end

# Remove cronjob (if cronjob doesn't exist no harm is done)
execute 'ACME remove cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --uninstall-cronjob
  ACME
end
