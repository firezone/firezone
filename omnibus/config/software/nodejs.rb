# frozen_string_literal: true

name 'nodejs'
description 'NodeJS'
default_version '16.15.1'
license_file 'LICENSE'

source url: "https://github.com/nodejs/node/archive/refs/tags/v#{version}.tar.gz"

version('16.15.1') do
  source sha256: '4275c903232e9d32f143908b3bd43578e7a214f871eb4363f0999d6f2874df0e'
end
version('14.19.3') do
  source sha256: '69f2dbcdfe3a8f8c29848ad5c29b8db23512d2ff8dc64f73acc49ca77945dc54'
end
version('14.18.3') do
  source sha256: '0f20571bc6d7d2f4b12b133768017c913a1a40c0c600ccd553b029842f7827d0'
end
version('14.18.2') do
  source sha256: '2d3b55fa3ff98acb5a8eb26ac73c1963b38e62c2428c883fc9debdfa54efcb6c'
end
version('14.18.1') do
  source sha256: 'ee873d13ce00680c682be27132a420b3b5620f17549906dda7e2398b56ba41b0'
end

dependency 'python'

relative_path "node-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
