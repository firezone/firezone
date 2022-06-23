# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: setcap
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Set capabilities for executables so they can be run without
# root privileges.

include_recipe 'firezone::config'

nft_path = "#{node['firezone']['install_directory']}/embedded/sbin/nft"

file nft_path do
  # Ensure phoenix app can control nftables
  mode '0700'
  owner node['firezone']['user']
  group node['firezone']['group']
  action :touch
end

# setcap must be performed after the file resource above otherwise
# it gets reset
execute 'setcap_nft' do
  command "setcap 'cap_net_admin,cap_net_raw+eip' #{nft_path}"
end
