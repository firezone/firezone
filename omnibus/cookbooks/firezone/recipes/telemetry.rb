# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2022, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

disable_telemetry_path = "#{node['firezone']['install_directory']}/.disable-telemetry"
telemetry_id_path = "#{node['firezone']['install_directory']}/.telemetry-id"

file 'telemetry_id' do
  action :create_if_missing
  path telemetry_id_path
  mode '0644'
  user node['firezone']['user']
  group node['firezone']['group']
  content SecureRandom.uuid()
end

if node['firezone']['telemetry']['enabled'] == false
  file 'disable_telemetry' do
    path disable_telemetry_path
    mode '0644'
    user node['firezone']['user']
    group node['firezone']['group']
  end
  node['firezone']['telemetry_id'] = nil
else
  file 'disable_telemetry' do
    path disable_telemetry_path
    action :delete
  end
  node['firezone']['telemetry_id'] = File.read(telemetry_id_path)
end
