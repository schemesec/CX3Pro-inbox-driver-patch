# Tested

This repo is experimental and was created with AI assistance for a specific
homelab CX3 Pro setup. It is not a production driver source.

## pvs3 current validated state

- Host: `pvs3`
- Kernel: `7.0.12-1-pve`
- Proxmox: `pve-manager/9.2.3/d0fde103346cf89a`
- Module install path: `/lib/modules/7.0.12-1-pve/updates/cx3pro-inbox-rocev2`
- Exact Proxmox packaging ref:
  `b8d87f8e97fa979f50d88673bd5be41de93ed2f3`
- Proxmox-pinned Linux source:
  `d873103e8ac3c51fbdb4be178bddb191af0f6a21`
- Current validated rollback point:
  `rpool@post-rollback-reupgrade-validated-20260628-041821`

Current pinned non-installing update readiness passed:

```sh
STRICT_PREFLIGHT=1 \
EXPECT_PVE_KERNEL_REF=b8d87f8e97fa979f50d88673bd5be41de93ed2f3 \
RUN_BUILD=0 RUN_NVMET_STATUS=0 ./port-update-check
```

Latest apply/source-check log:
`/root/CX3Pro-inbox-driver-patch/logs/install-20260628-101157.log`.

## pvs3

- Host: `pvs3`
- Kernel: `7.0.2-2-pve`
- Module install path: `/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`
- Driver patch commit tested: `009a0ad`

Validated:

- `install-pve7.sh --build-only --no-apt` builds `mlx4_core.ko`, `mlx4_en.ko`,
  and `mlx4_ib.ko` with matching vermagic.
- `mlx4_ib.ko` symbol CRCs match the patched `mlx4_core.ko` exports.
- `install-pve7.sh --no-build` installs the modules, runs `depmod`, updates
  initramfs, and makes `modprobe --show-depends` resolve all three `mlx4`
  modules from `updates/cx3pro-inbox-rocev2`.
- After reboot, `mlx4_core.enable_mfunc_roce_v2=Y`.
- PF RDMA device `mlx4_0` exposes RoCEv2 GIDs for `enp23s0`,
  `enp23s0.10`, and `enp23s0.20`.
- Host-owned VF RDMA devices expose RoCEv2 GIDs for `enp23s0v0` through
  `enp23s0v7`. RDMA device names are not stable across boots; map them from
  `/sys/class/infiniband/*/ports/*/gid_attrs/ndevs/*` instead of hardcoding
  names in tests.
