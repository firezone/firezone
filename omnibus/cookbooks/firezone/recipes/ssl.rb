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

include_recipe "firezone::config"

[node["firezone"]["ssl"]["directory"],
 "#{node["firezone"]["ssl"]["directory"]}/ca"].each do |dir|
  directory dir do
    owner node["firezone"]["user"]
    group node["firezone"]["group"]
    mode "0700"
  end
end

# Unless SSL is disabled, sets up SSL certificates.
# Creates a self-signed cert if none is provided.
if node["firezone"]["ssl"]["enabled"]
  firezone_ca_dir = File.join(node["firezone"]["ssl"]["directory"], "ca")
  ssl_dhparam = File.join(firezone_ca_dir, "dhparams.pem")

  # Generate dhparams.pem for perfect forward secrecy
  openssl_dhparam ssl_dhparam do
    key_length 2048
    generator 2
    owner "root"
    group "root"
    mode "0644"
  end

  node.default["firezone"]["ssl"]["ssl_dhparam"] ||= ssl_dhparam

  # A certificate has been supplied
  if node["firezone"]["ssl"]["certificate"]
    # Link the standard CA cert into our certs directory
    link "#{node["firezone"]["ssl"]["directory"]}/cacert.pem" do
      to "#{node["firezone"]["install_directory"]}/embedded/ssl/certs/cacert.pem"
    end

  # No certificate has been supplied; generate one
  else
    ssl_keyfile = File.join(firezone_ca_dir, "#{node["firezone"]["fqdn"]}.key")
    ssl_crtfile = File.join(firezone_ca_dir, "#{node["firezone"]["fqdn"]}.crt")

    openssl_x509_certificate ssl_crtfile do
      common_name node["firezone"]["fqdn"]
      org node["firezone"]["ssl"]["company_name"]
      org_unit node["firezone"]["ssl"]["organizational_unit_name"]
      country node["firezone"]["ssl"]["country_name"]
      key_length 2048
      expire 3650
      owner "root"
      group "root"
      mode "0644"
    end

    node.default["firezone"]["ssl"]["certificate"] ||= ssl_crtfile
    node.default["firezone"]["ssl"]["certificate_key"] ||= ssl_keyfile

    link "#{node["firezone"]["ssl"]["directory"]}/cacert.pem" do
      to ssl_crtfile
    end
  end
end
