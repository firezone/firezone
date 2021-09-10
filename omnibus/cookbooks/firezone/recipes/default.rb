# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: default
#
# Copyright:: 2021, FireZone, All Rights Reserved.

include_recipe "firezone::config"
include_recipe "firezone::setcap"
include_recipe "firezone::log_management"
include_recipe "firezone::ssl"
include_recipe "firezone::network_service"
include_recipe "firezone::postgresql"
include_recipe "firezone::nginx"
include_recipe "firezone::database"
include_recipe "firezone::app"

# Write out a firezone-running.json at the end of the run
file "#{node['firezone']['config_directory']}/firezone-running.json" do
  content Chef::JSONCompat.to_json_pretty('firezone' => node['firezone'])
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end
