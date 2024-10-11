# Testing the Firezone GUI Client on an Ubuntu VM

WIP

## (qemu VMs) Mounting the 9p share

From https://github.com/canonical/lxd/commit/b27d541f0997358b571ac2840f86660d55c9130c

1. `sudo nano /etc/fstab`
1. Append ``

## (VirtualBox VMs) Mounting the vboxsf share

Shared folders are a pain on Ubuntu 20.04.

Just use `ptth_file_server` on the host and `curl` in the guest. Let it loop through the LAN.

# Testing the Firezone Client on a Windows server VM

This assumes a Windows host. On macOS and Linux hosts, prefer UTM and qemu respectively.

## Prepare VM

1. Download and install Oracle VirtualBox <https://www.virtualbox.org/wiki/Downloads>
1. Prepare a VM with 50 GB of hard drive, 2+ GB of RAM, and 2+ CPU cores (More resources will help Windows set up faster. We can reduce resources before testing Firezone)

## Download VM image

Download the 64-bit ISO from <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022>

(Server 2019 requires a sign-up: <https://info.microsoft.com/ww-landing-windows-server-2019.html>)

You should get this file: `SERVER_EVAL_x64FRE_en-us.iso`

The Windows license is valid for 180 days

## Install Windows Server

1. In VirtualBox, mount the ISO as a CD/DVD
1. Boot the VM and use F12, then 'c' to boot from CD/DVD
1. When Windows asks what version to install, choose "Windows Server 2022 Standard Evaluation (Desktop Experience)
1. Choose "Custom" to delete the old Windows install, if any, and re-install
1. If there's any partition from a previous install, delete and recreate it
1. Tell Windows to install on the primary partition

## Windows first-time config

1. Assuming the host has a strong password, set the guest's admin password to just `Password1!`
1. Allow the PC to be "discoverable by other PCs and devices on this network", this might be needed for Firezone to work
1. In the Server Manager, click "Manage", click "Server Manager Properties", check "Do not start Server Manager automatically at logon", and click "OK". Close Server Manager.
1. Make any quality-of-life changes you want such as fixing the taskbar
1. Open `https://ifconfig.net/` in Edge and clear out the Edge first-time setup
1. Run Windows Update
1. In the VirtualBox menu, click "Devices", click "Insert Guest Additions CD image", and then install the VirtualBox guest additions, so you can drag-and-drop files into the VM easily.
1. Perform a clean shutdown from within the Windows VM.
1. In VirtualBox, take a snapshot of the VM and name it "Before Firezone" so you can roll back to this state after installing Firezone.

## Testing Firezone

1. Copy-paste an MSI built from CI/CD into the VM and install Firezone
1. Test Firezone as usual
