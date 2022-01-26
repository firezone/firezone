# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

telemetry_disable = "#{node['firezone']['install_directory']}/.disable-telemetry"

if node['firezone']['telemetry']['enabled'] == false
  file telemetry_disable do
    mode '0755'
    user node['firezone']['user']
    group node['firezone']['group']
  end
else
  file telemetry_disable do
    action :delete
  end
end
