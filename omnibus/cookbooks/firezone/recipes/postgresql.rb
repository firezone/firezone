#
# Cookbook:: firezone
# Recipe:: postgresql
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
include_recipe 'enterprise::runit'

# These sysctl settings make the shared memory settings work for larger
# instances
%w[shmmax shmall].each do |param|
  sysctl "kernel.#{param}" do
    value node['firezone']['postgresql'][param]
  end
end

directory node['firezone']['postgresql']['log_directory'] do
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0700'
  recursive true
end

if node['firezone']['postgresql']['enabled']
  enterprise_pg_cluster 'firezone' do
    data_dir node['firezone']['postgresql']['data_directory']
    encoding 'UTF8'
  end

  component_runit_service 'postgresql' do
    package 'firezone'
    control ['t']
    action :enable
    subscribes :restart, 'enterprise_pg_cluster[firezone]'
  end
else
  runit_service 'postgresql' do
    action :disable
  end
end
