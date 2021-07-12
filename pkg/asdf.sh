#!/usr/bin/env bash
set -e

# Wraps asdf to use within Dockerfiles
. $HOME/.asdf/asdf.sh

asdf plugin-add erlang
asdf plugin-add elixir
asdf plugin-add nodejs

asdf install
