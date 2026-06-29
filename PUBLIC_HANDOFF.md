# Public Handoff: CX3 Pro Inbox Driver Patch

This is the GitHub-safe project memory for the ConnectX-3 Pro inbox driver
patch work. It intentionally omits lab hostnames, private IP addresses, local
usernames, SSH commands, keys, VM identifiers, ZFS dataset/snapshot names,
private NQNs, log paths, and other environment-specific details.

## Goal

Build a Proxmox-native inbox driver patch for Mellanox ConnectX-3 Pro adapters
so RoCEv2 works with SR-IOV VFs while keeping the host close to stock Proxmox.

The preferred deployment model is a narrow module override, not a full OFED
replacement.

## Current Architecture

The project builds and installs only these patched inbox modules:

- `mlx4_core`
- `mlx4_en`
- `mlx4_ib`

They are installed below:

```text
/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2
```

The rest of the Proxmox RDMA and storage stack stays stock, including:

- `rdma_cm`
- `ib_core`
- `nvme-rdma`
- `nvmet-rdma`

This keeps the patch surface small and makes rollback practical.

## Driver Patch Scope

The main kernel patch is:

```text
patches/kernel/0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch
```

It touches the mlx4 Ethernet/core/IB code paths and provides:

- `mlx4_core.enable_mfunc_roce_v2`
- VF permission for `MLX4_SET_PORT_ROCE_ADDR`
- PF ownership of global RoCEv2 port configuration
- per-GID RoCE type tracking in the PF-managed mlx4 GID cache
- GID type return from `mlx4_core` to `mlx4_ib`
- RoCEv2 packet encoding for VF traffic based on the cached GID type
- duplicate handling for the same raw GID with different RoCE types
- a cleanup fix around `roce_v2_gsi` QP destruction

Patch footprint at the time of this handoff:

```text
8 files changed, about 239 insertions and 30 deletions
```

## Validated Behavior

The module override has been validated across multiple nearby Proxmox kernels
in the lab. The important validated behaviors are:

- patched `mlx4_*` modules resolve from the override directory
- stock RDMA core and NVMe/RDMA modules remain in use
- PF and host-owned VFs expose nonzero RoCEv2 GIDs
- SR-IOV VF VLAN/QoS policy is applied as expected
- cross-host VF RDMA-CM traffic passes with RoCEv2
- post-reboot validation passes after the RDMA postboot settle service
- post-upgrade validation passes after rebuilding the override for the new
  kernel
- rollback and re-upgrade lifecycle validation has been exercised

New kernels are allowed by default as unvalidated targets. They must pass
source apply-check, build-only, reboot/runtime verification, and RDMA-CM traffic
before being treated as supported.

## Important Tooling

- `install-pve7.sh`
  Builds and installs patched `mlx4_core`, `mlx4_en`, and `mlx4_ib` for the
  target kernel.

- `check-mlx4-rocev2-source`
  Runs semantic source checks after patch application to catch forward-port
  drift in the mlx4 RoCEv2/SR-IOV GID type plumbing.

- `preflight-upgrade.sh`
  Checks headers/build inputs, module resolution, and stock-vs-override module
  placement.

- `port-update-check`
  Runs a safe, non-installing update-readiness flow. It does not install
  modules, reboot, detach disks, or run storage writes.

- `port-validation`
  Runs lifecycle validation after reboot or upgrade. Full validation includes
  VF RDMA-CM traffic unless explicitly skipped for a documented investigation.

- `sriov_setup`
  Installs the SR-IOV/VF policy service and RDMA postboot settle service.

- `restore-stock-proxmox`
  Provides the explicit return-to-stock path. It is dry-run by default.

## Update Policy

Do not pin the whole host indefinitely just to preserve this patch. Instead:

1. Keep at least one known-good boot kernel available.
2. For a new Proxmox kernel, run preflight and apply-check first.
3. Build the three mlx4 override modules for that exact kernel.
4. Reboot into the new kernel.
5. Run runtime verification and VF RDMA-CM traffic tests.
6. Add the kernel to the tested map only after validation passes.

Exact Proxmox packaging refs can be pinned for reproducible testing, but strict
pinning is optional and should not block probing a new kernel.

## Return To Stock

A normal distro/kernel upgrade can bypass the old override for a new kernel, but
that is not a complete return to stock. It can leave project-owned modprobe
configuration, initramfs module entries, helper scripts, systemd units, and old
override directories behind.

Use:

```sh
./restore-stock-proxmox
```

to review the return-to-stock plan, and:

```sh
./restore-stock-proxmox --apply
```

to apply it for the running kernel.

Use:

```sh
./restore-stock-proxmox --apply --all-kernels
```

to move every project-owned override directory found under `/lib/modules`.

The restore path moves project-owned files into `stock-restore-backups/`, runs
`depmod`, refreshes initramfs for affected kernels, and requires a reboot before
the host should be treated as returned to stock behavior.

It does not revert Mellanox firmware SR-IOV settings and does not remove Proxmox
packages.

## Safety Rules

- Do not replace Proxmox RDMA core modules.
- Do not install full OFED as part of the inbox path.
- Do not run storage write tests unless explicitly planned.
- Keep validation logs, but sanitize them before sharing publicly.
- Treat unknown kernels as unvalidated, not unsupported.
- Keep rollback and return-to-stock commands tested and documented.

## Private Details Intentionally Omitted

The private project memory may contain:

- lab hostnames
- private IP addresses
- root SSH command lines
- VM IDs
- ZFS dataset/snapshot names
- local filesystem paths
- NQNs and storage topology
- exact log paths
- notes about local SSH key setup

Do not copy those details into this public handoff.
