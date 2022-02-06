# frozen_string_literal: true

#
# Copyright:: Chef Software, Inc.
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

name 'libffi'
default_version '3.4.2'

license 'MIT'
license_file 'LICENSE'
skip_transitive_dependency_licensing true

# version_list: url=ftp://sourceware.org/pub/libffi/ filter=*.tar.gz

version('3.2.1') { source sha256: 'd06ebb8e1d9a22d19e38d63fdb83954253f39bedc5d46232a05645685722ca37' }
version('3.3') { source sha256: '72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056' }
version('3.4.2') { source sha256: '540fb721619a6aba3bdeef7d940d8e9e0e6d2c193595bc243241b77ff9e93620' }

source url: "https://github.com/libffi/libffi/releases/download/v#{version}/libffi-#{version}.tar.gz"
relative_path "libffi-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  env['INSTALL'] = '/opt/freeware/bin/install' if aix?

  # disable option checking as disable-docs is 3.3+ only
  configure_command = ['--disable-option-checking',
                       '--disable-docs']

  patch source: 'libffi-3.3-arm64.patch', plevel: 1, env: env if version == '3.3' && mac_os_x? && arm?

  # AIX's old version of patch doesn't like the patch here
  unless aix?
    # disable multi-os-directory via configure flag (don't use /lib64)
    # Works on all platforms, and is compatible on 32bit platforms as well
    configure_command << '--disable-multi-os-directory'

    # add the --disable-multi-os-directory flag to 3.2.1
    patch source: 'libffi-3.2.1-disable-multi-os-directory.patch', plevel: 1, env: env if version == '3.2.1'
  end

  configure(*configure_command, env: env)

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env

  # libffi's default install location of header files is awful...
  mkdir "#{install_dir}/embedded/include"
  copy "#{install_dir}/embedded/lib/libffi-#{version}/include/*", "#{install_dir}/embedded/include/"
end
