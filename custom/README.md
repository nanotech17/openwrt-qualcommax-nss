# OpenWrt 25.12.6 with NSS for Linksys MX5300 and MX4200v1

**This is a personal custom build based on OpenWrt 25.12.6.** It is not an
official OpenWrt release and is not supported by the OpenWrt project or by the
authors of the NSS patches it uses. It is made for my own MX5300 and MX4200v1
and published in case it is useful to others.

This branch builds OpenWrt 25.12.6 with Qualcomm NSS offload (Ethernet, ECM and
Wi-Fi including 802.11s mesh) for two devices: the Linksys MX5300 and the
MX4200v1.

- Base: OpenWrt tag `v25.12.6` (kernel 6.12.112, mac80211 backports 6.18.55).
- NSS: the commits of [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq)
  `25.12-nss` (`d6848fa2ea`), rebased onto `v25.12.6`. That branch was based on
  an earlier 25.12 snapshot (kernel 6.12.91, backports 6.18.26).
- NSS firmware 11.4 (needed for NSS mesh), from qosmio/nss-packages
  `NSS-12.5-K6.x`.
- Feeds: the commits pinned by `v25.12.6`, plus the NSS feeds, all pinned in
  `custom/feeds.conf`.
- Images: see the Releases page of this repository.

## Contents

| Path | What |
|---|---|
| commits on this branch | rebase of the NSS patches, ported fixes, fixes of this build (below) |
| `custom/build.sh` | prepares the tree for one device and builds it |
| `custom/feeds.conf` | pinned feeds |
| `custom/configs/<device>.config` | one config per device |
| `custom/patches/nss_packages/` | patch for the nss_packages feed |
| `custom/files/<device>/` | files added to the image |

## Changes from qosmio `25.12-nss`

| Commit | Change |
|---|---|
| `qualcommax: NSS: rebase patches for 6.12.112` | Three patches taken from AgustinLorenzo/openwrt `0c375ad6fc` (6.12.95 rebase); the bonding LAG patch adapted to 6.12.112 |
| `ath11k_nss: rebase patches for backports 6.18.55` | Five patches adapted by hand (see the commit message), the rest refreshed |
| `ath11k_nss: fix AP_VLAN ext_vdev cleanup and open error path`, `ath11k_nss: drop memcpy workaround for mcast_rate` | Ported from qosmio/openwrt-ipq `main-nss` (not in `25.12-nss`) |
| `qualcommax: switch to wpad-openssl, libustream-openssl and apk-openssl` | Ported from AgustinLorenzo/openwrt `a9fd5032a7` |

## Fixes and settings of this build

