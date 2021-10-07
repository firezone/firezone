name "icu"
license_file "LICENSE"
skip_transitive_dependency_licensing true
default_version "69.1"

source url: "https://github.com/unicode-org/icu/releases/download/release-#{version.gsub(".", "-")}/icu4c-#{version.gsub(".", "_")}-src.tgz"
version("69.1") do
  source sha256: "4cba7b7acd1d3c42c44bb0c14be6637098c7faf2b330ce876bc5f3b915d09745"
end

relative_path "icu/source"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env

  # XXX: amazonlinux builds fail with OOM errors on only 2gb of RAM.
  # Reduce workers as a workaround for now.
  if ENV["LABELS"] = "amazonlinux2"
    workers 1
  end

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