- `verify-pve7.sh` passes after reboot, including the kernel warning scan for
  `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
  `__warn`, and `vhcr command:0x3a`.
- Cross-host PF RoCEv2 `ib_write_bw` from `pvs1` to `pvs3` passes after
  setting the pvs3 PF/VLAN MTU back to 9000:

  ```sh
  # pvs3 server
  ib_write_bw -d rocep23s0 -i 1 -R -x 5 -F --report_gbits -s 65536

  # pvs1 client
  ib_write_bw -d mlx4_0 -i 1 -R -x 5 -F --report_gbits -s 65536 192.168.20.56
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.50 -> 192.168.20.56`, RDMA MTU 2048, 49.25 Gbit/sec average.
  A post-test pvs3 kernel warning scan returned no entries.
- Local host-owned VF RoCEv2 `ib_write_bw` passes on pvs3 after reboot.
  On this boot VF0 mapped to RDMA device `rocep23s0`, netdev `enp23s0v0`,
  with IPv4 RoCEv2 GID index `3` for `192.168.20.156`:

  ```sh
  ib_write_bw -d rocep23s0 -i 1 -R -x 3 -F --report_gbits -s 65536
  ib_write_bw -d rocep23s0 -i 1 -R -x 3 -F --report_gbits -s 65536 192.168.20.156
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.156 -> 192.168.20.156`, RDMA MTU 2048, 46.80 Gbit/sec average.
  A post-test pvs3 kernel warning scan returned no entries.
- Cross-host host-owned VF RoCEv2 `ib_write_bw` from `pvs1` to all eight
  pvs3 host-owned VFs passes after reboot with IPv4 RoCEv2 GID index `3` on
  each VF. The test used pvs1 only as the `ib_write_bw` client and restored
  the pvs3 route to `enp23s0.20` after testing:

  ```text
  VF0 enp23s0v0 192.168.20.156 mlx4_1    49.40 Gbit/sec
  VF1 enp23s0v1 192.168.20.157 mlx4_2    49.48 Gbit/sec
  VF2 enp23s0v2 192.168.20.158 mlx4_3    49.30 Gbit/sec
  VF3 enp23s0v3 192.168.20.159 mlx4_4    50.50 Gbit/sec
  VF4 enp23s0v4 192.168.20.160 mlx4_5    49.96 Gbit/sec
  VF5 enp23s0v5 192.168.20.161 mlx4_6    49.48 Gbit/sec
  VF6 enp23s0v6 192.168.20.162 rocep23s0 50.18 Gbit/sec
  VF7 enp23s0v7 192.168.20.163 mlx4_7    50.52 Gbit/sec
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.50 -> 192.168.20.156-163`, RDMA MTU 2048. A post-test pvs3
  kernel warning scan returned no entries.
- Concurrent cross-host host-owned VF RoCEv2 `ib_write_bw` passes across all
  eight pvs3 VFs. Each VF used a distinct RDMA CM port and temporary
  source-based routing on pvs3 so replies used the matching VF netdev:

  ```text
  VF0 enp23s0v0 192.168.20.156 port 18515 6.70 Gbit/sec
  VF1 enp23s0v1 192.168.20.157 port 18516 6.65 Gbit/sec
  VF2 enp23s0v2 192.168.20.158 port 18517 6.76 Gbit/sec
  VF3 enp23s0v3 192.168.20.159 port 18518 6.65 Gbit/sec
  VF4 enp23s0v4 192.168.20.160 port 18519 6.74 Gbit/sec
  VF5 enp23s0v5 192.168.20.161 port 18520 6.64 Gbit/sec
  VF6 enp23s0v6 192.168.20.162 port 18521 6.64 Gbit/sec
  VF7 enp23s0v7 192.168.20.163 port 18522 6.80 Gbit/sec
  ```

  A post-test pvs3 kernel warning scan returned no entries. A prior local
  all-VF concurrency attempt without unique RDMA CM ports was invalid because
  multiple `ib_write_bw` servers tried to bind the same listen port.
- Twelve-VF SR-IOV mode is validated after changing `NUM_VFS=12` and
  rebooting. The card reported `sriov_totalvfs=32`, `sriov_numvfs=12`, and all
  twelve host-owned VF netdevs exposed IPv4 RoCEv2 GID index `3`. Sequential
  cross-host RoCEv2 `ib_write_bw` from `pvs1` to all twelve pvs3 VFs passed:

  ```text
  VF0  enp23s0v0  192.168.20.156 mlx4_1    49.66 Gbit/sec
  VF1  enp23s0v1  192.168.20.157 mlx4_2    50.55 Gbit/sec
  VF2  enp23s0v2  192.168.20.158 mlx4_3    49.50 Gbit/sec
  VF3  enp23s0v3  192.168.20.159 mlx4_4    50.65 Gbit/sec
  VF4  enp23s0v4  192.168.20.160 rocep23s0 49.79 Gbit/sec
  VF5  enp23s0v5  192.168.20.161 mlx4_5    50.54 Gbit/sec
  VF6  enp23s0v6  192.168.20.162 mlx4_6    49.51 Gbit/sec
  VF7  enp23s0v7  192.168.20.163 mlx4_7    49.69 Gbit/sec
  VF8  enp23s0v8  192.168.20.164 mlx4_8    49.94 Gbit/sec
  VF9  enp23s0v9  192.168.20.165 mlx4_9    50.58 Gbit/sec
  VF10 enp23s0v10 192.168.20.166 mlx4_10   49.54 Gbit/sec
  VF11 enp23s0v11 192.168.20.167 mlx4_11   49.68 Gbit/sec
  ```

  A post-test pvs3 kernel warning scan returned no entries. This is the largest
  VF count currently expected to preserve one IPv4 RoCEv2 GID for every VF with
  the patch's below-64 source GID index limit.
- Stock inbox `nvme-rdma` initiator on `pvs3` can discover and connect to the
  existing pvs1 NVMe/RDMA target over RoCEv2:

  ```sh
  nvme discover -t rdma -a 192.168.20.51 -s 4420
  nvme connect -t rdma -n schemesec:nvme:rg-pve0 -a 192.168.20.51 -s 4420
  nvme list
  nvme disconnect -n schemesec:nvme:rg-pve0
  ```

  Discovery returned `schemesec:nvme:rg-pve0`; connect created
  `/dev/nvme1n1` as a 3.76 TB Linux NVMe target using 12 I/O queues. A
  read-only identify/size check completed, the controller disconnected cleanly,
  and a pvs3 kernel warning scan returned no entries.

- `preflight-upgrade.sh` passed on kernel `7.0.2-6-pve` with zero warnings and zero failures: `mlx4_core`, `mlx4_en`, and `mlx4_ib` resolved from `updates/cx3pro-inbox-rocev2`, while `rdma_cm`, `nvme_rdma`, and `nvmet_rdma` remained stock inbox modules from the kernel tree.
- After reboot into kernel `7.0.2-6-pve`, the compact VF RoCEv2 GID layout was validated with `NUM_VFS=12`, `MLX4_ROCE_PF_GIDS=8`, and two RoCEv2 GIDs per host-owned VF. `verify-pve7.sh` passed with stable VF MACs, VLAN 20 on all twelve VFs, PF VLAN IPs `192.168.10.56/24` and `192.168.20.56/24`, module resolution from `updates/cx3pro-inbox-rocev2`, and no bounded kernel warning matches. Sequential cross-host RDMA-CM RoCEv2 `ib_write_bw` from pvs1 `192.168.20.50` to pvs3 VF IPs `192.168.20.160-171` passed for all twelve VFs using local VF GID index `1`; results were 49.41-50.61 Gbit/sec average with IPv4-mapped RoCEv2 GIDs. The test used coupled listener/client orchestration with a three-second listener warm-up so approval delay could not invalidate the RDMA-CM run. A post-test pvs3 kernel scan for `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`, `__warn`, `Bad wc`, `Completion with error`, `Failed status`, and `vhcr command:0x3a` returned no entries.

## Fresh rollback validation, 2026-05-23

Validated from `rpool/ROOT/pve-1@fresh-install` booting kernel `7.0.2-6-pve` with repository commit `7e22b3a`:

- `cx3pro-install` confirmed ConnectX-3 Pro firmware `2.42.5000` without flashing, and the full-install dependency path was updated so the documented later `install-pve7.sh --no-apt` build has `flex`, `bison`, and related kernel build tools available.
- `install-pve7.sh` rebuilt and installed patched inbox `mlx4_core`, `mlx4_en`, and `mlx4_ib` modules with matching vermagic and symbol CRC checks; after reboot all resolve from `updates/cx3pro-inbox-rocev2`.
- `rocesetup` now persists PF MTU 9000, VLAN20 source routing, and disables IPv6 only on its managed VLAN subinterfaces by default. This prevents duplicate unused VLAN link-local GID registration that previously produced `MLX4_CMD_SET_PORT` (`vhcr command:0xc`) status `-22` and `add_roce_gid` errors at boot.
- After the corrected reboot, `verify-pve7.sh` passes with active PF/VF RDMA links, stable MACs and VLAN 20 on all 12 VFs, persistent PF VLAN addresses, firmware `2.42.5000`, and no `vhcr`, GID-add, mlx4 warning, symbol, or call-trace matches.
- PF inbound RoCEv2 RDMA-CM `ib_write_bw` from pvs1 to `192.168.20.56` passed at `49.63 Gbit/sec`. VF0 passed individually in both listener forms at `49.57-49.61 Gbit/sec`; a longer inbound run to VF4 passed at `50.09 Gbit/sec`.
- All twelve pvs3 VFs successfully initiated reverse-direction RDMA-CM connections to pvs1 after reboot, and the post-traffic pvs3 Mellanox/GID/VHCR scan returned no entries.

## Traffic priority validation, 2026-05-24

- A paired sequential pvs1-initiated sweep to all twelve pvs3 VFs passed without RDMA-CM failure at `49.38-50.67 Gbit/sec`; the earlier sequence failure did not reproduce once each listener and client were started together. A post-sweep pvs3 kernel scan returned no Mellanox, GID-add, completion, or call-trace entries.
- Reverse-direction tests initially reproduced inconsistent throughput: the PF and some VFs reached approximately `50 Gbit/sec`, while VF1 and VF3-VF6/VF8 completed at `10-18 Gbit/sec`. `ethtool -S enp23s0` showed incoming RoCE traffic on priority 3 but outgoing test traffic on priority 0.
- Applying PF VLAN egress mapping `0:3` and VF VLAN `qos 3` at runtime moved outgoing traffic to priority 3. Previously slow VF1/VF3/VF4/VF8 then passed at `49.79-50.45 Gbit/sec`, PF passed at `49.74 Gbit/sec`, and no relevant kernel errors were logged. `rocesetup` and `sriov_setup` now persist this as `ROCE_PCP=3` by default, and `verify-pve7.sh` checks it.
- After deploying commit `cd5a811` and rebooting, `verify-pve7.sh` passed with both PF VLAN interfaces mapped to PCP `3` and all twelve VFs reporting VLAN 20 `qos 3`. A complete reverse PF plus twelve-VF sweep passed at `49.66-50.49 Gbit/sec`; post-reboot regression checks on formerly slow VF1, VF4, and VF8 passed at `50.35-50.70 Gbit/sec`, with `tx_prio_0_packets=0`, traffic counted under priority 3, and no matching kernel errors.
- On that corrected boot, stock inbox `rdma_cm` and `nvme-rdma` from kernel `7.0.2-6-pve` successfully discovered and temporarily connected to `schemesec:nvme:rg-pve0` at `192.168.20.51:4420` over the PF VLAN RoCEv2 route. The read-only validation exposed a 3.76 TB namespace with 12 I/O queues and disconnected cleanly; `nvme-cli` is now included in the fresh-install userspace tooling.
- Comparing the endpoints showed `pvs1` already persisted and enabled PFC on priority 3, while `pvs3` had PCP tagging active but PFC disabled on all priorities. `rocesetup` now enables and persists PF PFC on `ROCE_PCP` by default (`ROCE_PFC=1`), and `verify-pve7.sh` fails if the configured RoCE priority is not PFC-enabled.
- After deploying commit `d787252` and rebooting, `pvs3` reported `prio-pfc ... 3:on`, the verifier passed, VF1 reverse RoCEv2 traffic passed at `50.05 Gbit/sec`, and stock NVMe/RDMA discovery/connect/disconnect continued to pass. The post-test NIC counters reported transmitted data only on priority 3 and the bounded kernel scan returned no entries.

Remaining observation:

- The host logs recurring corrected APEI PCIe errors for NVMe endpoint vendor `15b7`, device `5002`, separate from the Mellanox `15b3:1007` adapter.

Not yet repeated after the latest clean inbox-patch boot:

- Cross-host VF `ib_write_bw` from a VM-assigned passthrough VF.

Note: an earlier PF run failed with completion status 12 while pvs3 was at
MTU 1500 and the test negotiated RDMA MTU 1024. Re-running after restoring
`enp23s0`, `enp23s0.10`, and `enp23s0.20` to MTU 9000 passed.

Previously observed and fixed:

- VF reprobe from `cx3pro-sriov-vfs.service` used to trigger `ib_core`
  `ib_free_cq` / `rdma_restrack_clean` WARNs through `mlx4_ib_remove`.
  Commit `8dea678` fixes this by destroying nested RoCEv2 GSI QPs for all SQP
  owners, including tunnel/proxy QPs, before CQ teardown.

## Debian passthrough VF validation, 2026-05-24

- VM 100 on `pvs3` has VF11 (`0000:17:01.4`, MAC `02:9a:0a:d0:90:0b`, VLAN 20, QoS 3) passed through to Debian 13 kernel `6.12.88+deb13-amd64`.
- Stock guest `mlx4_ib` exposed only `IB/RoCE v1` GIDs. Three minimal guest changes were required: retain the VF RoCEv2 capability in `mlx4_core`, do not issue PF-owned RoCEv2 UDP port configuration from guest `mlx4_ib` while exposing RoCEv2-only GIDs, and prevent guest `mlx4_en` from requesting PF-owned global-pause state.
- Loading only the capability change reproduced a real failure: the guest `mlx4_ib` probe failed because the VF attempted PF-owned RoCEv2 port configuration. That partial patch was not retained as a working state.
- Using `mlx4_en pfctx=8 pfcrx=8` suppressed PF global-pause denial but failed simultaneous RDMA-CM connection tests. It is not the selected solution.
- With all three minimal guest patches loaded, `ens16` exposed IPv4 RoCEv2 GID index `1` for `192.168.20.171`, host PF PFC remained configured on PCP 3, guest module reload produced no new host denial or warning entries, and a single-shell concurrent `ib_write_bw` test from `pvs1` to the guest VF passed at `50.83 Gbit/sec` with IPv4-mapped RoCEv2 GIDs.
- The guest installer must list `mlx4_core`, `mlx4_en`, and `mlx4_ib` in `/etc/initramfs-tools/modules` before regenerating initramfs. Without this, Debian's dep-mode initramfs included patched core/IB but loaded stock `mlx4_en`, restoring the PF-denied global-pause request on boot. After explicitly including all three modules and rebooting, the loaded `mlx4_en` srcversion matched the patched module, the VF retained RoCEv2 GIDs and pause `off/off`, and the host boot scan contained only expected VF reset messages with no denial, VHCR failure, warning, or trace.
- VM 100 uses its existing OVMF/i440fx topology for this functional validation. Q35/PCIe passthrough remains a separate deployment-topology test; it is not required to explain the validated RoCEv2 data path above.
- After that corrected guest reboot, a single-shell dual-SSH `ib_write_bw` run between pvs1 and the Debian VF at `192.168.20.171` passed at `50.00 Gbit/sec` average with IPv4-mapped RoCEv2 GIDs and no new bounded host driver error entries.
- Using stock Debian `nvme-rdma` above the reboot-persistent guest VF patches, the guest successfully ran `nvme discover -t rdma -a 192.168.20.51 -s 4420`, connected `schemesec:nvme:rg-pve0`, listed its 3.76 TB namespace, and disconnected cleanly. This validates the target storage path through the passed-through RoCEv2 VF without replacing current NVMe/RDMA drivers.

## Inbox module update workflow validation, 2026-06-27

- Validation policy update: future entries should distinguish pre-upgrade,
  post-reboot, and post-upgrade states. A system is not considered working
  across a reboot or upgrade until `port-validation --stage post-reboot` and
  `port-validation --stage post-upgrade`, respectively, pass with the
  cross-host VF RDMA-CM traffic test enabled.
- Post-reboot issue follow-up: the apparent `Bad wc status 12` regression was
  reproduced on both PF and VF RoCEv2 while stale `ib_write_bw` listeners were
  present from aborted diagnostics. RoCE v1 over the same VLAN20 PF GIDs passed,
  local RoCEv2 on each host passed, and cleaning exact stale perftest processes
  restored wire RoCEv2. A clean PF RoCEv2 RDMA-CM run passed at `50.56
  Gbit/sec`, then `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0
  NUM_VFS=12 ./test_vf_rdmacm` passed for all 11 host-owned VFs and skipped
  VF11 assigned to `vfio-pci`. Results were `49.63-50.67 Gbit/sec`.
  `test_vf_rdmacm` now refuses pre-existing `ib_write_bw`/`ib_send_bw`
  processes by default and traps interrupts to clean its active listener.
- `preflight-upgrade.sh` now prints the exact validated Proxmox packaging ref
  for kernel `7.0.2-6-pve`:
  `87f22e55de30d73b83722b86790394564036b33c`.
- The known-ref map also covers the older tested kernel `7.0.2-2-pve`:
  `59dd19a1c4f66f932d222eac91f9f1454f9b10cc`.
- `find-pve-kernel-ref` was added and validated against both currently tested
  kernels:
  - `7.0.2-6-pve` -> `87f22e55de30d73b83722b86790394564036b33c`,
    `ubuntu-kernel` gitlink `69bb061d6b71ee9b43e6584cc16d2a8853e81fe6`,
    `zfsonlinux` gitlink `069198f9d5ca7876a4af06da2c42f848f0d0552e`.
  - `7.0.2-2-pve` -> `59dd19a1c4f66f932d222eac91f9f1454f9b10cc`,
    `ubuntu-kernel` gitlink `4081a41e751a25370006d1a3bd7d07cc85a91440`,
    `zfsonlinux` gitlink `c03fdf105caad6054c575270da9e39b28b050b9f`.
- `install-pve7.sh --apply-check-only --no-apt` was run without manually
  setting `PVE_KERNEL_REF`; the installer auto-selected the known ref above,
  reset the pve-kernel checkout to `87f22e5 update ABI file for
  7.0.2-6-pve (amd64)`, and applied
  `0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch` cleanly against
  source version `7.0.2`.
- `install-pve7.sh --build-only --no-apt` was run without manually setting
  `PVE_KERNEL_REF`; it used the same auto-selected ref, rebuilt
  `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko`, verified `7.0.2-6-pve`
  vermagic, and confirmed `mlx4_ib` symbol CRCs match the patched
  `mlx4_core` exports. Log:
  `/root/CX3Pro-inbox-driver-patch/logs/install-20260627-131522.log`.
- This fixes the earlier unsafe default where the installer could follow the
  current Proxmox repository branch and land on a newer source version such as
  `7.0.12` when the target host was still running `7.0.2-6-pve`.
- pvs3 root SSH key auth to pvs1 root was installed so repository tests that
  orchestrate both hosts can run directly from pvs3 without password prompts.
- `nvmet-vm-lab status` passed from the pvs3 repository using default
  batch-mode SSH. It confirmed the live pvs1 `null_blk` NVMe/RDMA target,
  pvs3 `nvme1` RDMA controller, VM 100 `scsi1` attachment, and clean bounded
  pvs1/pvs3 kernel error scans.
- `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12
  ./test_vf_rdmacm` now runs directly from pvs3 after installing pvs3 root key
  auth to pvs1. It passed for all 11 host-owned VFs and skipped VF11 because
  it is assigned to `vfio-pci`.

  ```text
  VF0  192.168.20.160 mlx4_0   50.85 Gbit/sec
  VF1  192.168.20.161 mlx4_1   49.63 Gbit/sec
  VF2  192.168.20.162 mlx4_2   50.38 Gbit/sec
  VF3  192.168.20.163 mlx4_3   50.20 Gbit/sec
  VF4  192.168.20.164 mlx4_4   50.80 Gbit/sec
  VF5  192.168.20.165 mlx4_5   49.40 Gbit/sec
  VF6  192.168.20.166 mlx4_6   50.02 Gbit/sec
  VF7  192.168.20.167 mlx4_7   49.63 Gbit/sec
  VF8  192.168.20.168 mlx4_8   49.33 Gbit/sec
  VF9  192.168.20.169 mlx4_9   49.51 Gbit/sec
  VF10 192.168.20.170 mlx4_10  50.07 Gbit/sec
  ```

  Post-test pvs1 and pvs3 scans found no matching driver warnings, completion
  errors, call traces, mlx4 failures, or stale `ib_write_bw`/`test_vf_rdmacm`
  processes.
- `JOURNAL_SINCE='2026-06-27 13:12:00' PF=enp23s0 NUM_VFS=12
  VF_VLAN=20 VLAN10_IP=192.168.10.56/24
  VLAN20_IP=192.168.20.56/24 ./verify-pve7.sh` passed after the direct
  RDMA-CM sweep and build-only check, including module override resolution,
  PF/VF RoCEv2 GIDs, VF VLAN/qos policy, PFC on PCP 3, PF VLAN egress mapping,
  and bounded kernel warning scan.
- `RUN_BUILD=0 JOURNAL_SINCE='2026-06-27 13:12:00' ./port-update-check`
  passed. The wrapper ran preflight, `find-pve-kernel-ref`, auto-pinned
  apply-check, runtime verifier, and `nvmet-vm-lab status` without installing
  modules, rebooting, detaching VM disks, or running storage writes.

## Automated post-reboot validation, 2026-06-27

- Fresh boot tested: `c685c66f-4eeb-4178-a17f-98043460b7b1`, kernel
  `7.0.2-6-pve`, boot time `2026-06-27 15:22:08`.
- Installed boot fix: `cx3pro-rdma-postboot.service` now runs after
  `pve-guests.service`, waits 25 seconds for guest VF reset/probe activity,
  brings PF/VF netdevs up, reloads only `mlx4_ib`, waits for PF/VF RDMA links,
  and settles for 20 seconds.
- Evidence for the ordering: the earlier pre-guest reload still failed VF0
  with `Bad wc status 12`; a reload after VM 100 started and VF11 moved to
  `vfio-pci` made the full VF sweep pass; the automated service ordering then
  reproduced that pass after a clean reboot.
- VM 100 remained running with VF11 bound to `vfio-pci`; the host tested only
  VF0-VF10.
- Passing command:
  `CLIENT_SSH=root@192.168.1.50 CLIENT_DEV=rocep23s0 NUM_VFS=12 RUN_BUILD=0 RUN_NVMET_STATUS=0 EXPECT_BOOT_ID_CHANGED_FROM=cec43e65-b89d-42ea-894e-761130ad20dc ./port-validation --stage post-reboot`
- Passing log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260627-152336.log`.
- Validation result: `port-validation post-reboot: PASS`.
- VF RDMA-CM results:

  ```text
  VF0  192.168.20.160 mlx4_0   50.53 Gbit/sec
  VF1  192.168.20.161 mlx4_1   49.78 Gbit/sec
  VF2  192.168.20.162 mlx4_2   49.54 Gbit/sec
  VF3  192.168.20.163 mlx4_3   49.54 Gbit/sec
  VF4  192.168.20.164 mlx4_4   50.45 Gbit/sec
  VF5  192.168.20.165 mlx4_5   49.81 Gbit/sec
  VF6  192.168.20.166 mlx4_6   49.24 Gbit/sec
  VF7  192.168.20.167 mlx4_7   50.20 Gbit/sec
  VF8  192.168.20.168 mlx4_8   49.56 Gbit/sec
  VF9  192.168.20.169 mlx4_9   49.78 Gbit/sec
  VF10 192.168.20.170 mlx4_10  50.49 Gbit/sec
  ```

