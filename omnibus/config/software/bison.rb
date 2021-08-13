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
#
# expeditor/ignore: deprecated 2021-04
name "bison"
license "GPL-3.0"
license_file "COPYING"
skip_transitive_dependency_licensing true
default_version "3.7"
source url: "http://mirrors.ibiblio.org/gnu/bison/bison-#{version}.tar.gz"
version("3.7") do
  source sha256: "492ad61202de893ca21a99b621d63fa5389da58804ad79d3f226b8d04b803998"
end
relative_path "bison-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
