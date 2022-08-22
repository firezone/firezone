# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: phoenix
#
# Copyright:: 2014 Chef Software, Inc.
# Copyright:: 2021 Firezone
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Common configuration for Phoenix

include_recipe 'firezone::config'
include_recipe 'firezone::nginx'
include_recipe 'firezone::acme'
include_recipe 'firezone::ssl'
include_recipe 'firezone::wireguard'

[node['firezone']['phoenix']['log_directory'],
 "#{node['firezone']['var_directory']}/phoenix/run"].each do |dir|
  directory dir do
    owner node['firezone']['user']
    group node['firezone']['group']
    mode '0700'
    recursive true
  end
end

acme_cert = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.fullchain"
acme_key = "#{node['firezone']['var_directory']}/ssl/acme/#{fqdn}.key"
host = URI.parse(node['firezone']['external_url']).host

if node['firezone']['ssl']['acme']['enabled']
  # Generate a temporary cert until ACME issues one
  openssl_x509_certificate acme_cert do
    common_name host
    org node['firezone']['ssl']['company_name']
    org_unit node['firezone']['ssl']['organizational_unit_name']
    country node['firezone']['ssl']['country_name']
    key_length 2048
    expire 3650
    owner 'root'
    group 'root'
    mode '0644'
  end
end

template 'phoenix.nginx.conf' do
  fqdn = URI.parse(node['firezone']['external_url']).host
  path "#{node['firezone']['nginx']['directory']}/sites-enabled/phoenix"
  source 'phoenix.nginx.conf.erb'
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
  variables(nginx: node['firezone']['nginx'],
            logging_enabled: node['firezone']['logging']['enabled'],
            phoenix: node['firezone']['phoenix'],
            fqdn: fqdn,
            fips_enabled: node['firezone']['fips_enabled'],
            ssl: node['firezone']['ssl'],
            app_directory: node['firezone']['app_directory'],
            acme: {
              'enabled' => node['firezone']['ssl']['acme']['enabled'],
              'certificate' => acme_cert,
              'certificate_key' => acme_key
            })
end

if node['firezone']['phoenix']['enabled']
  component_runit_service 'phoenix' do
    runit_attributes(
      env: Firezone::Config.app_env(node),
      finish: true
    )
    package 'firezone'
    control ['t']
    action :enable
    subscribes :restart, 'file[environment-variables]'
    subscribes :restart, 'file[disable-telemetry]'
  end
else
  runit_service 'phoenix' do
    action :disable
  end
end
