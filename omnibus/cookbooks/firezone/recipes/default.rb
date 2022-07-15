# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: default
#
# Copyright:: 2021, Firezone, All Rights Reserved.

include_recipe 'firezone::config'
include_recipe 'firezone::log_management'
include_recipe 'firezone::ssl'
include_recipe 'firezone::network'
include_recipe 'firezone::postgresql'
include_recipe 'firezone::nginx'
include_recipe 'firezone::acme'
include_recipe 'firezone::database'
include_recipe 'firezone::setcap'
include_recipe 'firezone::app'
include_recipe 'firezone::telemetry'

running_config = "#{node['firezone']['config_directory']}/firezone-running.json"
old_interface = Chef::JSONCompat.from_json(File.open(running_config).read)['firezone']['wireguard']['interface_name']

# Write out a firezone-running.json at the end of the run
file running_config do
  content Chef::JSONCompat.to_json_pretty('firezone' => node['firezone'])
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end

file "#{node['firezone']['var_directory']}/.license.accepted" do
  content ''
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end

# Run at the end to try to minimize VPN disruption.
execute 'handle_interface_change' do
  only_if (old_interface != node['firezone']['wireguard']['interface_name']).to_s
  command "ip link del dev #{old_interface}"
end
