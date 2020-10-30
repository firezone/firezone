# This Dockerfile builds release packages
FROM ubuntu:20.04

# Setup to run build script
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    locales && \
    apt-get clean && \
    rm -rf /tmp/* /var/tmp/*
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app
COPY . .
RUN ./pkg/build.sh
