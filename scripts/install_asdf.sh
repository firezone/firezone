#!/usr/bin/env sh
set -e

git clone --depth 1 https://github.com/asdf-vm/asdf.git $HOME/.asdf
export PATH="${PATH}:${HOME}/.asdf/shims:${HOME}/.asdf/bin"
bash $HOME/.asdf/asdf.sh

# Install project runtimes
asdf plugin-add erlang && \
  asdf plugin-update erlang && \
  asdf plugin-add elixir && \
  asdf plugin-update elixir && \
  asdf plugin-add nodejs && \
  asdf plugin-update nodejs && \
  asdf plugin-add python && \
  asdf plugin-update python
bash -c '${ASDF_DATA_DIR:=$HOME/.asdf}/plugins/nodejs/bin/import-release-team-keyring'
asdf install
