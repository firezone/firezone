#!/usr/bin/env bash
set -e

# Install runtimes as vagrant user
# Install asdf
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
