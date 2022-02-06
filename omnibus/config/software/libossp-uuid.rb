# rubocop:disable Naming/FileName
# frozen_string_literal: true

#
# Copyright 2012-2014 Chef Software, Inc.
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

name 'libossp-uuid'
default_version '1.6.2'

license 'MIT'
license_file 'README'
skip_transitive_dependency_licensing true

dependency 'config_guess'

# version_list: url=https://www.mirrorservice.org/sites/ftp.ossp.org/pkg/lib/uuid/ filter=*.tar.gz

version('1.6.2') { source sha256: '11a615225baa5f8bb686824423f50e4427acd3f70d394765bdff32801f0fd5b0' }

# ftp on ftp.ossp.org is unavaiable so we must use another mirror site.
source url: "https://www.mirrorservice.org/sites/ftp.ossp.org/pkg/lib/uuid/uuid-#{version}.tar.gz"

relative_path "uuid-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  update_config_guess

  command './configure' \
          " --prefix=#{install_dir}/embedded", env: env

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
# rubocop:enable Naming/FileName
