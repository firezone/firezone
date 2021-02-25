#!/usr/bin/env bash
set -e

os_name=$(case $MATRIX_OS in
  ubuntu-20.04)
    echo -n 'ubuntu~focal'
    ;;
  ubuntu-18.04)
    echo -n 'ubuntu~bionic'
    ;;
esac)
wget -O erlang.deb https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_23.2.3-1~${os_name}_amd64.deb
wget -O elixir.deb https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.11.2-1~${os_name}_all.deb
sudo dpkg -i erlang.deb
sudo dpkg -i elixir.deb

curl -sL https://deb.nodesource.com/setup_14.x | sudo bash -