| # | Change | Where | Devices |
|---|---|---|---|
| 1 | ath11k NSS mesh: drop "mpath not found" exception packets | commit on this branch (`package/kernel/mac80211/patches/nss/ath11k/999-990-...`) | both |
| 2 | Disable tx checksum offload on ath10k mesh interfaces too | commit on this branch (`disable_mesh_chksum_ath11k.hotplug`) | both (only matters with ath10k radios, i.e. the MX5300's QCA9984) |
| 3 | qca-nss-clients tunipip6: release the route in the encap exception path | `custom/patches/nss_packages/` (applied to the nss_packages feed) | both |
| 4 | Set ECM `accel_delay_pkts` to 24 at boot | `custom/files/mx5300/` | MX5300 only |
| 5 | One device per config, package selection | `custom/configs/<device>.config` | per device |

### 1. ath11k NSS mesh "mpath not found" exceptions

With 802.11s mesh offloaded to NSS, NSS returns a packet to the host when it has
no mesh path for the destination. The driver re-sent the packet after
`eth_type_trans()` had removed the Ethernet header. mac80211 then read the start
of the IP header as the destination MAC address and created bogus mesh paths
(`60:xx:...` for IPv6). These paths fill the NSS mesh path table. Once the table
is full, adding real paths fails too, and the log fills with
`failed to add an entry to mpath table`.

The fix drops these packets. They were never delivered before either. Path
discovery does not depend on them, because NSS reports a separate
`PATH_NOT_FOUND` event for that.

An alternative fix was tested first: keep the Ethernet header and re-send the
packet. Under load it made an MX5300 reset without any kernel message, so it is
not used.

Without this fix, restarting `wpad` (`/etc/init.d/wpad restart`) clears both
tables for a while, and so does a reboot.

### 2. ath10k mesh checksum offload

The NSS patches already turn off `tx-checksumming` on ath11k mesh interfaces.
ath10k mesh interfaces need the same workaround. With checksum offload on, TCP
over the mesh link fails or crawls while ping works.

### 3. tunipip6 (DS-Lite) dst leak

`nss_tunipip6_encap_exception()` did not release the route it looked up when it
passed a packet up to the stack. Every such packet leaked a dst entry, and
`ip_dst_cache` (SUnreclaim) grew without bound. The leak was large with
`accel_delay_pkts=24` on DS-Lite. The fix adds the missing `ip_rt_put()`.

### 4. `accel_delay_pkts=24` (MX5300 only)

The `qca-nss-ecm` init script writes `1` to
`/sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts` every time it
loads ECM. With `1`, ECM does not accelerate the DS-Lite tunnel or one-way UDP,
so that traffic stays on the CPU.

With `24`, ECM handles the first 24 packets of each connection on the CPU and
then accelerates the connection, even if traffic flows in one direction only.
`/etc/init.d/ecm-accel-delay` (START=27, after ECM) writes the value at boot. A
uci-defaults script enables it on the first boot, so the value is 24 after a
`sysupgrade` with or without kept settings.

Notes:

- Any value other than `1` applies the DSCP and mark seen in one direction to
  both directions. This can affect QoS classification and mwan3 or policy
  routing marks.
- On MAP-E, values other than `1` were seen to stall upstream UDP when a
  translated port was reused. Check this before using such a value on MAP-E.
- Restarting ECM (`/etc/init.d/qca-nss-ecm restart`) writes `1` again. Run
  `/etc/init.d/ecm-accel-delay start` afterwards.

### 5. Configs

Each config selects one device only, without `ALL_KMODS`.

- `mx5300.config`: a router package set (DS-Lite, MAP, PPPoE, WireGuard,
  `tailscale`, `adblock`, `collectd` with `luci-app-statistics`,
  `tcpdump-mini`, `conntrack`, ...).
- `mx4200v1.config`: a mesh node package set (`collectd` with
  `luci-app-statistics`, `lm-sensors`, `dawn`, `usteer`, `umdns`, `iperf3`).
  No `adblock`, `tailscale` or `tcpdump`.

Both configs set `CONFIG_KERNEL_BUILD_USER="builder"` and
`CONFIG_KERNEL_BUILD_DOMAIN="buildhost"`, and leave the `nss_packages` and
`sqm_scripts_nss` feeds out of `distfeeds.conf`.

## Testing

Tested on one MX5300 and one MX4200v1, with a Linksys E8450 (OpenWrt 25.12.5) as
the mesh peer and Linux hosts on the LAN and WAN sides (1 GbE).

| Test | MX5300 | MX4200v1 |
|---|---|---|
| DS-Lite (B4), TCP 1/4 streams, both directions | 915 Mbps, CPU about 1% (NSS) | 915 Mbps with `accel_delay_pkts=24` (see known issues) |
| DS-Lite, UDP 900 Mbit/s | no or 0.05% loss | same, with `accel_delay_pkts=24` |
| 802.11s mesh over ath11k (5 GHz, ch 36, HE80), NSS offloaded | 565-650 Mbps, CPU 1-2% | 516-634 Mbps, CPU 1% |
| 802.11s mesh over ath10k (QCA9984, ch 120, VHT80) | 609-643 Mbps | (no ath10k radio) |
| Mesh path deleted 20 times under load (fix 1) | no bogus paths, NSS path table not full | same |
| 10 minutes under load, mesh path deleted every 20 s | no reset, no kernel warnings | same |

The mesh throughput is limited by the E8450 as the iperf3 endpoint. The results
were the same as with the previous build of these devices
(AgustinLorenzo/openwrt based, kernel 6.12.94) in the same setup.

## Known issues

- **Dynamic MU-EDCA.** The NSS patch `203-mac80211-ath11k-fw-dynamic-muedca`
  adds `NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS` and `NL80211_ATTR_HE_MUEDCA_PARAMS`
  at the end of the kernel's nl80211 enums, and the hostapd patch `900` adds
  them at the end of hostapd's copy of `nl80211.h`. The two copies have
  different numbers of entries, so the numbers do not match and hostapd does
  not see the firmware's MU-EDCA updates. The beacons keep the configured
  MU-EDCA values, as in OpenWrt without NSS. This is the same in qosmio
  `25.12-nss`.
- **DS-Lite on the MX4200v1.** The MX4200v1 image keeps the default
  `accel_delay_pkts=1`, so the DS-Lite tunnel is not accelerated by NSS and
  runs on the CPU (about 760 Mbps upload, UDP loss). Copy
  `custom/files/mx5300/` into the MX4200v1 build, or write `24` as in fix 4, if
  the MX4200v1 is used as a DS-Lite router.
- **Clock warning at boot on the MX5300.** `gcc_usb0_master_clk` and
  `gcc_usb1_master_clk status stuck at 'on'` with a `WARNING` from
  `clk-branch.c:87`. The previous build shows the same. No effect was seen.
- **Mesh path recovery.** After a mesh path is deleted by hand under load, it
  took about 35 seconds to come back in this test setup. The previous build
  behaved the same in the same setup.

## Building

On a host that can build OpenWrt (see the OpenWrt build system documentation):

```sh
git clone -b custom/v25.12.6-nss https://github.com/nanotech17/openwrt-qualcommax-nss.git openwrt
cd openwrt
custom/build.sh mx5300 -j$(nproc)      # or: custom/build.sh mx4200v1 -j$(nproc)
```

`custom/build.sh` does the following:

1. Writes `feeds.conf` from `custom/feeds.conf`.
2. Updates and installs the feeds.
3. Copies the nss-packages patch into the feed.
4. Puts `custom/files/<device>` in place as `files/`.
5. Copies the device config to `.config`.
6. Runs `make defconfig`, `make download` and `make`.

When switching devices in the same tree, just run it again with the other
device. The images are in `bin/targets/qualcommax/ipq807x/`.

## Installing

- From a running OpenWrt: use the `*-squashfs-sysupgrade.bin`
  (`sysupgrade <file>`, or LuCI). These Linksys devices have two firmware
  partitions. `sysupgrade` writes the inactive one, and
  `fw_setenv boot_part <1|2>` followed by `reboot` switches back to the other
  one.
- From the Linksys stock firmware: use the `*-squashfs-factory.bin`.
- Check the sha256 against `sha256sums` in the release.

When coming from a build without NSS, start with default settings
(`sysupgrade -n`) and keep software and hardware flow offloading and packet
steering off. The ECM init script turns packet steering off.

These images were tested on one device of each model only. Use them at your own
risk.

## License

Same as OpenWrt and the respective packages (mostly GPL-2.0). The patches in this
branch are under the license of the files they modify.
