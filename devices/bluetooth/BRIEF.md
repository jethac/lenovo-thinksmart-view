# Bluetooth

## What this is

The Bluetooth half of the QCA9379, on `&uart_5`, `compatible = "qcom-qca9379-bt", "qcom,qca6174-bt"`, through `hci_qca`.

## Done when

Pairs with a phone and a headset, plays A2DP audio, and has this unit's own BD address.

## Known so far

- rickx: works, A2DP tested, firmware loads at boot. Inventories in `../../ubuntu-thinksmart/research/bluetooth/`.

## Stock capture

- BT firmware files (rampatch and NVM, for example `rampatch_tlv*.tlv`, `nvm_tlv*.bin`) from `/vendor/firmware` or `/system/etc/firmware`, with hashes.
- Stock BD address (`/persist/bluetooth/*`, `getprop ro.boot.btmacaddr`, or the stock BT stack config).

## Questions

- Does mainline set the BD address, or does it come up as a default address that needs `btmgmt public-addr`?
- Enable GPIO and supplies for BT power: match stock and mainline.
- Coexistence with Wi-Fi on 2.4 GHz.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
