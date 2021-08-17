#
# Copyright 2014-2018 Chef Software, Inc.
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

name "liblzma"
default_version "5.2.5"

license "Public-Domain"
license_file "COPYING"
skip_transitive_dependency_licensing true

# version_list: url=http://tukaani.org/xz/ filer=*.tar.gz

version("5.2.5") { source sha256: "f6f4910fd033078738bd82bfba4f49219d03b17eb0794eb91efbae419f4aba10" }
version("5.2.4") { source sha256: "b512f3b726d3b37b6dc4c8570e137b9311e7552e8ccbab4d39d47ce5f4177145" }
version("5.2.3") { source sha256: "71928b357d0a09a12a4b4c5fafca8c31c19b0e7d3b8ebb19622e96f26dbf28cb" }
version("5.2.2") { source sha256: "73df4d5d34f0468bd57d09f2d8af363e95ed6cc3a4a86129d2f2c366259902a2" }

source url: "http://tukaani.org/xz/xz-#{version}.tar.gz"

relative_path "xz-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  # liblzma properly uses CFLAGS for C compilation and CPPFLAGS for common
  # flags used across tools such as windres.  Don't put anything in it
  # that can be misinterpreted by windres.
  env["CPPFLAGS"] = "-I#{install_dir}/embedded/include" if windows?

  config_command = [
    "--disable-debug",
    "--disable-dependency-tracking",
    "--disable-doc",
    "--disable-scripts",
    "--disable-lzma-links",
    "--disable-lzmainfo",
    "--disable-lzmadec",
    "--disable-xzdec",
    "--disable-xz",
  ]
  config_command << "--disable-nls" if windows?

  configure(*config_command, env: env)

  make "-j #{workers} install", env: env
end
