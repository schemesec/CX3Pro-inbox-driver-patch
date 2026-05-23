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
dependencies/initramfs, and leaves activation to the reboot. Kernels outside
`TESTED_KERNELS` are allowed by default but are treated as unvalidated until the
build, boot, verifier, and RDMA traffic tests pass.

`mlx4_core` and `mlx4_ib` contain the RoCEv2/SR-IOV logic changes. `mlx4_en`
is built and installed from the same patched inbox source tree so the active
mlx4 Ethernet, core, and IB modules stay from one consistent build.

If an older `mlx-research`/OFED override tree is present, the installer moves
that override and its legacy module options into `module-backups/` first. This
is intentional: the inbox patch must resolve against the stock inbox RDMA core,
not the ported OFED stack.

## Kernel upgrades

The patch is intended to be source-level portable across nearby Proxmox kernels,
but every kernel still needs its own module build. On an upgraded host, run an
apply-only check first:

```sh
cd /root/CX3Pro-inbox-driver-patch
git pull
./install-pve7.sh --apply-check-only --no-apt
```

If that passes, build and install for the running kernel:

```sh
./install-pve7.sh --no-apt
reboot
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 ./verify-pve7.sh

# Optional: host-owned VF test IPs visible in the Proxmox network GUI.
# Do not use this for VFs assigned to VMs. Review first, then apply.
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces --dry-run
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces
NUM_VFS=12 ./test_vf_rdmacm --list
CLIENT_SSH=root@192.168.1.50 NUM_VFS=12 ./test_vf_rdmacm
```

Use `--strict-kernel` only when you want the installer to refuse kernels not
listed in `TESTED_KERNELS`. `--force-kernel` is kept as a compatibility alias
for intentionally testing an unlisted kernel.

## Setup scripts

The repo includes the same style of host-side helper scripts used in
`mlx-research`, adapted for the inbox-driver patch:

- `install-pve7.sh` builds and installs only the patched inbox `mlx4` modules.
- `sriov_setup` configures CX3 Pro SR-IOV boot options and the VF VLAN service.
- `rocesetup` configures PF VLAN interfaces for RoCEv2 testing.
- `verify-pve7.sh` checks module resolution, RoCEv2 GIDs, VF VLAN/MAC state,
  and kernel warnings.
- `vf_roce_test_ifaces` optionally writes host-owned VF test IPs to
  `/etc/network/interfaces` so Proxmox can display them as managed config.
- `test_vf_rdmacm` runs coupled pvs3-listener/pvs1-client VF `ib_write_bw`
  tests so approval delay cannot invalidate RDMA-CM results.

Example pvs3 flow after the first reboot:

```sh
cd /root/CX3Pro-inbox-driver-patch
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 ./sriov_setup
reboot
VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 ./rocesetup
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 ./verify-pve7.sh

# Optional host-owned VF addresses for RDMA-CM testing, visible in Proxmox.
# Skip this for VFs assigned to VMs. Review first, then apply.
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces --dry-run
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces
NUM_VFS=12 ./test_vf_rdmacm --list
CLIENT_SSH=root@192.168.1.50 NUM_VFS=12 ./test_vf_rdmacm
```

Unlike the OFED port, these scripts do not set `roce_mode`, `ud_gid_type`, or
load `mlx_compat`; RoCEv2 exposure comes from the patched inbox `mlx4` modules
and `mlx4_core.enable_mfunc_roce_v2=1`.

The verifier intentionally fails on kernel warnings and symbol/path mismatches.
Those checks are there to catch real driver regressions; they are not masking
or filtering driver failures to make the patch look clean.
