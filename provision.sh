#!/usr/bin/env bash
set -xe

# This file provisions the vagrant vm with needed tools to develop
# and test a single-host CloudFire instance.

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
  tar \
  git

# Install asdfgit clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.7.o
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.7.8
echo '. $HOME/.asdf/asdf.sh' >> ~/.bash_profile
echo '. $HOME/.asdf/completions/asdf.bash' >> ~/.bash_profile
source ~/.bash_profile

asdf plugin-add erlang
asdf install erlang 22.3.3
asdf global erlang 22.3.3

asdf plugin-add elixir
asdf install elixir 1.10.3-otp-22
asdf global elixir 1.10.3-otp-22

# Is it working?
elixir -e 'IO.puts("Hello World!")'
