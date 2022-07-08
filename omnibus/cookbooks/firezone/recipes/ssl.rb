# frozen_string_literal: true

#
# Cookbook:: firezone
# Recipe:: ssl
#
# Copyright:: 2014 Chef Software, Inc.
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

include_recipe 'firezone::config'

[node['firezone']['ssl']['directory'],
 "#{node['firezone']['ssl']['directory']}/ca"].each do |dir|
  directory dir do
    owner node['firezone']['user']
    group node['firezone']['group']
    mode '0700'
  end
end

firezone_ca_dir = File.join(node['firezone']['ssl']['directory'], 'ca')
ssl_dhparam = File.join(firezone_ca_dir, 'dhparams.pem')

# Generate dhparams.pem for perfect forward secrecy
openssl_dhparam ssl_dhparam do
  key_length 2048
  generator 2
  owner 'root'
  group 'root'
  mode '0644'
end

node.default['firezone']['ssl']['ssl_dhparam'] ||= ssl_dhparam

if node['firezone']['ssl']['certificate']
  # A certificate has been supplied
  # Link the standard CA cert into our certs directory
  link "#{node['firezone']['ssl']['directory']}/cacert.pem" do
    to "#{node['firezone']['install_directory']}/embedded/ssl/certs/cacert.pem"
  end
elsif node['firezone']['ssl']['acme']['enabled']
  # No certificate provided but acme enabled don't
  # auto-generate and ensure acme directory is setup
  directory "#{node['firezone']['var_directory']}/ssl/acme" do
    owner 'root'
    group 'root'
    mode '0600'
  end

# No certificate has been supplied; generate one
else
  host = URI.parse(node['firezone']['external_url']).host
  ssl_keyfile = File.join(firezone_ca_dir, "#{host}.key")
  ssl_crtfile = File.join(firezone_ca_dir, "#{host}.crt")

  openssl_x509_certificate ssl_crtfile do
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

  node.default['firezone']['ssl']['certificate'] ||= ssl_crtfile
  node.default['firezone']['ssl']['certificate_key'] ||= ssl_keyfile

  link "#{node['firezone']['ssl']['directory']}/cacert.pem" do
    to ssl_crtfile
  end
end
