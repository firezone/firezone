#
# Copyright 2012-2016 Chef Software, Inc.
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

name 'rubygems'
default_version '3.1.4'

license 'MIT'
license_file 'LICENSE.txt'

skip_transitive_dependency_licensing true

dependency 'ruby'

if version && !source
  # NOTE: 2.1.11 is the last version of rubygems before the 2.2.x change to native gem install location
  #
  #  https://github.com/rubygems/rubygems/issues/874
  #
  # This is a breaking change for omnibus clients.  Chef-11 needs to be pinned to 2.1.11 for eternity.
  # We have switched from tarballs to just `gem update --system`, but for backcompat
  # we pin the previously known tarballs.
  known_tarballs = {
    '2.1.11' => 'b561b7aaa70d387e230688066e46e448',
    '2.2.1' => '1f0017af0ad3d3ed52665132f80e7443',
    '2.4.1' => '7e39c31806bbf9268296d03bd97ce718',
    '2.4.4' => '440a89ad6a3b1b7a69b034233cc4658e',
    '2.4.5' => '5918319a439c33ac75fbbad7fd60749d',
    '2.4.8' => 'dc77b51449dffe5b31776bff826bf559',
    '2.7.9' => '173272ed55405caf7f858b6981fff526',
    '3.1.4' => 'd117187a8f016cbe8f52011ae02e858b'
  }
  known_tarballs.each do |version, md5|
    version version do
      source md5: md5, url: "https://rubygems.org/rubygems/rubygems-#{version}.tgz"
      relative_path "rubygems-#{version}"
    end
  end

  version('v2.4.4_plus_debug') { source git: 'https://github.com/danielsdeleo/rubygems.git' }
  version('2.4.4.debug.1')     { source git: 'https://github.com/danielsdeleo/rubygems.git' }
  # This is the 2.4.8 release with a fix for
  # windows so things like `gem install "pry"` still
  # work
  version('jdm/2.4.8-patched') { source git: 'https://github.com/jaym/rubygems.git' }
end

# If we still don't have a source (if it's a tarball) grab from ruby ...
if version && !source
  # If the version is a gem version, we"ll just be using rubygems.
  # If it's a branch or SHA (i.e. v1.2.3) we use github.
  begin
    Gem::Version.new(version)
  rescue ArgumentError
    source git: 'https://github.com/rubygems/rubygems.git'
  end
end

# git repo is always expanded to "rubygems"
relative_path 'rubygems' if source && source.include?(:git)

build do
  env = with_standard_compiler_flags(with_embedded_path)

  if source
    # Building from source:
    ruby 'setup.rb --no-document', env: env
  else
    # Installing direct from rubygems:
    # If there is no version, this will get latest.
    gem "update --system #{version}", env: env
    patch source: "license/add-license-file.patch"
  end
end
