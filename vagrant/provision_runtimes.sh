#!/usr/bin/env bash
set -e

# Install Erlang
wget https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_22.3.3-1~ubuntu~bionic_amd64.deb
dpkg -i esl-erlang_22.3.3-1~ubuntu~bionic_amd64.deb

# Install Elixir
wget https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.10.3-1~ubuntu~bionic_all.deb
dpkg -i elixir_1.10.3-1~ubuntu~bionic_all.deb