- `verify-pve7.sh` inside the gate passed module override resolution,
  `enable_mfunc_roce_v2=Y`, PF/VF RoCEv2 GIDs, VF VLAN 20/QoS 3 policy,
  VF11 passthrough accounting, PFC on PCP 3, PF VLAN egress mapping, and a
  bounded kernel warning scan.

## Proxmox dist-upgrade and post-upgrade validation, 2026-06-28

- Clean rollback point created after a passing reboot gate:
  `rpool@pre-inbox-dist-upgrade-20260628-024359`.
- Pre-upgrade reboot validation passed on boot
  `84eea1f7-2ec8-4721-823b-61e5ded5529b`, kernel `7.0.2-6-pve`.
  Log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260628-024237.log`.
- Upgrade simulation selected target kernel `7.0.12-1-pve`; matching
  `proxmox-headers-7.0.12-1-pve` was installed explicitly before reboot.
- Exact target ref:
  `b8d87f8e97fa979f50d88673bd5be41de93ed2f3`; pinned source gitlink:
  `d873103e8ac3c51fbdb4be178bddb191af0f6a21`.
- Initial apply-check against `7.0.12` exposed an installer tooling bug: the
  script assumed the running kernel was the target and required target build
  files even for `--apply-check-only`.
- Fixed tooling:
  - `install-pve7.sh` maps `7.0.12-1-pve` to the exact Proxmox ref.
  - `install-pve7.sh --apply-check-only` no longer requires target
    `/boot/config` or `Module.symvers`.
  - `preflight-upgrade.sh` maps `7.0.12-1-pve`, so post-upgrade checks no
    longer warn about a missing known ref.
  - default `TESTED_KERNELS` includes `7.0.12-1-pve`.
- `KVER=7.0.12-1-pve PVE_KERNEL_REF=b8d87f8e97fa979f50d88673bd5be41de93ed2f3 ./install-pve7.sh --no-apt`
  built and installed the override. `mlx4_core.ko`, `mlx4_en.ko`, and
  `mlx4_ib.ko` all had matching `7.0.12-1-pve` vermagic, and `mlx4_ib` symbol
  CRCs matched patched `mlx4_core` exports. Log:
  `/root/CX3Pro-inbox-driver-patch/logs/install-20260628-034053.log`.
- Post-upgrade reboot validation passed on boot
  `d630fe38-0e9c-4ef4-a824-558e57d64127`, kernel `7.0.12-1-pve`.
  Log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-upgrade-20260628-034405.log`.
