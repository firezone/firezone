# frozen_string_literal: true

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

#
#
# XXX: Not needed at runtime, so this package is disabled in favor of OS package.
# This takes forever to compile.
#
#

name "nodejs"

license "MIT"
license_file "LICENSE"
skip_transitive_dependency_licensing true

default_version "16.6.1"

# dependency "python"

default_src_url = "https://nodejs.org/dist/v#{version}/node-v#{version}.tar.gz"

version "16.6.1" do
  source url: default_src_url, sha256: "36467b8a4e7e3bacc2f4f1709a83b0506429d1999bc461e5e363bc91d3437c09"
end

version "14.17.4" do
  source url: default_src_url, sha256: "70c75f21ac601ae9e0fd86bdfd4e13e4d302f42b4fafcd6d21804b043a571c36"
end

version "12.22.3" do
  source url: default_src_url, sha256: "30acec454f26a168afe6d1c55307c5186ef23dba66527cc34e4497d01f91bda4"
end

version "0.10.48" do
  source url: default_src_url, sha256: "27a1765b86bf4ec9833e2f89e8421ba4bc01a326b883f125de2f0b3494bd5549"
end

relative_path "node-v#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  config_command = [
    "--prefix=#{install_dir}/embedded",
    "--without-dtrace"
  ]

  if version.satisfies?(">= 12")
    config_command << "--without-node-snapshot"
    config_command << "--without-inspector"
    config_command << "--without-intl"
  end

  configure(*config_command, env: env)

  make "-j #{workers}", env: env
  make "install", env: env
end
