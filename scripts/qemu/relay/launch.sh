#!/usr/bin/env bash

qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -drive file=ubuntu-20.04-server-cloudimg-amd64.img,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
