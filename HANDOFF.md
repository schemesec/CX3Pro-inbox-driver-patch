# CX3 Pro Inbox Driver Patch Handoff

## Goal

Build and validate a Proxmox-native inbox driver patch for Mellanox
ConnectX-3 Pro cards so RoCEv2 works with SR-IOV VFs while keeping Proxmox
kernel updates, installs, and rollback clean and repeatable.

The preferred long-term path is the inbox/module-override approach, not the
OFED forward-port. Use exactly the Proxmox kernel packaging tree and its pinned
kernel source submodule for the target host. Do not assemble sources from
arbitrary Ubuntu tags. The `submodules/ubuntu-kernel` name is Proxmox's pinned
kernel source mirror.

## Active Hosts and Trees

- Local research tree: `/home/scheme/workspace/inbox-research`
- Active pvs3 implementation: `/root/CX3Pro-inbox-driver-patch`
- pvs3 current kernel: `7.0.2-6-pve`
- Exact Proxmox packaging commit for pvs3: `87f22e55de30d73b83722b86790394564036b33c`
- Proxmox-pinned kernel source commit: `69bb061d6b71ee9b43e6584cc16d2a8853e81fe6`
- Proxmox-pinned ZFS commit for `7.0.2-6`: `069198f9d5ca7876a4af06da2c42f848f0d0552e`
- Main feature patch: `patches/kernel/0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch`

The local tree has been advanced from the older `7.0.2-5` packaging state to
the Proxmox `7.0.2-6` packaging delta used by pvs3. The custom patch queue
applies through `0066` against the exact pinned Proxmox kernel source. A full
local package build was not completed because the local workstation is missing
Debian kernel build dependencies and does not have passwordless sudo.

## Current Best Implementation

The pvs3 tree is currently in the more deployable state. It builds only the
patched inbox `mlx4_core`, `mlx4_en`, and `mlx4_ib` modules and installs them
under:

`/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`

This keeps stock Proxmox RDMA core and upper protocol modules in place,
including `rdma_cm`, `nvme-rdma`, and `nvmet-rdma`. That is the preferred
compatibility model for Proxmox updates because the override is narrow, easy to
verify, and reversible without replacing the full RDMA stack.

The pvs3 repository commit tested during this handoff was:

`972079b add kernel upgrade preflight check`

## Patch Behavior

The mlx4 patch provides the missing ConnectX-3 Pro SR-IOV RoCEv2 behavior:

- Adds `mlx4_core.enable_mfunc_roce_v2`.
- Allows VFs to issue `MLX4_SET_PORT_ROCE_ADDR`.
- Keeps the PF responsible for global RoCEv2 port configuration.
- Preserves per-GID RoCE type in the mlx4 GID cache.
- Returns GID type to `mlx4_ib` so VF traffic is encoded as RoCEv2.
- Allows the same raw GID to exist as both RoCEv1 and RoCEv2 by checking the
  GID and type pair for duplicates.
- Includes a `mlx4_ib_destroy_qp` safety fix for `roce_v2_gsi` cleanup.

## Validation Completed on pvs3

Preflight passed for the currently installed kernel:

```sh
./preflight-upgrade.sh
```

Result: 0 failures and 0 warnings. The loaded `mlx4_core`, `mlx4_en`, and
`mlx4_ib` modules resolved to the `updates/cx3pro-inbox-rocev2` override path.
Stock `rdma_cm`, `nvme_rdma`, and `nvmet_rdma` remained inbox Proxmox modules.

Apply-check succeeded when pinned to the exact pvs3 Proxmox packaging commit:

```sh
PVE_KERNEL_REF=87f22e55de30d73b83722b86790394564036b33c \
  ./install-pve7.sh --apply-check-only --no-apt
```

Do not omit `PVE_KERNEL_REF` for pvs3 `7.0.2-6-pve`. The script default tracks
newer Proxmox state and was observed selecting `7.0.12`, which correctly failed
against the current target.

Build-only succeeded with the same pin:

```sh
PVE_KERNEL_REF=87f22e55de30d73b83722b86790394564036b33c \
  ./install-pve7.sh --build-only --no-apt
```

Result:

