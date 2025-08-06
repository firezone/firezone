#!/usr/bin/env bash

qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -drive file=ubuntu-20.04-server-cloudimg-amd64.img,format=qcow2,if=virtio \
  -cdrom seed.iso \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0
