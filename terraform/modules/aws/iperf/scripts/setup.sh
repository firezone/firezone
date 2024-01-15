#!/bin/bash

set -xe

sudo apt-get update
sudo apt-get install -y iperf3

sudo tee -a /etc/systemd/system/iperf3.service << EOF
[Unit]
Description=iperf3 server
After=syslog.target network.target auditd.service

[Service]
ExecStart=/usr/bin/iperf3 -s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now iperf3