- Built `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko`.
- Module vermagic matched `7.0.2-6-pve`.
- `mlx4_ib` symbol CRCs matched the patched `mlx4_core` exports.
- Build log: `/root/CX3Pro-inbox-driver-patch/logs/install-20260627-020028.log`

Functional verifier command:

```sh
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 \
VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 \
  ./verify-pve7.sh
```

The functional checks passed:

- Proxmox services active.
- `mlx4_core.enable_mfunc_roce_v2=Y`.
- PF RoCEv2 GIDs present.
- 12 VFs accounted for.
- VFs 0-10 host-owned with stable MACs, VLAN 20, PCP 3, and RoCEv2 GIDs.
- VF11 passthrough on `vfio-pci` and intentionally skipped for host tests.
- PFC enabled for RoCE PCP 3.
- PF VLAN interfaces present with MTU 9000, correct IPs, and PCP 3 egress maps.

An earlier verifier run exited nonzero only because the current boot journal
contained an old May 24 line:

`mlx4_core 0000:17:00.0: vhcr command:0x3a slave:12 failed with error:0, status -1`

pvs3 booted on `2026-05-24`, so this was stale boot-history noise, not a new
test failure. `verify-pve7.sh` was patched to default the kernel warning scan
to the current day using `JOURNAL_SINCE`, which can be overridden for stricter
or wider scans. After that change, the same verifier command passed cleanly on
`2026-06-27`.

## Cross-Host VF RDMA-CM Testing

The repo's direct `test_vf_rdmacm` path could not complete because pvs3 does
not currently have working noninteractive SSH auth to pvs1. Testing was
orchestrated from the local workstation instead.

pvs1 client source:

- Device: `rocep23s0`
- GID index: `5`
- IP: `192.168.20.50`

pvs3 host-owned VF results:

| VF | pvs3 device | IP | Result |
| --- | --- | --- | --- |
| 0 | `mlx4_0` | `192.168.20.160` | 50.56 Gbit/s |
| 1 | `mlx4_1` | `192.168.20.161` | 49.76 Gbit/s |
| 2 | `mlx4_2` | `192.168.20.162` | 49.27 Gbit/s |
| 3 | `mlx4_3` | `192.168.20.163` | 50.64 Gbit/s |
| 4 | `mlx4_4` | `192.168.20.164` | 50.56 Gbit/s |
| 5 | `mlx4_5` | `192.168.20.165` | 50.08 Gbit/s |
| 6 | `mlx4_6` | `192.168.20.166` | 49.29 Gbit/s |
| 7 | `mlx4_7` | `192.168.20.167` | 49.39 Gbit/s |
| 8 | `mlx4_8` | `192.168.20.168` | 49.34 Gbit/s |
| 9 | `mlx4_9` | `192.168.20.169` | 50.21 Gbit/s |
| 10 | `mlx4_10` | `192.168.20.170` | 49.88 Gbit/s |

All 11 host-owned VFs passed. VF11 was skipped because it is assigned to
`vfio-pci` for passthrough.

Post-test scan since `2026-06-27 02:00:00` found no entries for:

`BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
`__warn`, `Bad wc`, `Completion with error`, `Failed status`,
`vhcr command:0x3a`, `mlx4`, or `add_roce_gid`.

No stale `ib_write_bw` or `test_vf_rdmacm` process was left running on pvs3.

## NVMe/RDMA Target Testing

NVMe/RDMA target testing was run on `2026-06-27` after the VF RDMA-CM tests.
pvs3 was used as the NVMe target and pvs1 as the initiator. pvs1 did not have
`nvme-cli` or `fio` installed, so those packages were installed from the
configured Debian/Proxmox repositories.

The target used a disposable `null_blk` namespace, not real storage:

- NQN: `nqn.2026-06.local.pvs3:cx3pro-nullblk-test`
- Backing device: `/dev/nullb0`
- pvs3 target modules: stock Proxmox `nvmet`, `nvmet_rdma`, and `rdma_cm`
- pvs1 initiator modules: stock Proxmox `nvme`, `nvme_rdma`, and `rdma_cm`

PF/VLAN target address test:

- pvs3 target address: `192.168.20.56:4420`
- pvs1 discovery: passed
- pvs1 connect: created `/dev/nvme5n1`
- fio command shape: direct `randrw`, 64 KiB block size, iodepth 32, 20 seconds
- fio result: `err=0`, about 609 MiB/s read and 608 MiB/s write
- NVMe error log: no errors

Host-owned VF target address test:

- pvs3 target netdev: `enp23s0v0`
- pvs3 target RDMA device: `mlx4_0`
- pvs3 target address: `192.168.20.160:4421`
- pvs1 discovery: passed
- pvs1 connect: created `/dev/nvme5n1`
- fio command shape: direct `randrw`, 64 KiB block size, iodepth 32, 20 seconds
- fio result: `err=0`, about 1987 MiB/s read and 1985 MiB/s write
- NVMe error log: no errors

Post-test journal scans on pvs1 and pvs3 showed only expected NVMe/RDMA
controller creation and removal messages. No current test-window entries were
found for kernel warnings, call traces, symbol failures, mlx4 failures, bad work
completions, completion errors, or `vhcr command:0x3a`.

The disposable NVMe/RDMA test target was cleaned up after testing:

- pvs1 disconnected the test NQN.
- pvs3 ports `4420` and `4421` were removed.
- pvs3 test subsystem and namespace were removed.
- pvs3 `null_blk` was unloaded.

## NVMe/RDMA VM Disk Test

After the standalone target tests, a longer VM-path test was run and left
connected intentionally.

Topology:

- NVMe target host: pvs1
- NVMe initiator / hypervisor host: pvs3
- VM: pvs3 `100` (`debian`)
- Target NQN: `nqn.2026-06.local.pvs1:cx3pro-vm100-nullblk`
- Target address: `192.168.20.50:4520`
- pvs1 backing device: `/dev/nullb0`, 8 GiB, from `null_blk`
- pvs3 connected device: `/dev/nvme1n1`
- pvs3 stable path: `/dev/disk/by-id/nvme-Linux_298f1fbbd35ea2a8d1d8`
- VM attachment: `scsi1`
- Guest-visible disk: `/dev/sdb`, serial `drive-scsi1`

pvs3 VM config now includes:

```text
scsi1: /dev/disk/by-id/nvme-Linux_298f1fbbd35ea2a8d1d8,backup=0,cache=none,discard=on,size=8G,ssd=1
```

The guest completed an initial smoke test:

- 1 GiB direct write to `/dev/sdb`
- 1 GiB direct read from `/dev/sdb`
- Both completed with exit code 0.

Then a one-hour in-guest endurance loop was run against `/dev/sdb`:

- Start: `2026-06-27T06:44:30Z` range, from the guest log
- End: `2026-06-27T07:44:30Z`
- Result: `PASS`
- Iterations: `3219`
- Each iteration: 1 GiB direct write plus 1 GiB direct read
- Approximate guest I/O volume through the VM disk path: 3219 GiB written and
  3219 GiB read

The tested path was:

`VM 100 /dev/sdb -> virtio-scsi -> pvs3 /dev/nvme1n1 -> nvme-rdma -> pvs1 nvmet-rdma -> null_blk`

Final state after the endurance run:

- pvs3 NVMe/RDMA controller remained live:
  `nvme1 rdma traddr=192.168.20.50,trsvcid=4520`
- pvs1 target export remained present under
  `/sys/kernel/config/nvmet/ports/4520`
- VM 100 still has the test disk attached at `scsi1`.
- pvs1 still has `null_blk` loaded with `/dev/nullb0`.
- Kernel scans on pvs1 and pvs3 were clean for the test window: no `BUG`,
  `Oops`, `WARNING`, `Call Trace`, symbol mismatch, bad completion, reset,
  timeout, mlx4, or `vhcr command:0x3a` failures.

Important: this is a volatile test disk backed by `null_blk`. It is good for
transport/driver validation, not persistent VM data.

## Test Safety Rule

When asked to "keep working for an hour", continue engineering the port,
packaging, update checks, scripts, and documentation. Do not interpret that as
permission to run high-volume endurance I/O. Any future long-running storage or
network stress test must be explicitly scoped first, including backing device,
expected write volume, duration, and cleanup behavior. Default tests should be
short, bounded, and low-write-volume unless the user explicitly asks for a
soak/stress run.

## Porting Workflow Updates, 2026-06-27

The active pvs3 repository was improved after the VM disk test:

- Added `nvmet-vm-lab`, a repeatable helper for disposable `null_blk` backed
  NVMe/RDMA VM disk validation.
- `nvmet-vm-lab status` was tested from the pvs3 repository and confirmed the
  live pvs1 target, pvs3 NVMe/RDMA controller, VM 100 `scsi1` disk, and clean
  bounded pvs1/pvs3 kernel scans.
- `nvmet-vm-lab guest-smoke` refuses to write unless `ALLOW_WRITE=1` is set.
  Default write volume is only `SMOKE_MIB=64`.
- `nvmet-vm-lab detach-vm` and `teardown` now guard against removing an
  unrelated VM disk; they only delete the configured slot if it matches the
  expected live NVMe/RDMA by-id path, unless `FORCE_DETACH=1` is set.
- pvs3 root SSH key auth to pvs1 root was installed so direct repository tests
  no longer depend on local workstation orchestration or password prompts.
- After key auth was fixed, `CLIENT_SSH=root@192.168.1.50
  CLIENT_DEV=rocep23s0 NUM_VFS=12 ./test_vf_rdmacm` passed directly from pvs3
  for all 11 host-owned VFs. VF11 was skipped because it is assigned to
  `vfio-pci`. Results were 49.33-50.85 Gbit/sec, and pvs1/pvs3 post-test
  scans found no matching mlx4/RDMA warnings, completion errors, call traces,
  or stale test processes.
- `preflight-upgrade.sh` now prints the exact Proxmox packaging ref for known
  tested kernels.
- `install-pve7.sh` now auto-selects the validated Proxmox packaging ref for
  `7.0.2-6-pve` when `PVE_KERNEL_REF` is not explicitly set:
  `87f22e55de30d73b83722b86790394564036b33c`.
- The known-ref map also includes the older tested `7.0.2-2-pve` packaging
  ref: `59dd19a1c4f66f932d222eac91f9f1454f9b10cc`.
- Added and validated `find-pve-kernel-ref`, which searches Proxmox
  `pve-kernel` history for a target kernel and prints the packaging commit
  plus pinned `ubuntu-kernel` and `zfsonlinux` gitlinks. It resolved both
  `7.0.2-6-pve` and `7.0.2-2-pve` to the expected refs.
- Added and validated `port-update-check`, a safe non-installing wrapper for
  preflight, ref discovery, apply-check, optional build-only, runtime verifier,
  and optional NVMe/RDMA VM lab status. It does not install modules, reboot,
  detach VM disks, or run storage write tests. `RUN_BUILD=0
  JOURNAL_SINCE='2026-06-27 13:12:00' ./port-update-check` passed on pvs3.
- Added `port-validation`, the lifecycle validation gate for post-reboot and
  post-upgrade testing. It wraps `port-update-check` plus the cross-host
  `test_vf_rdmacm` traffic test. It does not reboot, upgrade, install modules,
  detach VM disks, or run storage writes; it validates the currently booted
  host. A port state is not considered working after reboot or upgrade until
  the matching `port-validation --stage post-reboot` or
  `port-validation --stage post-upgrade` run passes with RDMA-CM enabled.
- `./install-pve7.sh --apply-check-only --no-apt` was rerun without setting
  `PVE_KERNEL_REF`; it auto-selected the ref above and the mlx4 patch applied
  cleanly to source version `7.0.2`.
- `./install-pve7.sh --build-only --no-apt` was rerun without setting
  `PVE_KERNEL_REF`; it auto-selected the same ref, rebuilt `mlx4_core.ko`,
  `mlx4_en.ko`, and `mlx4_ib.ko`, verified `7.0.2-6-pve` vermagic, and
  confirmed `mlx4_ib` symbol CRCs match patched `mlx4_core` exports.
- `verify-pve7.sh` passed after the auto-pinned build-only check and direct
  pvs3-to-pvs1 VF RDMA-CM sweep, with a bounded kernel warning scan starting at
  `2026-06-27 13:12:00`.

## Snapshot and Reboot Check, 2026-06-27

Before testing the pending Proxmox upgrade, a recursive ZFS snapshot was
created on pvs3:

- Snapshot name: `rpool@pre-inbox-port-upgrade-20260627-133934`
- Important children included:
  - `rpool/ROOT/pve-1`
  - `rpool/data`
  - VM zvols, including VM 100 disks
  - `rpool/var-lib-vz`
- State log:
  `/root/CX3Pro-inbox-driver-patch/logs/pre-upgrade-state-20260627-133934.txt`

The disposable NVMe/RDMA VM lab disk was torn down before reboot so VM 100 would
boot with only its normal disk. VM 100 is currently running with:

- `scsi0: local-zfs:vm-100-disk-1,discard=on,size=16G,ssd=1`
- `hostpci0: 0000:17:01.4`
- no disposable lab `scsi1`

pvs3 was rebooted successfully:

- Boot time: `2026-06-27 13:42:51`
- Kernel: `7.0.2-6-pve`
- `RUN_BUILD=0 RUN_NVMET_STATUS=0 JOURNAL_SINCE="$(uptime -s)"
  ./port-update-check` passed after reboot.
- Runtime verifier confirms the patched `mlx4_core`, `mlx4_en`, and `mlx4_ib`
  modules are loaded from
  `/lib/modules/7.0.2-6-pve/updates/cx3pro-inbox-rocev2`.
- PF and host-owned VF RDMA links are `ACTIVE`.
- RoCEv2 GIDs, SR-IOV VF VLAN/PCP policy, and PFC checks pass.

However, cross-host VF RDMA-CM traffic is not currently working after reboot:

- Full sweep command:
  `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 ./test_vf_rdmacm`
- Failure starts on VF0, and VF1 also failed before the run was stopped.
- Manual VF0 retest:
  - pvs3 server: `ib_write_bw -d mlx4_0 -i 1 -R -x 1 -F --report_gbits -s
    65536 --bind_source_ip 192.168.20.160`
  - pvs1 client: `ib_write_bw -d rocep23s0 -i 1 -R -x 5 -F --report_gbits -s
    65536 --bind_source_ip 192.168.20.50 192.168.20.160`
  - Client result: `Bad wc status 12`, `Unable to write to socket/rdma_cm`,
    `Failed to exchange data between server and clients`

Do not proceed to the Proxmox upgrade until this post-reboot data-plane
regression is resolved or explicitly accepted.

Update: this was resolved later on 2026-06-27. The failing PF/VF RoCEv2 tests
were caused by stale `ib_write_bw` listeners left behind by aborted diagnostic
commands, not by a persistent post-reboot driver regression. Evidence:

- PF RoCEv1 over VLAN20 passed while RoCEv2 was failing, narrowing the symptom
  to the tested RoCEv2/perftest path.
- Local same-host RoCEv2 passed on both pvs1 and pvs3.
- Exact stale pvs3 `ib_write_bw` processes were found and killed:
  three VF0 listeners and one PF listener.
- After cleanup, PF RoCEv2 RDMA-CM passed at `50.56 Gbit/sec`.
- Full clean sweep passed:
  `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12
  ./test_vf_rdmacm`
  tested VF0-VF10 at `49.63-50.67 Gbit/sec` and skipped VF11 because it is
  assigned to `vfio-pci`.

`test_vf_rdmacm` was hardened to refuse pre-existing `ib_write_bw`/`ib_send_bw`
processes unless `ALLOW_STALE_PERFTEST=1` is explicitly set, and to clean up
its active server process on exit/interrupt.

## Local Tree Status

Expected local worktree changes after aligning with Proxmox `7.0.2-6`:

- `.gitmodules` adjusted to use the public Proxmox ZFS remote.
- `Makefile` KREL moved to `6`.
- `abi-prev-7.0.2-5-pve-amd64` renamed to `abi-prev-7.0.2-6-pve-amd64`.
- `debian/changelog` updated to the Proxmox `7.0.2-6` state.
- `debian/signing-template/rules.in` updated.
- `patches/kernel/0064-drm-atomic-Increase-timeout-in-drm_atomic_helper_wai.patch` added.
- `patches/kernel/0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch` refreshed.
- `submodules/zfsonlinux` updated to `069198f9d5ca7876a4af06da2c42f848f0d0552e`.

## Next Steps

1. Keep the pvs3 module-override repository as the active implementation.
2. Treat stale perftest processes as a hard precondition failure before any PF
   or VF RDMA-CM validation.
3. Proceed with the upgrade workflow:
   - `./preflight-upgrade.sh`
   - resolve the exact new Proxmox packaging ref with `./find-pve-kernel-ref`
   - pinned `./install-pve7.sh --apply-check-only --no-apt`
   - pinned `./install-pve7.sh --build-only --no-apt`
   - install or rebuild override modules only after those checks pass.
4. After reboot, run:
   `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12
   ./port-validation --stage post-reboot`.
5. After the Proxmox upgrade, rebuild/install if the kernel changed, reboot,
   then run:
   `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12
   ./port-validation --stage post-upgrade`.
6. Keep `/home/scheme/workspace/mlx-research` as the OFED reference project,
   not the preferred deployment path.

## OFED Comparison

`/home/scheme/workspace/mlx-research` is useful as a known-good OFED
forward-port/reference tree. It has validated ConnectX-3 Pro PF/VF RoCEv2
behavior, but it replaces more of the RDMA stack and is less likely to survive
Proxmox kernel updates cleanly. The inbox override path gains the needed
ConnectX-3 Pro SR-IOV RoCEv2 behavior while keeping Proxmox's RDMA stack and
kernel packaging model intact.

## Post-reboot SR-IOV/RDMA Ordering Fix, 2026-06-27

A real fresh-boot failure was reproduced after stale perftest listeners were
eliminated. `port-validation --stage post-reboot` passed module/preflight
checks but failed VF0 RDMA-CM traffic with `Bad wc status 12` /
`Unexpected CM event ... 7`.

The root cause is boot ordering, not a failed source patch. PF and host-owned
VF RDMA links can report `ACTIVE` before RoCEv2 traffic is actually reliable.
Traffic becomes reliable after `mlx4_ib` is reloaded once SR-IOV, VF policy,
link activation, VM passthrough VF reset, and guest probe activity have settled.

`sriov_setup` now installs `cx3pro-rdma-postboot.service` and
`/usr/local/sbin/cx3pro-rdma-postboot.sh`. The unit runs after
`cx3pro-sriov-vfs.service`, `network-online.target`, and `pve-guests.service`;
waits 25 seconds for guest VF reset/probe activity; brings the PF and
host-owned VF netdevs administratively up; waits for RDMA PF/VF links; reloads
only `mlx4_ib`; waits again; then settles for 20 seconds.

The reload did not disturb VM 100's passthrough binding. During validation,
VF11 remained bound to `vfio-pci` while host-owned VF0-VF10 were available to
`mlx4_ib`.

`port-validation` now waits for the PF and host-owned VF RDMA links to become
`ACTIVE` and then settles before starting RDMA-CM traffic.

Automated clean-boot validation passed on pvs3:

- Boot ID: `c685c66f-4eeb-4178-a17f-98043460b7b1`
- Kernel: `7.0.2-6-pve`
- Boot time: `2026-06-27 15:22:08`
- Log: `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260627-152336.log`
- Command shape:
  `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 RUN_BUILD=0 RUN_NVMET_STATUS=0 ./port-validation --stage post-reboot`
- Result: preflight, exact Proxmox ref apply-check, runtime verifier, RDMA link
  readiness, VF map, and RDMA-CM traffic passed.
- VF0-VF10 RDMA-CM throughput: `49.24-50.53 Gbit/sec`.
- VF11 skipped because it is assigned to `vfio-pci`.

Next gate before calling the port upgrade-safe: run the Proxmox package upgrade
workflow from the pre-upgrade ZFS snapshot, rebuild/install the override for
the upgraded kernel, reboot, then run `port-validation --stage post-upgrade`
with RDMA-CM enabled.

## Proxmox dist-upgrade validation, 2026-06-28

Rollback snapshot before upgrade:

- Recursive ZFS snapshot: `rpool@pre-inbox-dist-upgrade-20260628-024359`
- Snapshot includes `rpool/ROOT`, `rpool/ROOT/pve-1`, VM zvols, and
  `rpool/var-lib-vz`.
- Snapshot inventory log:
  `/root/CX3Pro-inbox-driver-patch/logs/pre-dist-upgrade-zfs-20260628-024359.txt`

Pre-upgrade reboot gate:

- Boot ID: `84eea1f7-2ec8-4721-823b-61e5ded5529b`
- Kernel: `7.0.2-6-pve`
- Passing log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260628-024237.log`
- Result: `port-validation post-reboot: PASS`; VF0-VF10 RDMA-CM passed at
  `49.15-50.86 Gbit/sec`, VF11 skipped on `vfio-pci`.

