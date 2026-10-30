# wifi

Status: everything that can be done without the Wi-Fi PSK is done and tested
on the device. Joining `yareyare-xd-mesh`, and the rekey, roam and router
restart tests, wait for the PSK (see "To test once a PSK is provided").

## Hardware and firmware: works as is

- QCA9379 hw1.0 on SDIO (`mmc1:0001:1`), `ath10k_sdio`. Probe on the baseline
  and on the patched kernel:
  `firmware ver WLAN.NPL.1.6-00163-QCANPLSWPZ-1 api 5 features wowlan,ignore-otp,mfp crc32 98f1a90a`,
  `board_file api 1 ... crc32 05c45515`, `htt-ver 3.52 wmi-op 4 htt-op 3 cal otp max-sta 32 raw 0 hwcrypto 1`.
- Image files (`/lib/firmware/ath10k/QCA9379/hw1.0/`): `firmware-sdio-5.bin`
  `148b1db2…58aafc`, `board.bin` `65767cca…bda7d4` (bdwlan30.bin). These match
  the README manifest. No board-2.bin is needed; ath10k falls back to board API 1.
- Container feature set `wowlan,ignore-otp,mfp`: Felix Kaechele, who added
  QCA9379 SDIO upstream, runs the same firmware with exactly these features
  (api 6, ath10k list 2026-02-17, message 016792). This is no longer just an
  inference; no change to `ath10k-fwpack.py` is needed.
- Board data regdomain is 0x0, so ath10k uses US (regpair 0x3a, FCC CTLs) and
  hints US to cfg80211. See "Regulatory".

## GTK rekey: kernel patch

`kernel/patches-wip/wifi/0101-wifi-ath10k-don-t-wait-for-security-indications-QCA9379-SDIO-does-not-send.patch`
(the commit message has the full reasoning).

- Upstream check (2026-10-30): `ath10k/mac.c` in ath-next, ath-current,
  wireless-next main and torvalds master is identical to our base. Waiting for
  `HTT_T2H_MSG_TYPE_SEC_IND` in `ath10k_install_key()` has been there since
  v3.12. No fix is merged. On the list: Richard Acayan's RFC "only wait for
  response to SET_KEY" (Feb 2026, 016781). Felix reports that it does not fix
  QCA9379 SDIO, and the maintainers (Jeff Johnson, Baochen Qiang) worry that a
  late indication would complete a later wait. David Heidelberg's RFC "skip
  completion wait for pairwise key removal" (Sep 2026, 017285) adds a
  hw_params flag for WCN3990 only. Neither covers group key replacement.
- Evidence of the firmware's behaviour: the 6.19 port's log
  (`ubuntu-thinksmart/research/wifi/inventories/dmesg-ath10k.txt`):
  - Every group rekey (each 600 s) times out on SET of the group key, and the
    station then deauthenticates.
  - Every roam times out on group and pairwise DISABLE (3 s + 3 s).
  - Installs right after association never time out.
- The patch:
  - Adds `hw_params.key_update_no_sec_ind`, set only for "qca9379 hw1.0 sdio".
  - With the flag, no wait for station group key SET (static WEP excepted) or
    for any DISABLE. Those keys are rx-only or being removed, so nothing
    transmits on them.
  - In that case it resets the HL per-TID last PN itself, as the indication
    handler would. Otherwise group-addressed frames under the new key are
    dropped as replays.
  - Other hardware keeps waiting for everything.
- The earlier 0101 and 0102 drafts are replaced. They applied to all
  hardware, the objection the list raised. Their 0102 also had broken
  `1/a/` and `2/b/` path headers and did not apply (this repo's git has
  `diff.mnemonicPrefix` on: generate patches with
  `--src-prefix=a/ --dst-prefix=b/`).
- Build: `WIP_CONFIG=0 streams/wifi/build-wifi.sh` → `kernel/build-wifi`
  (`#2 SMP PREEMPT Fri Oct 30 21:33:02 JST 2026`).
  - Built on the current accepted series (0001–0003, 0201–0204); 0101 also
    passes `git apply --check` on `kernel/linux-7.3` as the baseline has it,
    and on current ath-next.
  - `.config` is identical to the new `build-7.3`.
  - No compiler warnings.
  - checkpatch: 0 errors. The 4 warnings are quoted log lines and pipermail
    links; switch these to lore links before sending.
