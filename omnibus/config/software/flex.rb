# frozen_string_literal: true

# Copyright:: FireZone
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
name "flex"
license_file "COPYING"
skip_transitive_dependency_licensing true
default_version "2.6.4"
source url: "https://github.com/westes/flex/releases/download/v#{version}/flex-#{version}.tar.gz"
version("2.6.4") do
  source sha256: "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"
end
relative_path "#{name}-#{version}"

dependency "bison"
dependency "m4"
dependency "gettext"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./autogen.sh"
  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
