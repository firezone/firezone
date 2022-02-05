# frozen_string_literal: true

# Copyright:: Firezone
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

name 'gettext'
license 'GPL-3.0'
license_file 'COPYING'

default_version '0.21'

dependency 'm4'
dependency 'autoconf'
dependency 'automake'
dependency 'bison'
dependency 'perl'
dependency 'libiconv'
dependency 'ncurses'
dependency 'bzip2'
dependency 'zlib'
dependency 'libxml2'
dependency 'liblzma'
dependency 'icu'
dependency 'pkg-config'

source url: "https://mirrors.kernel.org/gnu/gettext/gettext-#{version}.tar.gz"
version('0.21') do
  source sha256: 'c77d0da3102aec9c07f43671e60611ebff89a996ef159497ce8e59d075786b12'
end

relative_path "#{name}-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  configure_command = [
    './configure',
    # Enabling OpenMP requires libgomp, which requires building gcc which is very slow.
    '--disable-openmp',
    "--prefix=#{install_dir}/embedded"
  ]

  command configure_command, env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
