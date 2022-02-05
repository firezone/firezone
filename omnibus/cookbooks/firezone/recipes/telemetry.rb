# frozen_string_literal: true

require "securerandom"

# Cookbook:: firezone
# Recipe:: telemetry
#
# Copyright:: 2022, Firezone, All Rights Reserved.

# Configure telemetry app-wide.

include_recipe 'firezone::config'

disable_telemetry_path = "#{node['firezone']['install_directory']}/.disable-telemetry"
telemetry_id_path = "#{node['firezone']['var_directory']}/cache/telemetry_id"
telemetry_id =
  if /[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}/.match?(node['firezone']['telemetry_id'].to_s)
    # already generated
    node["firezone"]["telemetry_id"]
  else
    SecureRandom.uuid
  end

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

file "telemetry-id" do
  path telemetry_id_path
  owner node["firezone"]["user"]
  group node["firezone"]["group"]
  mode "0440"
  content telemetry_id
  action :create_if_missing
end
node.default["firezone"]["telemetry_id"] = File.read(telemetry_id_path)
