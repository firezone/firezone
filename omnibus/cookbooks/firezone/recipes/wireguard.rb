# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: wireguard
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Sets up service to manage WireGuard interface

include_recipe "firezone::config"

directory node["firezone"]["wireguard"]["log_directory"] do
  owner node["firezone"]["user"]
  group node["firezone"]["group"]
  mode "0700"
  recursive true
end

if node["firezone"]["wireguard"]["enabled"]
  component_runit_service "wireguard" do
    package "firezone"
    action :enable
    subscribes :restart, "template[sv-wireguard-run]"
  end
else
  runit_service "wireguard" do
    action :disable
  end
end
