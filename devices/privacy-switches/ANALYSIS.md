# Privacy switches — ThinkSmart View CD-18781Y

## 1. Summary

There is **one** switch on this unit, not two: the camera lens shutter. Measured today, it does **not** mute the microphone — recordings either side of a flip sit at the same level. Stock drives it as an `EV_KEY` on the `gpio-keys` device, emitting `KEY_POWER`, and nothing in Android consumes that (wakefulness does not change when it is flipped). GPIO 86 exists in the stock DT as a `mute` key but appears unwired on this unit. Mainline's model — `SW_CAMERA_LENS_COVER` on GPIO 87 — is the right one for the shutter; the "mute" node can stay but should be documented as unpopulated.

## 2. Identity

- Stock DT (`soc/gpio_keys`): `camera_switch` on GPIO 87, `linux,code = <0x57>` (KEY_F11 as evdev names it), and `mute` on GPIO 86, `linux,code = <0x5b>` (KEY_HIRAGANA). Both `EV_KEY`, 15 ms debounce.
- Observed behaviour does not match either code: flipping the shutter produces **`KEY_POWER` (116)** on `/dev/input/event3` (`gpio-keys`), verified with a counted `getevent` capture (`evidence/shutter-keyevents-20261030.txt`, 12 `KEY_POWER` events for three flips, each a DOWN/UP pair ≈ 1 s apart).
- The input device advertises `KEY_F11`, `KEY_HIRAGANA`, `KEY_VOLUMEUP`, `KEY_POWER`, `KEY_SELECT`.
- Mainline: `camera-lens-cover` on GPIO 87 as `EV_SW`/`SW_CAMERA_LENS_COVER`; `mic-mute-swtich` on GPIO 86 as `EV_SW`/`SW_MICROPHONE_INSERT`.

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| Shutter line | GPIO 87, `ACTIVE_LOW`, debounce 15 ms | GPIO 87, `GPIO_ACTIVE_LOW` | yes |
| Shutter event type | `EV_KEY` / `KEY_POWER` (as delivered) | `EV_SW` / `SW_CAMERA_LENS_COVER` | mainline better |
| Mute line | GPIO 86, same shape | GPIO 86, `EV_SW` | both present, hardware absent |
| Idle level | pull-up on both | relies on tlmm default pull-up | yes |
| Rails or data cut | none | none | n/a |

**Pin-level reading is not possible on this kernel.** `/sys/kernel/debug/gpio` on stock reports a static value for these pins — the whole dump md5 is unchanged while volume-up is held, and 200 tight samples of `gpio86`/`gpio87` are byte-identical during two flips. So "which pin" rests on the DT plus the event evidence, not on a level read.

## 4. Stock behaviour — measured

- **Mic mute: none.** Two 8 s recordings at the same gain, one with the shutter open and one closed, in the same room: mean `-32.3 dB` / max `-0.0` versus mean `-34.2 dB` / max `-0.0` (`evidence/shutter-open.wav`, `evidence/shutter-closed.wav`). A ~2 dB difference is room noise, not a mute; a hardware mute would have dropped to the noise floor or to digital silence.
- **No screen toggle.** `mWakefulness=Awake` and `Display Power: state=ON` before and after a flip; the `KEY_POWER` is ignored.
- Capture path note: Android's own recorder delivers real signal, while the Termux:API recorder path produced 8 kHz digital silence. Use the former for any repeat measurement.
- No LED is tied to the switch; the RGB LEDs are userspace-driven (`leds`).

## 5. Mainline state

- Both switches are modelled as `EV_SW`, correct for sliders. `SW_CAMERA_LENS_COVER` is a proper upstream code.
- `SW_MICROPHONE_INSERT` is semantically wrong (it means "a mic was plugged") but is the best code available; the DTS comment concedes this.
- Because the hardware mute does not exist here, the DTS comment "It is a hardware mute switch" is **wrong for this unit** and should be corrected.
- Neither switch is a wakeup source; with no working mute switch that is now the right call for GPIO 86, and for GPIO 87 it is a policy choice.

## 6. Gap and plan

1. Correct the DTS comment and mark the `mic-mute-swtich` node as unpopulated on this unit (keep it, it is inert).
2. Map the shutter for the desktop: a small listener turns `SW_CAMERA_LENS_COVER` into a bar indicator, and optionally into a screen toggle to match what users may expect from the stock `KEY_POWER` quirk.
3. Camera integration: refuse to start a stream while the cover is closed. Test: `cam` with the shutter closed should error cleanly, not produce a black frame.
4. Confirm on the first mainline boot that GPIO 87 is the pin that moves (it is the only way to settle it, given the stock debugfs limitation). If it turns out to be 86, swap the two nodes.
5. Do not add `wakeup-source` to either switch unless a use for it appears.

## 7. Risks

- There is no hardware mute, so a crashed audio policy stack can leave the mic live with no physical fallback. That is a privacy property worth stating plainly.
- GPIO 86 being driven in the DT while unwired is harmless, but a future unit with the switch populated would behave differently — keep the node.
- The stock `KEY_POWER` quirk means keylayouts written against stock expectations may differ from mainline's `EV_SW` behaviour.
- Shutter state is not persisted anywhere; a reboot mid-stream resets it to "open" from the driver's point of view.

## 8. Open questions

- Is the shutter physically on GPIO 87 or 86? Only a mainline boot with both nodes active can settle it.
- Why does the stock kernel remap the shutter to `KEY_POWER` — a LineageOS patch, or a hidden vendor driver?
- Does the cover switch cut anything at all electrically (camera power, MIPI), or is it purely a signal?
- Was a mic-mute switch ever fitted to any CD-18781Y variant, or only to the reference design?

## 9. Sources

- `evidence/shutter-open.wav`, `evidence/shutter-closed.wav`, `evidence/shutter-keyevents-20261030.txt`, `evidence/stock-switch-gpio-state-20261030.txt`; live `getevent`, `dumpsys power`, `debugfs/gpio`.
- `../stock/stock-device-tree.dts:2690-2716`; GPL `apq8053-lite-dragon.dtsi:75-89`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:37-54`; `privacy-switches/BRIEF.md`.
