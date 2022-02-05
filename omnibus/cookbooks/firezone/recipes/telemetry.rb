# frozen_string_literal: true

require "securerandom"

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

file "telemetry-id" do
  telemetry_id =
    if /[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}/.match?(node['firezone']['telemetry_id'].to_s)
      # already generated
      node["firezone"]["telemetry_id"]
    else
      SecureRandom.uuid
    end

  path "#{node['firezone']['var_directory']}/cache/telemetry_id"
  mode "0440"
  owner node["firezone"]["user"]
  group node["firezone"]["group"]
  content telemetry_id
  action :create_if_missing
end
