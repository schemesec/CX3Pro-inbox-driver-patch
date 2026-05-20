# CX3Pro-inbox-driver-patch

Experimental Proxmox inbox-kernel patch work for Mellanox ConnectX-3 Pro
RoCEv2/SR-IOV testing in my homelab.

This repository was created with AI assistance for a specific local setup. It
is for testing and research only; do not use it as a production driver source.

## Fresh install test flow

On the Proxmox host:

```sh
cd /root
git clone https://github.com/schemesec/CX3Pro-inbox-driver-patch.git
cd CX3Pro-inbox-driver-patch
./install-pve7.sh
reboot
```

The installer builds patched inbox `mlx4_core`, `mlx4_en`, and `mlx4_ib`
modules for the currently running kernel, installs them under
`/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`, updates module
dependencies/initramfs, and leaves activation to the reboot.

If an older `mlx-research`/OFED override tree is present, the installer moves
that override and its legacy module options into `module-backups/` first. This
is intentional: the inbox patch must resolve against the stock inbox RDMA core,
not the ported OFED stack.
