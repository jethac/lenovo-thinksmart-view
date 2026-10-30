# Buttons — ThinkSmart View CD-18781Y

## 1. Summary

Two physical side keys on TLMM: GPIO 85 (volume up) and PM8953 `resin` (volume down, wired to the PON block, not a discrete button GPIO). There is **no** power button: the PM8953 `kpdpwr` line exists and probes but is not wired to a key; stock's `qpnp_pon` input device offers `KEY_POWER` only because the PON block always advertises it. Stock binds GPIO 85 to `KEY_VOLUMEUP` and GPIO 86/87 to the mute and shutter switches, all in one `gpio-keys` node with `INPUT_PROP 0`. Mainline 7.3 already has vol-up on GPIO 85 with `wakeup-source` and vol-down on `&pm8953_resin`, `pwrkey` disabled. The gap is small: confirm both keys wake the panel, confirm long-press semantics, and keep `pwrkey` disabled with a comment explaining why.

## 2. Identity

- Volume up: `vol_up` node, `gpios = <&tlmm 85 GPIO_ACTIVE_LOW>`, `linux,code = <KEY_VOLUMEUP>` (stock DT `…/soc/gpio_keys/vol_up`, GPL `apq8053-lite-dragon.dtsi:91-97`).
- Volume down: PM8953 `qcom,power-on@800` `qcom,pon_2`, `qcom,pon-type = <1>` (resin), `linux,code = <KEY_VOLUMEDOWN>` (`stock-device-tree.dts:10449-10453`).
- Power: `qcom,pon_1` (`pon-type = 0`, kpdpwr) is present with `linux,code = <KEY_POWER>`; stock exposes `KEY_POWER` on the `qpnp_pon` input device, but see §3/§4 — no key is wired to it. Observation: GPL and mainline agree on this node.
- Live evidence: three keys in one `gpio-keys` device with `EV=3` (EV_SYN|EV_KEY) and `PROP=0`, `/devices/soc/soc:gpio_keys/input/input3`. Measured 2026-10-30: the shutter on that device emits `KEY_POWER` (not its DT code), and flipping it does not change wakefulness — see `../privacy-switches/ANALYSIS.md` §2/§4. (`evidence/stock-getevent-lp-20261030.txt`, `evidence/stock-keylayout-input-devices-20261030.txt`).

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| Volume up GPIO | TLMM 85, `GPIO_ACTIVE_LOW`, pull-up, 15 ms debounce | TLMM 85, `GPIO_ACTIVE_LOW`, `wakeup-source` | yes (mainline adds wakeup) |
| Volume down | PM8953 resin, `pon_2`, `KEY_VOLUMEDOWN` | `&pm8953_resin`, `KEY_VOLUMEDOWN`, `wakeup-source`, `okay` | yes (mainline adds wakeup) |
| Power key | `pon_1` present, `KEY_POWER`, no GPIO | `pwrkey { status = "disabled" }` | yes in effect |
| gpio-keys property set | `pinctrl-0/1` `tlmm_gpio_key_active/suspend`, 2 mA, pull-up, `input-name = "gpio-keys"` | no pinctrl on the node (tlmm defaults) | minor difference; mainline relies on default pull-up |

Observed pin state, all idle high with pull-up, so the switches short to ground and `GPIO_ACTIVE_LOW` is correct (`evidence/stock-switch-gpio-state-20261030.txt`):
`gpio85: in 0 2mA pull up`, `gpio86`, `gpio87` the same. Mainline DTS comment already notes only Volume Up and Volume Down exist.

## 4. Stock behaviour

