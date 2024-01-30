# Testing the Firezone Windows client on a Windows server VM

## Prepare VM

1. Download and install Oracle VirtualBox <https://www.virtualbox.org/wiki/Downloads>
1. Prepare a VM with 50 GB of hard drive, 2+ GB of RAM, and 2+ CPU cores (More resources will help Windows set up faster. We can reduce resources before testing Firezone)

## Download VM image

Download the 64-bit ISO from <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022>

(Server 2019 requires a sign-up: <https://info.microsoft.com/ww-landing-windows-server-2019.html>)

You should get this file: `SERVER_EVAL_x64FRE_en-us.iso`

This will last for 6-12 months more or less.

## Install Windows Server

1. In VirtualBox, mount the ISO as a CD/DVD
1. Boot the VM and use F12, then 'c' to boot from CD/DVD
1. When Windows asks what version to install, choose "Windows Server 2022 Standard Evaluation (Desktop Experience)
1. Choose "Custom" to delete the old Windows install, if any, and re-install
1. If there's any partition from a previous install, delete and recreate it
1. Tell Windows to install on the primary partition
