#!/usr/bin/env bash
set -xeuo pipefail

wget --no-clobber https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img

virt-copy-in -a ubuntu-20.04-server-cloudimg-amd64.img rust/target/x86_64-unknown-linux-musl/release/firezone-relay /usr/local/bin/

genisoimage -output seed.iso -volid cidata -joliet -rock scripts/qemu/relay/user-data scripts/qemu/relay/meta-data
