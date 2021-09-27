# frozen_string_literal: true

# Copyright Firezone
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

name "libmnl"
default_version "1.0.4"

license "GPL-2.1"
license_file "COPYING"
skip_transitive_dependency_licensing true

version("1.0.4") { source sha256: "171f89699f286a5854b72b91d06e8f8e3683064c5901fb09d954a9ab6f551f81" }

source url: "https://www.netfilter.org/pub/libmnl/libmnl-#{version}.tar.bz2"

relative_path "#{name}-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
