#!/usr/bin/env bash
set -e

asdf plugin-add erlang
asdf plugin-add elixir
asdf plugin-add nodejs

asdf install
