# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: network_service
#
# Copyright:: 2021, FireZone, All Rights Reserved.

include_recipe 'firezone::config'
include_recipe 'enterprise::runit'

directory node['firezone']['network_service']['log_directory'] do
  # These logs could contain sensitive information
  owner 'root'
  group 'root'
  mode '0700'
  recursive true
end

component_runit_service 'network_service' do
  package 'firezone'
  action :enable
end
