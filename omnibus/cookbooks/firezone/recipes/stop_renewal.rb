# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: stop_renewal
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Removes cronjob renewing certificates. Used during uninstall.

include_recipe 'firezone::config'

require 'mixlib/shellout'

bin_path = "#{node['firezone']['install_directory']}/embedded/bin"

# Remove cronjob (if cronjob doesn't exist no harm is done)
execute 'ACME remove cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --uninstall-cronjob
  ACME
end
