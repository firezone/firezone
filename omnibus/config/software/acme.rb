# frozen_string_literal: true

name 'acme'

default_version '3.0.4'

source url: "https://github.com/acmesh-official/acme.sh/archive/refs/tags/#{version}.tar.gz"

license 'GPL-3.0'

version('3.0.4') do
  source sha256: 'c2855836a6db5766474c860fa54fa2f9f378ab334856b0cf0d07512866b808bb'
end

relative_path "acme.sh-#{version}"

build do
  copy 'acme.sh', "#{install_dir}/embedded/bin"
end
