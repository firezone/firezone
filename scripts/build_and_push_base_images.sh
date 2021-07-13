#!/bin/bash
set -e

.ci/build_amazonlinux_2.base.sh
docker push ghcr.io/firezone/amazonlinux:2

.ci/build_centos_7.base.sh
docker push ghcr.io/firezone/centos:7

.ci/build_centos_8.base.sh
docker push ghcr.io/firezone/centos:8

.ci/build_fedora_33.base.sh
docker push ghcr.io/firezone/fedora:33

.ci/build_fedora_34.base.sh
docker push ghcr.io/firezone/fedora:34

.ci/build_fedora_35.base.sh
docker push ghcr.io/firezone/fedora:35

.ci/build_debian_10.base.sh
docker push ghcr.io/firezone/debian:10

.ci/build_ubuntu_18.04.base.sh
docker push ghcr.io/firezone/ubuntu:18.04

.ci/build_ubuntu_20.04.base.sh
docker push ghcr.io/firezone/ubuntu:20.04
