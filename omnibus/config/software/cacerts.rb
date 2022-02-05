# frozen_string_literal: true

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

name "cacerts"

license "MPL-2.0"
license_file "https://www.mozilla.org/media/MPL/2.0/index.815ca599c9df.txt"
skip_transitive_dependency_licensing true

default_version "2021-01-19"

source url: "https://curl.haxx.se/ca/cacert-#{version}.pem"

# versions_list: https://curl.se/docs/caextract.html
version("2021-01-19") { source sha256: "e010c0c071a2c79a76aa3c289dc7e4ac4ed38492bfda06d766a80b707ebd2f29" }
version("2020-12-08") { source sha256: "313d562594ebd07846ad6b840dd18993f22e0f8b3f275d9aacfae118f4f00fb7" }
version("2020-10-14") { source sha256: "bb28d145ed1a4ee67253d8ddb11268069c9dafe3db25a9eee654974c4e43eee5" }
version("2020-07-22") { source sha256: "2782f0f8e89c786f40240fc1916677be660fb8d8e25dede50c9f6f7b0c2c2178" }
version("2020-06-24") { source sha256: "726889705b00f736200ed7999f7a50021b8735d53228d679c4e6665aa3b44987" }

relative_path "cacerts-#{version}"

build do
  mkdir "#{install_dir}/embedded/ssl/certs"

  copy "#{project_dir}/cacert*.pem", "#{install_dir}/embedded/ssl/certs/cacert.pem"
  copy "#{project_dir}/cacert*.pem", "#{install_dir}/embedded/ssl/cert.pem" if windows?

  # Windows does not support symlinks
  unless windows?
    link "certs/cacert.pem", "#{install_dir}/embedded/ssl/cert.pem",
         unchecked: true,
         force: true

    block { File.chmod(0o644, "#{install_dir}/embedded/ssl/certs/cacert.pem") }
  end
end
