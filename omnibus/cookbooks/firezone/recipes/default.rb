# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: default
#
# Copyright:: 2021, FireZone, All Rights Reserved.

include_recipe "firezone::config"
include_recipe "firezone::log_management"
include_recipe "firezone::ssl"
include_recipe "firezone::postgresql"
include_recipe "firezone::nginx"
include_recipe "firezone::database"
include_recipe "firezone::app"