- Device test (one locked session; deploy, check, then back to baseline):
  - The running kernel was `/proc/version` `#2 … 21:33:02`, on a new boot_id.
  - The loaded `ath10k_core.ko` was the patched one (stripped sha256
    `4a0b26fb…`; baseline is `6a49dff8…`).
  - Probe is unchanged, JP applied, MAC permanent, and the scan found all 6
    mesh BSSIDs. `systemctl is-system-running` reported `running`, and no
    ath10k/cfg80211 warnings appeared.
  - The key path itself cannot run without joining a network.
  - Earlier attempts (before the deploy script's reboot fix) did not reliably
    run the intended kernel. They are not counted; these replace them.
- `kernel/config/wip-wifi.config` (`ATH10K_DEBUG`, `ATH10K_DEBUGFS`) is for the
  PSK test only, to see `sec ind` and the new "without waiting" debug lines.
  It is not proposed for the baseline.
- Known residual, same as upstream: the HL host replay check
  (`tids_last_pn`, ext TIDs only) does not track the key index. Frames sent
  under the old group key after the reset and before the AP switches keys can
  set a high last PN again. Watch for it in the PSK test (broadcast/multicast
  reception after a rekey). The real fix would use `HTT_RX_DESC_HL_INFO_KEY_ID_OCT`
  in `ath10k_htt_rx_pn_check_replay_hl()`.

## Regulatory (JP)

- Verified on the device: with `cfg80211 ieee80211_regdom=JP` (the old
  `/etc/modprobe.d/cfg80211.conf`), the boot-time user hint JP is intersected
  with ath10k's later US driver hint. The global domain becomes `98`, the phy
  follows its own US rules (ch 149–165 enabled), and a later `iw reg set JP`
  is ignored (tested: still `98`).
- Fix (earlier design, verified here): `tsv-wifi-regdom.service`
  is started by udev when the phy registers. It waits for ath10k's hint, then
  runs `iw reg set JP`, and the phy follows the global domain.
  `/etc/conf.d/wireless-regdom` holds JP, wireless-regdb's
  `85-regulatory.rules` is masked, and the modprobe option is removed.
- Result on every boot since (old baseline, new baseline, patched): `regulatory domain JP` from
  the service; `global country JP: DFS-JP`; ch 1–11 enabled (12/13 stay
  disabled, see below), 36–48, 52–64 DFS, 100–144 DFS, 149–173 disabled.
  `iw reg get` still lists `phy#0 country US`. That is the driver's saved copy,
  which cfg80211 no longer uses once the last request is a user hint; the
  channel list above is the effective one.
- Ch 12/13 stay disabled: with `REGULATORY_STRICT_REG` the phy never enables a
  channel its own US domain lacked. The mesh's 2.4 GHz radio is on ch 9.
- Firmware CTLs stay FCC (board data). Moving the firmware itself to MKK
  would need `CONFIG_ATH_REG_DYNAMIC_USER_REG_HINTS` (certification-onus,
  "say N"). Not proposed.

## MAC

- The permanent address from the chip's OTP is `94:08:53:2d:0b:e5`, the same
  as stock. ath10k would prefer DT `local-mac-address`, but a per-unit value
  does not belong in the board DTS, and the OTP value is stable across the
  four boots seen today.
- The `0e:a9:…` address seen before was NetworkManager's scan MAC
  randomization. `10-thinksmart.conf` now sets
  `wifi.scan-rand-mac-address=no` (`[device-wifi]`) and
  `wifi.cloned-mac-address=permanent` (`[connection-wifi]`), and
  `inject-wifi.sh` writes `cloned-mac-address=permanent` into the profile.
  On the device `wlan0` is `94:08:53:2d:0b:e5` after every boot.

## Time

`systemd-timesyncd` is enabled and active, and NetworkManager feeds DNS to
systemd-resolved (`dns=systemd-resolved`, Quad9 fallback). It has no route to
the internet until Wi-Fi is up (`System clock synchronized: no`). The clock
restarts at the same unsynced time (2026-10-19 ~02:34 JST) on every boot, so
file times on the device are meaningless until the first sync.

## Scan (2026-10-30, under JP)

`yareyare-xd-mesh` seen on 6 BSSIDs (single active scan; nothing joined):

| BSSID | Ch | MHz | Signal |
| --- | --- | --- | --- |
| 06:EB:B6:BB:8C:5E | 40 | 5200 | 100 |
| 0A:EB:B6:BB:8C:5F | 120 | 5600 (DFS) | 100 |
| 1A:EB:B6:BB:98:1B | 48 | 5240 | 85 |
| 1E:EB:B6:BB:98:1C | 104 | 5520 (DFS) | 75 |
| 02:EB:B6:BB:8C:5D | 9 | 2452 | 100 |
| 16:EB:B6:BB:98:1A | 9 | 2452 | 74 |

These are two mesh nodes (`…8C:5x` and `…98:1x`), each with 2.4 GHz plus two
5 GHz radios, all WPA2. Every channel is allowed under JP. A `_Guest` SSID
and a `yareyare-xd` SSID are also present.

## rootfs/scripts changes (for the integrator)

- `overlay/etc/conf.d/wireless-regdom` (JP), `overlay/etc/systemd/system/tsv-wifi-regdom.service`,
  `overlay/etc/udev/rules.d/90-tsv-wifi-regdom.rules`,
  `overlay/etc/udev/rules.d/85-regulatory.rules` → `/dev/null`,
  `overlay/usr/local/sbin/tsv-wifi-regdom`; removed `overlay/etc/modprobe.d/cfg80211.conf`.
- `overlay/etc/NetworkManager/conf.d/10-thinksmart.conf`: permanent MAC, no scan randomization.
- `inject-wifi.sh`: `--adb` mode (installs the profile on the running device
  over adb stdin, PSK never on a command line), `cloned-mac-address=permanent`,
  stricter SSID checks. Re-tested today with a dummy SSID and PSK: profile
  0600 root:root, autoconnect yes, permanent MAC; then deleted.
- `build-rootfs.sh`: chown `etc/conf.d/wireless-regdom` along with the other overlay files.
- `rootfs/README.md` needs (not edited here, to avoid clashing with other
  streams):
  - "System settings": replace `cfg80211 ieee80211_regdom=JP` with the
    regdom service.
  - "Wi-Fi": mention `--adb` and the permanent MAC.
  - Known gaps: drop "features is an inference" (see above) and "rekey patch
    not carried" once 0101 is accepted.

## Left on the device

- New baseline kernel running (`#3 SMP PREEMPT Fri Oct 30 21:18:21 JST 2026`; Image.gz, DTB and ath10k_core byte-identical to `build-7.3`), no `/boot/*.prev`.
- The userspace above is installed and active: the files from the overlay
  pushed as-is, `85-regulatory.rules` → `/dev/null`, and
  `/etc/modprobe.d/cfg80211.conf` removed. Originals are in `/root/wifi-backup/`.
  To undo, restore `/etc/modprobe.d/cfg80211.conf`, `/etc/conf.d/wireless-regdom`
  and `/etc/NetworkManager/conf.d/10-thinksmart.conf` from there, then remove
  `tsv-wifi-regdom.service`, `90-tsv-wifi-regdom.rules`,
  `85-regulatory.rules` and `/usr/local/sbin/tsv-wifi-regdom`.
- Removed the earlier empty
  `/etc/NetworkManager/system-connections/.tsv-inject-selftest.nmconnection.tmp`.
  There are no connection profiles.
- Removed the `.prev` kernel files and `/usr/lib/modules/*.prev.tar` that the
  test deploys left. `config-7.3.0-g732aa6846ff6-dirty` and
  `/usr/lib/modules/7.3.0-g732aa6846ff6-dirty` belong to another stream; they
  were left alone.
- Note: during an earlier attempt, a cpufreq soak (`measure.sh soak 600`) may
  have run on an old-base `build-wifi`. That kernel differed from the old
  baseline only in `ath10k_core.ko`.

## To test once a PSK is provided

1. Build with debug: `streams/wifi/build-wifi.sh` (`WIP_CONFIG=1`), then
   `SRC=wt-wifi kernel/deploy-to-device.sh --reboot build-wifi`. Run
   `echo 0x0000001a > /sys/module/ath10k_core/parameters/debug_mask` (MAC|HTT|WMI),
   or load it with `debug_mask=` at module load.
2. `rootfs/scripts/inject-wifi.sh --adb --ssid yareyare-xd-mesh --psk - < file`.
   Check: it joins by itself, `wlan0` uses `94:08:53:2d:0b:e5`, and it gets
   DHCP v4/v6. `timedatectl` shows "synchronized: yes" within a minute.
3. Reboot: it joins at boot with no action.
4. Rekeys: stay connected over at least 3 group rekeys (the log shows the AP
   uses 600 s). Expect "without waiting for sec ind" debug lines and no
   `failed to install key`, `failed to set key` or `deauthenticating`.
   Check whether any `sec ind` arrives late after a skipped wait.
5. Multicast after a rekey: from the laptop, `ip neigh flush` plus ping, mDNS
   (`avahi-browse`/`resolvectl query thinksmart.local`), and IPv6 RA
   (`ip -6 route`), each once 1–2 min after a rekey. This checks the PN-reset
   race above.
6. Roam: walk between the two nodes, or `nmcli dev wifi connect` by BSSID.
   Expect no 3 s DISABLE stalls (authentication within ~100 ms of the disconnect).
7. Router restart: power-cycle the mesh; it must reconnect by itself
   (`autoconnect-retries=0`).
8. Compare against the baseline kernel once, to confirm the drop on rekey still
   reproduces on 7.3 (expected: `failed to set key (n, ff:ff:ff:ff:ff:ff) … -110`
   then `deauthenticating`).
9. 24 h soak (GOAL), plus SSH over Wi-Fi.
