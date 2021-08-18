#
# Cookbook:: supermarket
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

include_recipe 'omnibus-supermarket::config'

[node['supermarket']['ssl']['directory'],
 "#{node['supermarket']['ssl']['directory']}/ca"].each do |dir|
  directory dir do
    owner node['supermarket']['user']
    group node['supermarket']['group']
    mode '0700'
  end
end

# Unless SSL is disabled, sets up SSL certificates.
# Creates a self-signed cert if none is provided.
if node['supermarket']['ssl']['enabled']
  supermarket_ca_dir = File.join(node['supermarket']['ssl']['directory'], 'ca')
  ssl_dhparam = File.join(supermarket_ca_dir, 'dhparams.pem')

  # Generate dhparams.pem for perfect forward secrecy
  openssl_dhparam ssl_dhparam do
    key_length 2048
    generator 2
    owner 'root'
    group 'root'
    mode '0644'
  end

  node.default['supermarket']['ssl']['ssl_dhparam'] ||= ssl_dhparam

  # A certificate has been supplied
  if node['supermarket']['ssl']['certificate']
    # Link the standard CA cert into our certs directory
    link "#{node['supermarket']['ssl']['directory']}/cacert.pem" do
      to "#{node['supermarket']['install_directory']}/embedded/ssl/certs/cacert.pem"
    end

  # No certificate has been supplied; generate one
  else
    ssl_keyfile = File.join(supermarket_ca_dir, "#{node['supermarket']['fqdn']}.key")
    ssl_crtfile = File.join(supermarket_ca_dir, "#{node['supermarket']['fqdn']}.crt")

    openssl_x509_certificate ssl_crtfile do
      common_name node['supermarket']['fqdn']
      org node['supermarket']['ssl']['company_name']
      org_unit node['supermarket']['ssl']['organizational_unit_name']
      country node['supermarket']['ssl']['country_name']
      key_length 2048
      expire 3650
      owner 'root'
      group 'root'
      mode '0644'
    end

    node.default['supermarket']['ssl']['certificate'] ||= ssl_crtfile
    node.default['supermarket']['ssl']['certificate_key'] ||= ssl_keyfile

    link "#{node['supermarket']['ssl']['directory']}/cacert.pem" do
      to ssl_crtfile
    end
  end
end
