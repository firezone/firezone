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

name "pcre"
default_version "8.44"

license "BSD-2-Clause"
license_file "LICENCE"
skip_transitive_dependency_licensing true

dependency "libedit"
dependency "ncurses"
dependency "config_guess"

# version_list: url=https://sourceforge.net/projects/pcre/files/pcre/ filter=*.tar.gz

version("8.44") { source sha256: "aecafd4af3bd0f3935721af77b889d9024b2e01d96b58471bd91a3063fb47728" }
version("8.38") { source sha256: "9883e419c336c63b0cb5202b09537c140966d585e4d0da66147dc513da13e629" }

source url: "http://downloads.sourceforge.net/project/pcre/pcre/#{version}/pcre-#{version}.tar.gz"

relative_path "pcre-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  update_config_guess

  command "./configure" \
          " --prefix=#{install_dir}/embedded" \
          " --disable-cpp" \
          " --enable-utf" \
          " --enable-unicode-properties" \
          " --enable-pcretest-libedit" \
          "--disable-pcregrep-jit", env: env

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