Upgrade target:

- `apt full-upgrade` moved Proxmox from `9.1` era packages to `9.2` packages.
- New target kernel: `7.0.12-1-pve`
- Exact Proxmox packaging ref:
  `b8d87f8e97fa979f50d88673bd5be41de93ed2f3`
- Proxmox-pinned kernel source:
  `d873103e8ac3c51fbdb4be178bddb191af0f6a21`
- Matching headers package installed explicitly:
  `proxmox-headers-7.0.12-1-pve`

Upgrade issue found and fixed:

- `install-pve7.sh --apply-check-only` originally rejected the `7.0.12` source
  while pvs3 was still booted on `7.0.2`, because it assumed the running kernel
  was the target kernel and required target `/boot/config` plus headers even for
  source-only apply checks.
- `install-pve7.sh` now maps `7.0.12-1-pve` to the exact Proxmox ref and skips
  `/boot/config` / `Module.symvers` checks for `--apply-check-only`.
- `preflight-upgrade.sh` now also maps `7.0.12-1-pve` to the exact Proxmox
  packaging ref, eliminating the post-upgrade warning.
- `install-pve7.sh` default `TESTED_KERNELS` now includes `7.0.12-1-pve` after
  the successful upgrade validation.

Build/install result:

- `KVER=7.0.12-1-pve PVE_KERNEL_REF=b8d87f8e97fa979f50d88673bd5be41de93ed2f3 ./install-pve7.sh --no-apt`
  built and installed `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko`.
