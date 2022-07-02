# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: acme
#
# Copyright:: 2022, Firezone, All Rights Reserved.

include_recipe 'firezone::config'
include_recipe 'firezone::ssl'

acme_sh_path = "#{node['firezone']['install_directory']}/embedded/bin/acme.sh"

file acme_sh_path do
  mode '0700'
  owner 'root'
  group 'root'
end

# Enable ACME if set to enabled and user-specified certs are disabled, maintains
# backwards compatibility during upgrades.
if node['firezone']['ssl']['acme'] \
    && !node['firezone']['ssl']['certificate'] \
    && !node['firezone']['ssl']['certificate_key']

  acme_home = "#{node['firezone']['var_directory']}/acme"

  directory acme_home do
    mode '0750'
    owner 'root'
    group node['firezone']['group']
  end

  execute 'ACME initialization' do
    command <<~ACME
      #{acme_sh_path} --install \
      --home #{acme_home}
      --accountemail "#{node['firezone']['admin_email']}"
    ACME
  end

  execute 'ACME issue' do
    command <<~ACME
      #{acme_sh_path} --issue \
        -d #{URI.parse(node['firezone']['external_url']).host} \
        -w #{node['firezone']['var_directory']}/nginx/acme_root
    ACME
  end

  execute 'ACME install-cert' do
    fqdn = URI.parse(node['firezone']['external_url']).host
    command <<~ACME
      #{acme_sh_path} --install-cert \
        -d #{fqdn} \
        --cert-file "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.cert" \
        --key-file "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.key" \
        --fullchain-file "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.fullchain" \
        --reloadcmd "firezone-ctl hup nginx"
    ACME
  end
end