- VF RDMA-CM results after upgrade:

  ```text
  VF0  192.168.20.160 mlx4_0   50.14 Gbit/sec
  VF1  192.168.20.161 mlx4_1   49.66 Gbit/sec
  VF2  192.168.20.162 mlx4_2   49.94 Gbit/sec
  VF3  192.168.20.163 mlx4_3   49.38 Gbit/sec
  VF4  192.168.20.164 mlx4_4   49.66 Gbit/sec
  VF5  192.168.20.165 mlx4_5   49.28 Gbit/sec
  VF6  192.168.20.166 mlx4_6   50.57 Gbit/sec
  VF7  192.168.20.167 mlx4_7   49.54 Gbit/sec
  VF8  192.168.20.168 mlx4_8   49.60 Gbit/sec
  VF9  192.168.20.169 mlx4_9   50.39 Gbit/sec
  VF10 192.168.20.170 mlx4_10  49.60 Gbit/sec
  ```

- VF11 remained assigned to `vfio-pci` and was skipped by host VF testing.
- Follow-up `RUN_BUILD=0 RUN_VERIFY=1 RUN_NVMET_STATUS=0 KVER=7.0.12-1-pve
  JOURNAL_SINCE='2026-06-28 03:42:33' ./port-update-check` passed with zero
  warnings and zero failures.
