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
# expeditor/ignore: deprecated 2021-04

name "automake"
default_version "1.16"

dependency "autoconf"
dependency "perl-thread-queue"

license "GPL-2.0"
license_file "COPYING"
skip_transitive_dependency_licensing true

version("1.16") { source sha256: "80da43bb5665596ee389e6d8b64b4f122ea4b92a685b1dbd813cd1f0e0c2d83f" }
version("1.15") { source sha256: "7946e945a96e28152ba5a6beb0625ca715c6e32ac55f2e353ef54def0c8ed924" }
version("1.11.2") { source sha256: "c339e3871d6595620760725da61de02cf1c293af8a05b14592d6587ac39ce546" }

source url: "https://ftp.gnu.org/gnu/automake/automake-#{version}.tar.gz"

relative_path "automake-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  if version == "1.15"
    command "./bootstrap.sh", env: env
  else
    command "./bootstrap", env: env
  end
  command "./configure" \
          " --prefix=#{install_dir}/embedded", env: env

  make "-j #{workers}", env: env
  make "install", env: env
end
