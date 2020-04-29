# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure("2") do |config|
  config.vm.box = "generic/alpine310"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
  end

  config.vm.provision "shell", inline: <<~SHELL
    set -x

    # Add required packages
    apk add --update \
      wget \
      autoconf \
      ca-certificates \
      gcc \
      g++ \
      libc-dev \
      linux-headers \
      make \
      autoconf \
      ncurses-dev \
      openssl-dev \
      unixodbc-dev \
      lksctp-tools-dev \
      tar

    export OTP_VER=22.3.2
    export ELIXIR_VER=1.10.2
    orig_dir=`pwd`

    # Download and unpack OTP
    prefix=OTP-$OTP_VER
    wget https://github.com/erlang/otp/archive/$prefix.tar.gz
    tar -zxf $prefix.tar.gz
    cd otp-$prefix
    # Install OTP
    ./otp_build autoconf
    ./configure
    make
    make install

    # Download and unpack Elixir
    cd $orig_dir
    prefix=v$ELIXIR_VER
    wget https://github.com/elixir-lang/elixir/archive/$prefix.tar.gz
    tar -zxf $prefix.tar.gz
    cd elixir-$ELIXIR_VER

    # Install Elixir
    make clean test

    # Add Elixir binaries to PATH
    cwd=`pwd`
    echo "export PATH=$cwd/bin:$PATH" >> /etc/profile

    # Is it working?
    bin/elixir -e 'IO.puts("Hello World!")'
  SHELL
end