- Package and service health after upgrade: `apt-get -s -f install` reported
  no repairs needed, `systemctl --failed` reported no failed units, and no
  stale `ib_write_bw` / `ib_send_bw` processes were present.
- `nvmet-vm-lab status` completed read-only. pvs1 target modules were loaded
  with no pvs1 errors since `2026-06-28 00:00:00`; VM 100 currently shows only
  the normal `sda` disk, so no NVMe/RDMA VM disk is attached after this
  upgrade pass.

## Rollback and re-upgrade validation, 2026-06-28

- Rebooted the current `7.0.12-1-pve` upgraded state and found a validation
  harness race: `port-validation` could start `verify-pve7.sh` while
  `cx3pro-rdma-postboot.service` was still reloading/settling `mlx4_ib`.
  `port-validation` now waits for that service before running
  `port-update-check`.
- After the harness fix, current-state post-reboot validation passed on boot
  `7c43a443-a78c-41fc-bfdd-14fd555fbf5e`, kernel `7.0.12-1-pve`. Log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260628-040514.log`.
  VF0-VF10 RDMA-CM passed at `49.52-50.70 Gbit/sec`; VF11 was skipped on
  `vfio-pci`.
- Rolled back `rpool/ROOT/pve-1` to
  `rpool/ROOT/pve-1@pre-inbox-dist-upgrade-20260628-024359`, booted
  `7.0.2-6-pve`, pulled the current GitHub repo, and validated the old
  baseline. Log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-reboot-20260628-040849.log`.
  VF0-VF10 RDMA-CM passed at `49.73-50.79 Gbit/sec`; VF11 was skipped on
  `vfio-pci`.
