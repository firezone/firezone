# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2022, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

disable_telemetry_path = "#{node['firezone']['install_directory']}/.disable-telemetry"

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
end

unless /[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}/.match?(node['firezone']['telemetry_id'].to_s)
  node.normal['firezone']['telemetry_id'] = SecureRandom.uuid()
end