- `gpio-keys` driver creates one input device carrying `KEY_VOLUMEUP`, `KEY_MUTE` (86) and `KEY_SWITCHVIDEOSOURCE` (87). All three are `EV_KEY` with 15 ms debounce, and stock marks the device `wakeup` capable (`H: Handlers=event3 keychord`).
- `/vendor/usr/keylayout/gpio-keys.kl` maps only `key 115 VOLUME_UP` and `key 172 HOMEPAGE`; 0x57 (87) would become HOMEPAGE. In practice the shutter arrives as `KEY_POWER` and no keylayout entry consumes it, so Android ignores it. This is the mismatch with mainline, which exposes both as `EV_SW`.
- `/vendor/usr/keylayout/qpnp_pon.kl` maps `key 116 POWER` and `key 114 VOLUME_DOWN`. So stock does route the resin to volume down, matching mainline.
- Power-key handling: `qpnp_pon` advertises `KEY_POWER` and `KEY_VOLUMEDOWN`; the resin path is the one actually exercised. Note that `KEY_POWER` also arrives from the camera shutter entry (see `../privacy-switches/`), so `KEY_POWER` alone does not identify a power key on this device. Long-press behaviour on stock is the standard `qpnp_pon` `system-reset` (`qcom,system-reset`, `pon-dbc-delay = 0x3d09`) — a long resin hold resets the unit, the same as a smartphone power key.
- **Inference**: `pon_1` is `qcom,system-reset` capable but no key reaches kpdpwr, so a 10 s hold on volume-down is the only reset gesture. This matches the "no power button" reading and is why mainline disables `pwrkey`.

## 5. Mainline state

- `gpio-keys`: volume-up on GPIO 85 with `wakeup-source`; yes.
- `&pm8953_resin`: `KEY_VOLUMEDOWN` with `wakeup-source`, enabled; yes.
- `&pm8953_pon` `pwrkey`: disabled, with a one-line comment. Adequate, but the comment "Device doesn't have a power key" does not record *why* (probes fine, genuinely unwired) — worth extending.
- The `gpio-keys` node has no `pinctrl-0` pin-state of its own. The tlmm default leaves 85/86/87 with pull-up, which is what makes `ACTIVE_LOW` work; a board-level change that repurposes those pins would silently break the key.

## 6. Gap and plan

1. Extend the `pwrkey` comment to say kpdpwr is unwired but advertised by qpnp_pon, so nobody "fixes" it later.
2. Give `gpio-keys` an explicit `pinctrl-0` (`gpio_key_default`: 85,86,87, bias-pull-up, input) instead of relying on tlmm defaults. Test: boot, `grep gpio8[5-7] /sys/kernel/debug/gpio` shows `pull up` and `in`.
3. `evtest /dev/input/eventX` on the key device: press each of the two volume keys, expect exactly `KEY_VOLUMEUP`/`KEY_VOLUMEDOWN` with correct press/release.
4. With the panel blanked, press each key once; expect the screen to wake (the `wakeup-source` test, done on the real mainline boot, not stock).
5. Hold volume-down 10 s on a mainline boot and confirm the reset gesture still works through `qpnp_pon`.

## 7. Risks

- Leaving `pwrkey` enabled may add a phantom `KEY_POWER` that nothing consumes, and on some msm8953 units a floating kpdpwr can cause spurious wakeups or a reboot loop. Keep it disabled unless tested otherwise.
- The volume keys are the only reset gesture; a change that removes `wakeup-source` from resin also removes the ability to wake or reset a hung device with no other input.
- GPIO 85 is shared in the same node as the two privacy switches; moving it to its own node changes the stock-compatible input device layout, which some userspace keylayouts assume.

## 8. Open questions

- Whether kpdpwr is physically shorted to anything, or truly floating (would need a continuity check or a probe on `qpnp_kpdpwr_status` while pressing candidates).
- Whether the 15 ms debounce is enough for these particular tact switches on mainline; stock's value is only a starting point.
- Whether volume-down-as-resin long-press still triggers `system-reset` with `pwrkey` disabled.

## 9. Sources

- `evidence/stock-getevent-lp-20261030.txt`, `evidence/stock-keylayout-input-devices-20261030.txt`, `evidence/stock-switch-gpio-state-20261030.txt`.
- `../stock/stock-device-tree.dts:2687-2728,10435-10453`.
- Lenovo GPL `apq8053-lite-dragon.dtsi:68-98` (`_inventory/evidence/gpl-dts-apq8053-lite-dragon-201218.txt`).
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:34-66,325-336`.
- `../_inventory/ANALYSIS.md` §3 pinmux table; `buttons/BRIEF.md`.
