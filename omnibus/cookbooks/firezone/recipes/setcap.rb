# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: setcap
#
# Copyright:: 2021, FireZone, All Rights Reserved.

# Set capabilities for executables so they can be run without
# root privileges.

include_recipe 'firezone::config'

execute 'setcap_nft' do
  nft_path = "#{node['firezone']['install_directory']}/embedded/sbin/nft"
  command "setcap 'cap_net_admin,cap_net_raw+eip' #{nft_path}"
end

execute 'setcap_wg' do
  wg_path = "#{node['firezone']['install_directory']}/embedded/bin/wg"
  command "setcap 'cap_net_admin,cap_net_raw,cap_dac_read_search+eip' #{wg_path}"
end
