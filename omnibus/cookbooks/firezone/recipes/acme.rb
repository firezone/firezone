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

# Remove cronjob to make sure it's correctly re-created
# and remove even if acme is disabled.
execute 'ACME remove cronjob' do
  command <<~ACME
    #{bin_path}/acme.sh --uninstall-cronjob
  ACME
end

# Enable ACME if set to enabled and user-specified certs are disabled, maintains
# backwards compatibility during upgrades.
if node['firezone']['ssl']['acme'] && !node['firezone']['ssl']['certificate'] &&
   node['firezone']['ssl']['enabled']

  server = node['firezone']['ssl']['acme_server']
  # We include the server in acme's home to force it to re-generate
  acme_home = "#{node['firezone']['var_directory']}/#{server}/acme"
  fqdn = URI.parse(node['firezone']['external_url']).host
  certfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.cert"
  keyfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.key"
  fullchainfile = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.fullchain"

  directory acme_home do
    mode '0770'
    owner 'root'
    group 'root'
    recursive true
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

  execute 'ACME registration' do
    command <<~ACME
      #{bin_path}/acme.sh --register-account \
      --home #{acme_home} \
      --server #{server} \
      --debug \
      -m #{node['firezone']['ssl']['email_address']}
    ACME
  end

  execute 'ACME issue' do
    # Command returns 0: Cert was issued
    # Command returns 2: Skipping because renewal isn't needed
    returns [0, 2]
    command <<~ACME
      #{bin_path}/acme.sh --issue \
        --home #{acme_home} \
        --server #{server} \
        --debug \
        -d #{URI.parse(node['firezone']['external_url']).host} \
        -w #{node['firezone']['var_directory']}/nginx/acme_root
    ACME
  end

  execute 'ACME install-cert' do
    command <<~ACME
      #{bin_path}/acme.sh --install-cert \
        --home #{acme_home} \
        --debug \
        -d #{fqdn} \
        --cert-file "#{certfile}" \
        --key-file "#{keyfile}" \
        --server #{server} \
        --fullchain-file "#{fullchainfile}" \
        --reloadcmd "firezone-ctl hup nginx"
    ACME
  end

  # TODO: Set notifications
end