- All three modules had `7.0.12-1-pve` vermagic.
- `mlx4_ib` symbol CRCs matched patched `mlx4_core` exports.
- `modprobe -S 7.0.12-1-pve` resolved all three mlx4 modules to
  `/lib/modules/7.0.12-1-pve/updates/cx3pro-inbox-rocev2`.
- Install log:
  `/root/CX3Pro-inbox-driver-patch/logs/install-20260628-034053.log`

Post-upgrade reboot gate:

- Boot ID: `d630fe38-0e9c-4ef4-a824-558e57d64127`
- Kernel: `7.0.12-1-pve`
- `cx3pro-rdma-postboot.service` ran after `pve-guests.service`, reloaded
  `mlx4_ib`, and restored the expected RDMA naming: PF `rocep23s0`, host VFs
  `mlx4_0` through `mlx4_10`.
- Passing log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-upgrade-20260628-034405.log`
- Result: `port-validation post-upgrade: PASS`; preflight, exact Proxmox ref
  apply-check, runtime verifier, RDMA link readiness, VF map, and RDMA-CM
  traffic all passed.
- VF0-VF10 RDMA-CM throughput: `49.28-50.57 Gbit/sec`; VF11 skipped because it
  is assigned to `vfio-pci`.
- Follow-up `port-update-check` on `7.0.12-1-pve` passed with zero warnings and
  zero failures after the ref-map patch.

Current health after upgrade:

- `apt-get -s -f install` reports no required package repairs.
- `systemctl --failed` reports no failed units.
- No stale `ib_write_bw` or `ib_send_bw` processes were left running.
- `nvmet-vm-lab status` completed. It showed pvs1 target modules loaded and no
  pvs1 errors since `2026-06-28 00:00:00`. VM 100 currently exposes only its
  normal `sda` disk; no NVMe/RDMA VM test disk is attached.
