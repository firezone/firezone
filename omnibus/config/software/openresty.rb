# frozen_string_literal: true

# Copyright 2012-2016 Chef Software, Inc.
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

name 'openresty'
default_version '1.21.4.1'

dependency 'pcre'
dependency 'openssl'

# OpenResty includes zlib so we don't need to depend on it
# dependency 'zlib'

license_file 'COPYRIGHT'

source url: "https://openresty.org/download/openresty-#{version}.tar.gz"

# versions_list: https://nginx.org/download/ filter=*.tar.gz
version('1.21.4.1') { source sha256: '0c5093b64f7821e85065c99e5d4e6cc31820cfd7f37b9a0dec84209d87a2af99' }

relative_path "openresty-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command './configure' \
          " --prefix=#{install_dir}/embedded" \
          ' --with-ipv6' \
          '--with-pcre-jit' \
          " --with-cc-opt=\"-L#{install_dir}/embedded/lib -I#{install_dir}/embedded/include\"" \
          " --with-ld-opt=-L#{install_dir}/embedded/lib", env: env

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env

  # Ensure the logs directory is available on rebuild from git cache
  touch "#{install_dir}/embedded/logs/.gitkeep"
end
