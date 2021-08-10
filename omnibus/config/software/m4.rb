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
# expeditor/ignore: deprecated 2021-04

name "m4"
default_version "1.4.18"

license "GPL-3.0"
license_file "COPYING"
skip_transitive_dependency_licensing true

version("1.4.18") { source sha256: "ab2633921a5cd38e48797bf5521ad259bdc4b979078034a3b790d7fec5493fab" }

source url: "https://ftp.gnu.org/gnu/m4/m4-#{version}.tar.gz"

relative_path "m4-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  patch source: "m4-1.4.18-glibc-change-work-around.patch", plevel: 1, env: env if version == "1.4.18"

  command "./configure --prefix=#{install_dir}/embedded", env: env

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
