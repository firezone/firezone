#!/usr/bin/env bash
set -e

os_name='ubuntu~bionic'

echo 'Current architecture:'
echo $arch

wget -O erlang.deb https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_24.0.2-1~${os_name}_${arch}.deb
wget -O elixir.deb https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.12.0-1~${os_name}_all.deb
sudo dpkg -i erlang.deb
sudo dpkg -i elixir.deb

curl -sL https://deb.nodesource.com/setup_14.x | sudo bash -
