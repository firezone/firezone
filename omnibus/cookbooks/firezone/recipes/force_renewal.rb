# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: force_renewal
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Force certificate to renew now even if it hasn't expired.

include_recipe 'firezone::config'

require 'mixlib/shellout'

server = node['firezone']['ssl']['acme']['server']
keylength = node['firezone']['ssl']['acme']['keylength']
bin_path = "#{node['firezone']['install_directory']}/embedded/bin"
acme_home = "#{node['firezone']['var_directory']}/#{server}/#{keylength}/acme"

# Remove cronjob (if cronjob doesn't exist no harm is done)
execute 'ACME force cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --cron \
    --force \
    --home #{acme_home}
  ACME
end
