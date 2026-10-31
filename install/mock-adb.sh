#!/bin/bash
# Stand-in for adb in the rehearsal: answers the two things install.sh asks after the reset
# ('devices -l', and the first-boot report script) from a prepared report file. It exercises the
# installer's check logic only; it proves nothing about a real first boot.
#   MOCK_ADB_REPORT  file with the key=value lines the report script prints on the unit
set -euo pipefail
case "${1:-}" in
    devices) echo "List of devices attached"
             echo "0123456789abcdef       device usb:1-8.3 product:thinksmart model:ThinkSmart_View device:cd-18781y transport_id:1" ;;
    -s) shift 2
        [ "${1:-}" = shell ] || { echo "mock-adb: only 'shell' is implemented" >&2; exit 1; }
        cat "${MOCK_ADB_REPORT:?}" ;;
    *) echo "mock-adb: '$*' not implemented" >&2; exit 1 ;;
esac
