# rubocop:disable Naming/FileName
# frozen_string_literal: true

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

name 'firezone-cookbooks'
license :project_license

source path: 'cookbooks/firezone'

# rubocop:disable Metrics/BlockLength
build do
  cookbooks_path = "#{install_dir}/embedded/cookbooks"
  env = with_standard_compiler_flags(with_embedded_path)

  command "berks vendor #{cookbooks_path}", env: env

  block do
    all_the_gem_deps = {}
    Dir.glob("#{cookbooks_path}/**/metadata.json").each do |metadata|
      cookbook_name = File.basename(File.dirname(metadata))
      metadata_json = FFI_Yajl::Parser.parse(File.read(metadata))
      gem_deps = metadata_json.fetch('gems', [])
      all_the_gem_deps[cookbook_name] = gem_deps unless gem_deps.empty?
    end

    unless all_the_gem_deps.empty?
      raise Omnibus::Error, 'Nope. Gem dependencies found in the following '\
        'cookbooks used during ctl-reconfigure. This will break airgapped '\
        "installs.\n#{all_the_gem_deps}"
    end
  end

  block do
    File.open("#{cookbooks_path}/dna.json", 'w') do |file|
      file.write FFI_Yajl::Encoder.encode(run_list: ['recipe[firezone::default]'])
    end

    File.open("#{cookbooks_path}/show-config.json", 'w') do |file|
      file.write FFI_Yajl::Encoder.encode(
        run_list: ['recipe[firezone::show_config]']
      )
    end

    File.open("#{cookbooks_path}/solo.rb", 'w') do |file|
      file.write <<~SOLO
        cookbook_path   "#{cookbooks_path}"
        cache_path "/var/opt/firezone/cache"
        verbose_logging true
        ssl_verify_mode :verify_peer
      SOLO
    end
  end
end
# rubocop:enable Metrics/BlockLength
# rubocop:enable Naming/FileName
