name "gawk"

default_version "5.1.0"

version("5.1.0") { source sha256: "03a0360edcd84bec156fe211bbc4fc8c78790973ce4e8b990a11d778d40b1a26" }

source url: "https://mirrors.ocf.berkeley.edu/gnu/gawk/gawk-#{version}.tar.gz"

relative_path "gawk-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  configure_command = ["./configure",
                       "--prefix=#{install_dir}/embedded"]

  command configure_command.join(" "), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
