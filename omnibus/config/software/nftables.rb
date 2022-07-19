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
#
name 'nftables'

license_file 'COPYING'
skip_transitive_dependency_licensing true

# Some weirdness in the official release package so use git and switch to tag
# default_version "1.0.4"
# source url: "https://www.netfilter.org/pub/nftables/nftables-#{version}.tar.bz2"
# version("1.0.4") { source sha256: "927fb1fea1f685a328c10cf791eb655d7e1ed49d310eea5cb3101dfd8d6cba35" }
source git: 'git://git.netfilter.org/nftables'
default_version 'v1.0.4'

relative_path "#{name}-#{version}"

dependency 'gmp'
dependency 'm4'
dependency 'bison'
dependency 'flex'
dependency 'libmnl'
dependency 'libnftnl'
dependency 'libtool'
dependency 'linenoise'
dependency 'pkg-config'

build do
  env = with_standard_compiler_flags(with_embedded_path)
  configure_cmd = [
    './configure',
    "--prefix=#{install_dir}/embedded",
    '--disable-debug',
    '--disable-man-doc',
    '--with-cli=linenoise' # readline seems to fail to be detected and libedit fails with missing "editline/history.h"
  ]
  command './autogen.sh', env: env
  command configure_cmd.join(' '), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
