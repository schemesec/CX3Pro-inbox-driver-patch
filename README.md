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
./cx3pro-install
./install-pve7.sh
reboot
```

`cx3pro-install` installs MST/MFT, RDMA test, and `nvme-cli` tooling and verifies the CX3 Pro firmware image and current card firmware; firmware burning remains opt-in through `--flash`. The post-boot verifier requires firmware matching `2.42.5x`.

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
CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 ./test_vf_rdmacm
```

Use `--strict-kernel` only when you want the installer to refuse kernels not
listed in `TESTED_KERNELS`. `--force-kernel` is kept as a compatibility alias
for intentionally testing an unlisted kernel.

## Setup scripts

The repo includes the same style of host-side helper scripts used in
`mlx-research`, adapted for the inbox-driver patch:

- `cx3pro-install` installs MST/MFT, RDMA test, and `nvme-cli` tooling and verifies or explicitly flashes CX3 Pro firmware.
- `install-pve7.sh` builds and installs only the patched inbox `mlx4` modules.
- `install-debian-vf-guest.sh` builds and installs the minimal Debian guest
  `mlx4_core`, `mlx4_en`, and `mlx4_ib` patches required when a CX3 Pro VF is
  passed through to a VM. It requires the host-side patch to be active.
- `sriov_setup` configures CX3 Pro SR-IOV boot options and the VF VLAN service, including RoCE VLAN PCP `3` by default.
- `rocesetup` configures PF VLAN interfaces for RoCEv2 testing, maps egress RoCE traffic to VLAN PCP `3`, and enables PFC for that priority by default.
- `verify-pve7.sh` checks module resolution, RoCEv2 GIDs, VF VLAN/MAC state,
  and kernel warnings.
- `vf_roce_test_ifaces` optionally writes host-owned VF test IPs to
  `/etc/network/interfaces` so Proxmox can display them as managed config.
- `test_vf_rdmacm` runs coupled pvs3-listener/pvs1-client VF `ib_write_bw`
  tests so approval delay cannot invalidate RDMA-CM results.
- `rollback-pve7.sh` restores a previously backed-up inbox module directory and updates initramfs.

Example pvs3 flow after the first reboot:

```sh
cd /root/CX3Pro-inbox-driver-patch
./cx3pro-install
./install-pve7.sh --no-apt
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 ./sriov_setup
reboot
VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 VLAN20_ROUTE_CIDR=192.168.20.0/24 ./rocesetup
# VLAN IPv6 is disabled by default here so the eight PF GID entries are used for the required IPv4 RoCE endpoints.
# RoCE PCP 3 is applied by default to PF VLAN egress and VF VLAN policy for the lossless traffic class.
# PFC is enabled on the CX3 PF for priority 3 by default, matching the lossless RoCE class.
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 ./verify-pve7.sh

# Optional host-owned VF addresses for RDMA-CM testing, visible in Proxmox.
# Skip this for VFs assigned to VMs. Review first, then apply.
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces --dry-run
NUM_VFS=12 VF_IP_BASE=192.168.20. VF_ROUTE_CIDR=192.168.20.0/24 ./vf_roce_test_ifaces
NUM_VFS=12 ./test_vf_rdmacm --list
CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 ./test_vf_rdmacm
```

Unlike the OFED port, these scripts do not set `roce_mode`, `ud_gid_type`, or
load `mlx_compat`; RoCEv2 exposure comes from the patched inbox `mlx4` modules
and `mlx4_core.enable_mfunc_roce_v2=1`.

The verifier intentionally fails on kernel warnings and symbol/path mismatches.
Those checks are there to catch real driver regressions; they are not masking
or filtering driver failures to make the patch look clean.

`install-stock-rdma-pve7.sh` from `mlx-research` is intentionally not copied into this repository: this inbox patch already leaves current inbox `rdma_cm`, `nvme-rdma`, and `nvmet-rdma` in place.

## Debian guest VF passthrough

The host patch alone is sufficient for host-owned VFs. A VF passed through to
a Debian VM loads the guest's own `mlx4` modules, so the guest also needs the
minimal patches in `patches/guest/`.

Inside a Debian guest with the CX3 Pro VF attached:

```sh
git clone https://github.com/schemesec/CX3Pro-inbox-driver-patch.git
cd CX3Pro-inbox-driver-patch
./install-debian-vf-guest.sh
reboot
```

The guest patches:

- retain the RoCEv2 capability reported to a VF when its host PF is patched;
- expose RoCEv2-only VF GIDs and leave PF-level UDP port configuration to the
  host;
- stop a VF from requesting physical global-pause state, which remains owned
  by the PF configured for PCP/PFC.

The script builds from the Debian source package matching the running guest
kernel and installs only `mlx4_core`, `mlx4_en`, and `mlx4_ib` below
`/lib/modules/<kernel>/updates/cx3pro-vf-rocev2`. It also ensures all three modules are included
in the guest initramfs so early VF probe cannot mix patched and stock modules. The dependency path installs `nvme-cli` so stock guest `nvme-rdma` can be validated over the patched VF.
