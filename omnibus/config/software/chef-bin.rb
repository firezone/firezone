name 'chef-bin'
# The version here should be in agreement with /Gemfile.lock so that our rspec
# testing stays consistent with the package contents.
default_version '15.14.0'

license 'Apache-2.0'
license_file 'LICENSE'

skip_transitive_dependency_licensing true

dependency 'ruby'
dependency 'rubygems'

build do
  env = with_standard_compiler_flags(with_embedded_path)

  gem 'install chef-bin' \
      " --version '#{version}'" \
      " --bindir '#{install_dir}/embedded/bin'" \
      ' --no-document', env: env
  patch source: 'disable_license_enforce.patch',
        target: "#{install_dir}/embedded/lib/ruby/gems/2.7.0/gems/chef-bin-#{version}/bin/chef-client"
end
