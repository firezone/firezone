# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2022, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

disable_telemetry_path = "#{node['firezone']['var_directory']}/.disable_telemetry"

if node['firezone']['telemetry']['enabled'] == false
  file 'disable_telemetry' do
    path disable_telemetry_path
    mode '0644'
    user node['firezone']['user']
    group node['firezone']['group']
  end
else
  file 'disable_telemetry' do
    path disable_telemetry_path
    action :delete
  end
end

file 'telemetry-id' do
  path "#{node['firezone']['var_directory']}/cache/telemetry_id"
  mode '0440'
  owner node['firezone']['user']
  group node['firezone']['group']
  content node['firezone']['telemetry_id']
end
