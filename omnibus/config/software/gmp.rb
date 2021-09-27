#
# Copyright 2014 Chef Software, Inc.
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

name "gmp"
default_version "6.2.1"

# version_list: url=https://ftp.gnu.org/gnu/gmp/ filter=*.tar.bz2

version("6.2.1")  { source sha256: "eae9326beb4158c386e39a356818031bd28f3124cf915f8c5b1dc4c7a36b4d7c" }
version("6.1.0")  { source sha256: "498449a994efeba527885c10405993427995d3f86b8768d8cdf8d9dd7c6b73e8" }
version("6.0.0a") { source sha256: "7f8e9a804b9c6d07164cf754207be838ece1219425d64e28cfa3e70d5c759aaf" }

source url: "https://mirrors.kernel.org/gnu/gmp/gmp-#{version}.tar.bz2"

if version == "6.0.0a"
  # version 6.0.0a expands to 6.0.0
  relative_path "gmp-6.0.0"
else
  relative_path "gmp-#{version}"
end

build do
  env = with_standard_compiler_flags(with_embedded_path)

  if solaris2?
    env["ABI"] = "32"
  end

  configure_command = ["./configure",
                       "--prefix=#{install_dir}/embedded"]

  command configure_command.join(" "), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
