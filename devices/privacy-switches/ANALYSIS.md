# Privacy switches — ThinkSmart View CD-18781Y

## 1. Summary

There are **two** switches, as Lenovo's quick start guide shows: the camera privacy shutter on the top edge, towards the left (GPIO 87), and the **microphone mute slider** on the left edge, towards the top (GPIO 86). The mute slider is a **hardware mute**: in the top position the microphones deliver digital silence, whatever the software does.

> **Correction (2026-11-06).** This analysis first said the mute switch was not fitted. That came from flipping only the lens cover, which does not affect the mics. Flipping the left slider on mainline settled it; see §4. The stock-side measurements below are kept as recorded.

Stock drives a switch as an `EV_KEY` on the `gpio-keys` device, emitting `KEY_POWER`, and nothing in Android consumes that (wakefulness does not change when it is flipped). Mainline's model — `SW_CAMERA_LENS_COVER` on GPIO 87 and `SW_MICROPHONE_INSERT` on GPIO 86, both `EV_SW` — is right for both.

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
| Mute line | GPIO 86, same shape | GPIO 86, `EV_SW`, `GPIO_ACTIVE_LOW` | yes; high = muted |
| Idle level | pull-up on both | relies on tlmm default pull-up | yes |
| Rails or data cut | none | none | n/a |

**Pin-level reading is not possible on the stock kernel.** `/sys/kernel/debug/gpio` on stock reports a static value for these pins — the whole dump md5 is unchanged while volume-up is held, and 200 tight samples of `gpio86`/`gpio87` are byte-identical during two flips. On mainline it does move: `gpio86` reads `in high` with the mute slider at the top and `in low` at the bottom (2026-11-06).

## 4. Stock behaviour — measured

- **The lens cover does not mute the mics.** Two 8 s recordings at the same gain, one with the shutter open and one closed, in the same room: mean `-32.3 dB` / max `-0.0` versus mean `-34.2 dB` / max `-0.0` (`evidence/shutter-open.wav`, `evidence/shutter-closed.wav`). A ~2 dB difference is room noise. (This was first read as "no mic mute"; the mute slider itself was not flipped.)
- **The mute slider does (mainline, 2026-11-06).** 3 s recordings on `hw:0,1`, 2 ch, 48 kHz, listener stopped: slider at the top, both channels peak 0 (digital silence), `gpio86` high; slider at the bottom, both channels -49.6 dBFS RMS (room noise), `gpio86` low.
- **No screen toggle.** `mWakefulness=Awake` and `Display Power: state=ON` before and after a flip; the `KEY_POWER` is ignored.
- Capture path note: Android's own recorder delivers real signal, while the Termux:API recorder path produced 8 kHz digital silence. Use the former for any repeat measurement.
- No LED is tied to the switch; the RGB LEDs are userspace-driven (`leds`).

## 5. Mainline state

- Both switches are modelled as `EV_SW`, correct for sliders. `SW_CAMERA_LENS_COVER` is a proper upstream code.
- `SW_MICROPHONE_INSERT` is semantically wrong (it means "a mic was plugged") but is the best code available; the DTS comment concedes this.
- With `GPIO_ACTIVE_LOW`, `SW_MICROPHONE_INSERT` reads 1 while the mics are live and 0 while muted, which happens to fit the code's meaning ("a mic is present").
- The upstream DTS comment ("It is a hardware mute switch though, so mics will be muted even though it is not reflected in UI") is **right**. An earlier local patch replaced it with a wrong "not fitted" comment; that change has been dropped.
- Neither switch is a wakeup source; for both that is a policy choice.

## 6. Gap and plan

1. Show the mute state in the UI: the listener reads `SW_MICROPHONE_INSERT` and the screen shows "Microphone off" while the slider is up.
2. Map the shutter for the desktop: a small listener turns `SW_CAMERA_LENS_COVER` into a bar indicator, and optionally into a screen toggle to match what users may expect from the stock `KEY_POWER` quirk.
3. Camera integration: refuse to start a stream while the cover is closed. Test: `cam` with the shutter closed should error cleanly, not produce a black frame.
4. Confirm on the first mainline boot that GPIO 87 is the pin that moves (it is the only way to settle it, given the stock debugfs limitation). If it turns out to be 86, swap the two nodes.
5. Do not add `wakeup-source` to either switch unless a use for it appears.

## 7. Risks

- The hardware mute is the physical fallback: with the slider up, no software state can make the mics live.
- The stock `KEY_POWER` quirk means keylayouts written against stock expectations may differ from mainline's `EV_SW` behaviour.
- Shutter state is not persisted anywhere; a reboot mid-stream resets it to "open" from the driver's point of view.

## 8. Open questions

- Is the shutter physically on GPIO 87 or 86? Only a mainline boot with both nodes active can settle it.
- Why does the stock kernel remap the shutter to `KEY_POWER` — a LineageOS patch, or a hidden vendor driver?
- Does the cover switch cut anything at all electrically (camera power, MIPI), or is it purely a signal?
- Which stock switch produced the `KEY_POWER` events in §2: the shutter, or the mute slider?

## 9. Sources

- `evidence/shutter-open.wav`, `evidence/shutter-closed.wav`, `evidence/shutter-keyevents-20261030.txt`, `evidence/stock-switch-gpio-state-20261030.txt`; live `getevent`, `dumpsys power`, `debugfs/gpio`.
- `../stock/stock-device-tree.dts:2690-2716`; GPL `apq8053-lite-dragon.dtsi:75-89`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:37-54`; `privacy-switches/BRIEF.md`.
