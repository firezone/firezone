# frozen_string_literal: true

require "securerandom"

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2022, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

disable_telemetry_path = "#{node['firezone']['install_directory']}/.disable-telemetry"
telemetry_id =
  if /[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}/.match?(node['firezone']['telemetry_id'].to_s)
    # already generated
    node["firezone"]["telemetry_id"]
  else
    SecureRandom.uuid
  end
node.consume_attributes("firezone" => { "telemetry_id" => telemetry_id })

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