- Re-ran the Proxmox upgrade from the rolled-back root, explicitly installed
  `proxmox-headers-7.0.12-1-pve`, rebuilt and installed the mlx4 override for
  `7.0.12-1-pve`, removed the one-shot kernel pin, rebooted, and validated the
  upgraded state. Log:
  `/root/CX3Pro-inbox-driver-patch/logs/validation/post-upgrade-20260628-041618.log`.
  VF0-VF10 RDMA-CM passed at `49.39-50.54 Gbit/sec`; VF11 was skipped on
  `vfio-pci`.
- Final health after rollback/re-upgrade: `apt-get -s -f install` required no
  repairs, `systemctl --failed` showed no failed units, no stale
  `ib_write_bw`/`ib_send_bw` processes were present, and `mlx4_core`,
  `mlx4_en`, and `mlx4_ib` resolved from
  `/lib/modules/7.0.12-1-pve/updates/cx3pro-inbox-rocev2`.
- New validated rollback point:
  `rpool@post-rollback-reupgrade-validated-20260628-041821`. Snapshot
  inventory:
  `/root/CX3Pro-inbox-driver-patch/logs/post-rollback-reupgrade-zfs-20260628-041821.txt`.

## Update tooling hardening, 2026-06-28

- Added `lib/pve-kernel-refs.sh` as the shared tested-kernel/ref map for
  installer, preflight, rollback, and validation tooling.
