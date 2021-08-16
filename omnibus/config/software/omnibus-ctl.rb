#
# Copyright 2012-2015 Chef Software, Inc.
# Copyright 2017-2021 GitLab Inc.
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

name 'omnibus-ctl'
version = Gitlab::Version.new('omnibus-ctl', 'v0.6.0')
default_version version.print(false)
display_version version.print(false)

license 'Apache-2.0'
license_file 'LICENSE'

skip_transitive_dependency_licensing true

dependency 'rubygems'

source git: version.remote

relative_path 'omnibus-ctl'

build do
  env = with_standard_compiler_flags(with_embedded_path)
  patch source: 'skip-license-acceptance.patch'

  # Remove existing built gems in case they exist in the current dir
  delete 'omnibus-ctl-*.gem'

  gem 'build omnibus-ctl.gemspec', env: env
  gem 'install omnibus-ctl-*.gem --no-document', env: env

  touch "#{install_dir}/embedded/service/omnibus-ctl/.gitkeep"
end
