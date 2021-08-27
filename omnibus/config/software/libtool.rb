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

name "libtool"
default_version "2.4.6"

license "GPL-2.0"
license_file "COPYING"
skip_transitive_dependency_licensing true

dependency "m4"
dependency "config_guess"

# version_list: url=https://ftp.gnu.org/gnu/libtool/ filter=*.tar.gz

version("2.4.6") { source sha256: "e3bd4d5d3d025a36c21dd6af7ea818a2afcd4dfc1ea5a17b39d7854bcd0c06e3" }
version("2.4.2") { source sha256: "b38de44862a987293cd3d8dfae1c409d514b6c4e794ebc93648febf9afc38918" }
version("2.4")   { source sha256: "13df57ab63a94e196c5d6e95d64e53262834fe780d5e82c28f177f9f71ddf62e" }

source url: "https://mirrors.ocf.berkeley.edu/gnu/libtool/libtool-#{version}.tar.gz"

relative_path "libtool-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  update_config_guess
  update_config_guess(target: "libltdl/config")

  if aix?
    env["M4"] = "/opt/freeware/bin/m4"
  elsif solaris2?
    # We hit this bug on Solaris11 platforms bug#14291: libtool 2.4.2 fails to build due to macro_revision  reversion
    # The problem occurs with LANG=en_US.UTF-8 but not with LANG=C
    env["LANG"] = "C"
  end

  command "./configure" \
          " --prefix=#{install_dir}/embedded", env: env

  make env: env
  make "install", env: env
end