- Added `check-mlx4-rocev2-source` as a post-apply semantic source check for the
  patched mlx4 RoCEv2/SR-IOV GID type plumbing.
- Fixed `check-mlx4-rocev2-source` to handle Proxmox submodule `.git` files and
  to discover the kernel source under a parent Proxmox packaging checkout.
- Added `upgrade-lifecycle` as a guarded/dry-run lifecycle command logger.
- Added optional `EXPECT_PVE_KERNEL_REF` and `STRICT_PREFLIGHT` reproduction
  gates to the update check path.
- Latest pinned non-installing update check passed with zero failures:

  ```sh
  STRICT_PREFLIGHT=1 \
  EXPECT_PVE_KERNEL_REF=b8d87f8e97fa979f50d88673bd5be41de93ed2f3 \
  RUN_BUILD=0 RUN_NVMET_STATUS=0 ./port-update-check
  ```

- Known residual notes: DKMS may skip side kernels when matching headers are not
  installed; `/usr/sbin/grub-probe: error: unknown filesystem` has appeared
  during grub generation but did not block successful boots.

## Return-to-stock dry-run, 2026-06-29

- Added `restore-stock-proxmox` as the explicit return-to-stock path.
- Dry-run on pvs3 showed it would disable/move:
  `cx3pro-rdma-postboot.service`, `cx3pro-sriov-vfs.service`,
  `/usr/local/sbin/cx3pro-apply-vf-vlans.sh`,
  `/usr/local/sbin/cx3pro-rdma-postboot.sh`,
  `/etc/modprobe.d/cx3pro-inbox-rocev2.conf`, the
  `cx3pro-inbox-rocev2` initramfs block, and
  `/lib/modules/7.0.12-1-pve/updates/cx3pro-inbox-rocev2`.
- It would then run `depmod 7.0.12-1-pve`, `update-initramfs -u -k
  7.0.12-1-pve`, and `systemctl daemon-reload`.
- The restore was not applied; the host remains on the patched inbox override.
