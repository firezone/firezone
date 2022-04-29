FROM ubuntu:bionic AS dev-base

ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG USERNAME=vscode

ENV DEBIAN_FRONTEND=noninteractive

RUN echo "APT::Install-Recommends 0;" >> /etc/apt/apt.conf.d/01norecommends \
  && echo "APT::Install-Suggests 0;" >> /etc/apt/apt.conf.d/01norecommends \
  && apt update \
  && apt upgrade -y \
  && apt install -y \
    apt-utils \
    dialog \
    wget \
    net-tools \
    wireguard \
    inotify-tools \
    ca-certificates \
    build-essential \
    python python-pip \
    less \
    automake \
    autoconf \
    libreadline-dev \
    libncurses-dev \
    libssl-dev \
    libyaml-dev \
    libxslt-dev \
    libffi-dev \
    libtool \
    zlib1g-dev \
    unixodbc-dev \
    unzip \
    curl \
    git \
    vim \
    sudo \
    bsdmainutils \
    gpg \
    dirmngr \
  # Clean up
  && apt-get autoremove -y \
  && apt-get clean -y \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid $USER_GID $USERNAME \
  && useradd --uid $USER_GID --gid $USERNAME --shell /bin/bash --create-home --groups sudo $USERNAME \
  && echo "%${USERNAME}    ALL=(ALL)   NOPASSWD:    ALL" >> /etc/sudoers.d/${USERNAME} \
  && mkdir -p /home/$USERNAME/.vscode-server/extensions \
      /home/$USERNAME/.vscode-server-insiders/extensions \
  && chown -R $USERNAME \
      /home/$USERNAME/.vscode-server \
      /home/$USERNAME/.vscode-server-insiders \
  && mkdir -p /workspace \
  && chown -R $USERNAME /workspace

ENV DEBIAN_FRONTEND=dialog

FROM dev-base AS setup-asdf

ARG USERNAME=vscode

RUN git clone https://github.com/asdf-vm/asdf.git /opt/asdf \
  && cd /opt/asdf \
  && git checkout "$(git describe --abbrev=0 --tags)" \
  && mkdir /opt/asdf-data \
  && chown -R $USERNAME /opt/asdf-data

FROM setup-asdf AS dev-env

ARG USERNAME=vscode

USER $USERNAME
WORKDIR /home/$USERNAME
ENV HOME=/home/$USERNAME \
  TZ="UTC" \
  LC_ALL="C.UTF-8" \
  ASDF_DIR="/opt/asdf" \
  ASDF_DATA_DIR="/opt/asdf-data"

RUN echo '\n. /opt/asdf/asdf.sh' >> ~/.bashrc \
    && echo '\n. /opt/asdf/completions/asdf.bash' >> ~/.bashrc

SHELL ["/bin/bash", "-ic"]

RUN asdf plugin-add erlang https://github.com/asdf-vm/asdf-erlang.git && \
    asdf plugin-add elixir https://github.com/asdf-vm/asdf-elixir.git && \
    asdf plugin-add nodejs https://github.com/asdf-vm/asdf-nodejs.git && \
    asdf plugin-add ruby https://github.com/asdf-vm/asdf-ruby.git

# Need global erlang version to install Elixir -     https://github.com/asdf-vm/asdf-elixir/issues/113
COPY .tool-versions /home/vscode/.tool-versions

RUN asdf install erlang
# No order to asdf, so elixir error without Erlang
RUN asdf install

RUN mix local.hex --force
RUN mix local.rebar --force

VOLUME ["${ASDF_DATA_DIR}"]

# Pre-commit install with deps
RUN pip install setuptools wheel
RUN pip install pre-commit

ENV PATH=${HOME}/.local/bin:/opt/asdf-data/shims:/opt/asdf/bin:${PATH}

CMD ["/bin/bash"]
