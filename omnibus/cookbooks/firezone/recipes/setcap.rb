# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: setcap
#
# Copyright:: 2021, FireZone, All Rights Reserved.

# Set capabilities for executables so they can be run without
# root privileges.

include_recipe 'firezone::config'

nft_path = "#{node['firezone']['install_directory']}/embedded/sbin/nft"
wg_path = "#{node['firezone']['install_directory']}/embedded/bin/wg"

file nft_path do
  # Ensure phoenix app can control nftables
  mode '0700'
  owner node['firezone']['user']
  group node['firezone']['group']
end

file wg_path do
  # Ensure phoenix app can control WireGuard interface
  mode '0700'
  owner node['firezone']['user']
  group node['firezone']['group']
end

# setcap must be performed after the file resource above otherwise
# it gets reset
execute 'setcap_nft' do
  command "setcap 'cap_net_admin,cap_net_raw+eip' #{nft_path}"
end

execute 'setcap_wg' do
  command "setcap 'cap_net_admin,cap_net_raw,cap_dac_read_search+eip' #{wg_path}"
end
