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
but every kernel still needs its own module build. On an upgraded host, run the preflight first, then an
apply-only check:

```sh
cd /root/CX3Pro-inbox-driver-patch
git pull
./preflight-upgrade.sh
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

For kernels already listed in `TESTED_KERNELS`, `install-pve7.sh` auto-selects
the validated Proxmox packaging ref from `lib/pve-kernel-refs.sh` when one is
known. For a new Proxmox kernel, `port-update-check` and `find-pve-kernel-ref`
try to discover the exact pve-kernel packaging commit, but absence of a known
ref is not fatal by default. Set `PVE_KERNEL_REF` when you want to pin the
source checkout exactly, and use `EXPECT_PVE_KERNEL_REF` only when reproducing
a known baseline.

Example discovery step for a new kernel:

```sh
./find-pve-kernel-ref "$(uname -r)"
```

For a safe non-installing check of the current host:

```sh
RUN_BUILD=0 ./port-update-check
```

Use `RUN_BUILD=1` when you also want to prove the modules still rebuild for
the current kernel. The wrapper still does not install modules or reboot.

The lifecycle validation gates are more complete than `port-update-check`. A
kernel or package update is not considered validated until the matching gate
passes with cross-host VF RDMA-CM traffic:

```sh
# After rebooting into the patched module override.
CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 \
  ./port-validation --stage post-reboot

# After apt upgrade, rebuilding/installing the override modules, and rebooting.
CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 \
  ./port-validation --stage post-upgrade
```

`port-validation` does not reboot, upgrade packages, install modules, detach VM
disks, or run storage writes. It validates the currently booted host and fails
unless the VF RDMA-CM traffic test runs successfully, unless `RUN_RDMACM=0` is
set deliberately for a non-traffic investigation.

## Setup scripts

The repo includes the same style of host-side helper scripts used in
`mlx-research`, adapted for the inbox-driver patch:

- `cx3pro-install` installs MST/MFT, RDMA test, and `nvme-cli` tooling and verifies or explicitly flashes CX3 Pro firmware.
- `preflight-upgrade.sh` reports whether the running kernel has the required
  headers/build inputs, whether patched `mlx4` modules resolve from the
  override directory, and whether stock `rdma_cm`, `nvme-rdma`, and
  `nvmet-rdma` remain from the current kernel tree.
- `find-pve-kernel-ref` searches the Proxmox `pve-kernel` packaging history
  for the commit matching a target kernel and prints the pinned
  `ubuntu-kernel` and `zfsonlinux` gitlinks. Use it before testing an unlisted
  Proxmox kernel.
- `lib/pve-kernel-refs.sh` centralizes the tested-kernel list and exact
  Proxmox packaging refs consumed by installer, preflight, rollback, and
  validation scripts.
- `check-mlx4-rocev2-source` runs lightweight semantic source checks after the
  mlx4 patch applies, catching common forward-port drift in RoCEv2 GID type
  plumbing before build/install/reboot. It accepts either the kernel source tree
  itself or a parent Proxmox packaging checkout containing the source tree.
- `upgrade-lifecycle` prints and logs the guarded reboot, rollback, and
  re-upgrade command blocks used for the lifecycle test. It is dry-run by
  default for dangerous operations.
- `port-update-check` runs the safe, non-installing update-readiness flow:
  preflight, ref discovery, apply-check, optional build-only, verifier, and
  optional NVMe/RDMA VM lab status. It does not install modules, reboot, detach
  disks, or run storage write tests.
- `port-validation` is the post-reboot/post-upgrade validation gate. It wraps
  `port-update-check` and the cross-host VF RDMA-CM traffic test so reboot and
  upgrade testing cannot be mistaken for a control-plane-only verifier pass.
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
- `nvmet-vm-lab` creates, connects, attaches, checks, and tears down a
  disposable `null_blk`-backed NVMe/RDMA target for VM disk-path validation.
  It defaults to status/setup operations and refuses guest writes unless
  `ALLOW_WRITE=1` is explicitly set.
- `rollback-pve7.sh` restores a previously backed-up inbox module directory and updates initramfs.
- `restore-stock-proxmox` dry-runs or applies a return-to-stock cleanup for the
  project-owned override modules, modprobe config, initramfs block, and CX3 Pro
  systemd services.

## Return to stock Proxmox

A distro or kernel upgrade may boot a kernel that does not have the
`cx3pro-inbox-rocev2` override installed, but that is only a partial return to
stock. It does not remove this project's modprobe options, initramfs module
block, SR-IOV services, helper scripts, or old override directories.

Use the explicit restore path instead:

```sh
# Review only; no changes.
./restore-stock-proxmox

# Apply for the running kernel.
./restore-stock-proxmox --apply

# Apply for every kernel with a cx3pro override directory.
./restore-stock-proxmox --apply --all-kernels
```

The script moves project-owned files into `stock-restore-backups/` instead of
deleting them, runs `depmod`, refreshes initramfs for affected kernels, and
prints the resulting stock `mlx4_*` module resolution. It intentionally does
not revert Mellanox firmware SR-IOV settings and keeps generic VFIO autoload
unless `--remove-vfio-load` is set. Reboot after applying it before treating the
host as returned to stock behavior.

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

## Disposable NVMe/RDMA VM disk lab

`nvmet-vm-lab` is for repeatable VM storage-path validation without using real
storage as the target. The default topology matches the current lab:

- target: pvs1 `192.168.20.50:4520`
- initiator/hypervisor: pvs3
- VM: pvs3 VM `100`
- target backing: pvs1 `/dev/nullb0`
- VM slot: `scsi1`

Typical setup:

```sh
./nvmet-vm-lab setup-target
./nvmet-vm-lab connect
./nvmet-vm-lab attach-vm
./nvmet-vm-lab status
```

If pvs3 does not have SSH key auth to pvs1, run from a trusted admin shell with
an explicit SSH command:

```sh
SSHPASS=... SSH_BIN='sshpass -e ssh' \
SSH_OPTS='-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new' \
  ./nvmet-vm-lab status
```

The bounded guest smoke test is intentionally small and write-gated:

```sh
ALLOW_WRITE=1 SMOKE_MIB=64 ./nvmet-vm-lab guest-smoke
```

Do not use this helper for large endurance testing unless the backing device,
expected write volume, runtime, and cleanup behavior have been explicitly
reviewed first. The default target is `null_blk`, so it validates the
transport/driver/VM plumbing but does not provide persistent VM storage.

Cleanup when the lab disk should be removed:

```sh
./nvmet-vm-lab teardown
```

`detach-vm` and `teardown` only remove the configured VM slot when it matches
the expected live NVMe/RDMA by-id path. If the controller is already gone and
manual cleanup is required, set `FORCE_DETACH=1` after checking the VM config.

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
