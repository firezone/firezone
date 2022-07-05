# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: acme
#
# Copyright:: 2022, Firezone, All Rights Reserved.

include_recipe 'firezone::config'

bin_path = "#{node['firezone']['install_directory']}/embedded/bin"

file "#{bin_path}/acme.sh" do
  mode '0770'
  owner 'root'
  group 'root'
end

# Enable ACME if set to enabled and user-specified certs are disabled, maintains
# backwards compatibility during upgrades.
if node['firezone']['ssl']['acme'] && !node['firezone']['ssl']['certificate']
  acme_home = "#{node['firezone']['var_directory']}/acme"
  fqdn = URI.parse(node['firezone']['external_url']).host
  certfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.cert"
  keyfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.key"
  fullchainfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.fullchain"

  directory acme_home do
    mode '0770'
    owner 'root'
    group 'root'
  end

  execute 'ACME initialization' do
    # Need to cwd to bin_path because ACME expects to copy itself
    cwd bin_path
    command <<~ACME
      ./acme.sh --install \
      --debug \
      --home #{acme_home} \
      --accountemail "#{node['firezone']['ssl']['email_address']}"
    ACME
  end

  unless File.exist?("#{acme_home}/account.conf")
    execute 'ACME registration' do
      command <<~ACME
        #{bin_path}/acme.sh --register-account \
        --home #{acme_home} \
        --server #{node['firezone']['ssl']['acme_server']} \
        --debug \
        -m #{node['firezone']['ssl']['email_address']}
      ACME
    end
  end

  unless File.exist?(certfile)
    execute 'ACME first-time issue' do
      command <<~ACME
        #{bin_path}/acme.sh --issue \
          --home #{acme_home} \
          --server #{node['firezone']['ssl']['acme_server']} \
          --debug \
          -d #{URI.parse(node['firezone']['external_url']).host} \
          -w #{node['firezone']['var_directory']}/nginx/acme_root
      ACME
    end
  end

  execute 'ACME install-cert' do
    command <<~ACME
      #{bin_path}/acme.sh --install-cert \
        --home #{acme_home} \
        --debug \
        -d #{fqdn} \
        --cert-file "#{certfile}" \
        --key-file "#{keyfile}" \
        --server #{node['firezone']['ssl']['acme_server']} \
        --fullchain-file "#{fullchainfile}" \
        --reloadcmd "firezone-ctl hup nginx"
    ACME
  end

  # TODO: Set notifications
end
