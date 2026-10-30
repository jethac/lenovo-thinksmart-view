# Bluetooth — ThinkSmart View CD-18781Y

## 1. Summary

The QCA9379 Bluetooth half is a UART-attached controller on `blsp2_uart0` (`uart_5`), reset line on GPIO 76, firmware `btfwnpla.tlv` (rampatch) plus `btnvnpla.bin` (NVM) in the `modem` partition. On stock **nothing kernel-side runs it**: the vendor HAL (`android.hardware.bluetooth@1.0-service-qti`, `naples_uart` transport) drives the UART and loads both blobs from userspace, so there is no `hci0` and no BlueZ involvement. BD address is OTP-programmed, `94:08:53:2D:0B:E6` — the Wi-Fi MAC's neighbour. Mainline uses `hci_qca`, which needs the blobs renamed, the address supplied, and the enable-line polarity confirmed.

## 2. Identity

- DT: `qca9379_bt` under `&uart_5`, `compatible = "qcom-qca9379-bt", "qcom,qca6174-bt"`, `enable-gpios = <&tlmm 76 GPIO_ACTIVE_HIGH>`.
- `qcom,qca9379-bt` has **no** `of_device_id` entry; `qcom,qca6174-bt` does (`hci_qca.c:2771`), and it selects the default `QCA_ROME` path. So the first compatible string is decorative.
- Stock BT node: `bt_qca9379`, `compatible = "qca,qca6174"`, `qca,bt-reset-gpio = <&tlmm 76 0>` (`../stock/stock-device-tree.dts`).
- Firmware, from the `modem` partition `/image`: `btfwnpla.tlv` 38248 B (`sha256 0fa3169e0db0…`), `btnvnpla.bin` 2172 B (`sha256 4e36326d644a…`). Copies in `evidence/`.
- BD address: `94:08:53:2D:0B:E6` from `BluetoothManagerService` (`evidence/stock-bt-address-logcat-20261030.txt`). OUI 94:08:53 is Qualcomm; Wi-Fi is `…:0B:E5`. Device name `Lenovo StarView`.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| UART | `blsp2_uart0` = `7aef000`, `uart_5`, 4-wire | `&uart_5` okay with `qca9379_bt` child | yes |
| Pins | GPIO 16-19, `blsp_uart5` | inherited | yes |
| Reset/enable | GPIO 76, `qca,bt-reset-gpio`, ACTIVE_HIGH | `enable-gpios` ACTIVE_HIGH | names differ |
| Live pad state | `out 0`, 2 mA, pull down (BT idle-running) | driver pulses 0→1 at open, leaves high | **to verify** |
| Sleep clock | `clocks = <&sleep_clk>` | same | yes |
| Firmware load | userspace HAL | `hci_qca` + `btqca` in kernel | different |
| BD address | OTP, read by controller | nothing in DT | gap |

## 4. Stock behaviour

- Management is entirely userspace. `bluetooth-1.0-service-qti` (pid 482) owns the UART, and `com.android.bluetooth` sits behind it. `logcat` shows continuous `IBS_WAKE_IND`/`IBS_SLEEP_IND` arbitration, i.e. the controller is alive, paired to the HAL, and idling.
- Consequences: no `/sys/class/bluetooth/hci0`, no `dmesg` HCI lines, no `hciconfig`/`btmgmt` binaries. Any address reading has to go through the Android service.
- `/persist/bluetooth/` exists but is empty, and there is no `btmacaddr` property, so the address is not persisted in a file — the controller reports it from OTP.
- The GPL `wcnss` pinctrl states include gpio76 in a 5-pin group (76-80) with pull-up and 6 mA, but those states belong to the unused WCNSS path; the live owner of pin 76 is a pinctrl hog at output-low.

## 5. Mainline state

- `uart_5` is enabled with the BT child node; the QCA firmware path exists in `btqca`.
- `enable-gpios` is present but only acted on in the non-Rome `default` case: `GPIOD_OUT_LOW` at probe, then a 0→1 pulse with the line left **high**. The live stock line is **low** while BT works. One of the two is wrong; it must be measured, not guessed.
- No `local-bd-address` in the DTS. `hci_qca` expects the address from the bootloader/DT (there is a `qcom,local-bd-address-broken` quirk for byte-order bugs), and stock has none.
- Firmware names: `btqca` asks for `qca/rampatch_*.tlv` and `qca/nvm_*.bin` by chip type. `qca9379` is not a known `btqca` type, so the names have to be supplied via `firmware-name` in the node (two entries: nvm, then rampatch per the binding).

## 6. Gap and plan

1. Ship the two blobs as `qca/nvm_btnvnpla.bin` and `qca/rampatch_btfwnpla.tlv` and reference them from `firmware-name` in the node (binding order is nvm first).
2. Flip `enable-gpios` to `GPIO_ACTIVE_LOW` **only if** the first boot proves BT dead with the driver's high idle level. Test with `busctl`/`bluetoothctl` and `dmesg | grep -i qca`.
3. Set `local-bd-address = [e6 0b 2d 53 08 94]` (little-endian byte order as the binding wants) so the unit keeps its identity, and use `qcom,local-bd-address-broken` if the controller reports it byte-swapped.
4. Check `max-speed`: the vendor stack runs the UART at high speed after rampatch; without a `max-speed` the kernel may stay at 115200 and A2DP will stutter.
5. Test: pair with a phone, pair with the WH202A headset used by the prior port, play A2DP, and confirm the address with `btmgmt info`.
6. Wi-Fi coexistence: BT and Wi-Fi share the chip, so run the A2DP test with Wi-Fi associated on 2.4 GHz and 5 GHz and compare.

## 7. Risks

- A wrong `enable-gpios` polarity means the controller never leaves reset and BT looks broken with no obvious error.
- Rampatch and NVM must match; a mismatched NVM gives a controller that answers basic HCI but fails to page/stream.
- GPIO 76 is also in the unused WCNSS pin group — enabling the WCNSS path later would fight the BT driver for it.
- Losing the OTP address means every pair on the phone has to be redone.

## 8. Open questions

- Is GPIO 76 an active-low reset or an active-high enable? Read the pad in both states on mainline, or probe continuity to the module's EN/RESET_N.
- Does the controller accept `hci_qca`'s ROM-patch flow at all, or does it need the vendor `hci_qca`-incompatible sequence the HAL uses?
- Is `qca9379` distinguishable from `qca6174` by HCI version/features, and does `btqca` pick the right patch size for it?
- Is the address really OTP, or is `BluetoothManagerService` reading a copy the HAL cached at first boot?

## 9. Sources

- Live 2026-10-30: `logcat` (address, IBS traffic), `ps`, `/sys/kernel/debug/gpio`, `debugfs/pinctrl`; `evidence/stock-bt-*.txt`.
- Firmware: `../backup-20261029/partitions/modem.img.zst` → `evidence/stock-{rampatch-btfwnpla.tlv,nvm-btnvnpla.bin}`.
- `../stock/stock-device-tree.dts` (`bt_qca9379`, `wcnss_*` pinctrl groups).
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:182-188`; `drivers/bluetooth/hci_qca.c:1805-1818,2385-2470,2765-2780`; `Documentation/devicetree/bindings/net/bluetooth/qcom,bluetooth-common.yaml`.
- `bluetooth/BRIEF.md`.
