# frozen_string_literal: true

# Copyright FireZone
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

name "readline"
default_version "8.1"

license "GPL-3.0"
license_file "COPYING"
skip_transitive_dependency_licensing true

version("8.1") { source sha256: "f8ceb4ee131e3232226a17f51b164afc46cd0b9e6cef344be87c65962cb82b02" }

source url: "https://ftp.gnu.org/gnu/readline/readline-#{version}.tar.gz"

relative_path "#{name}-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
