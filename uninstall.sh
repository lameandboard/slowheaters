#!/usr/bin/env bash
# uninstall.sh - Remove heater_slow Klipper extra
#
# Removes heater_slow.py from Klipper's extras directory and restarts Klipper.
#
# Usage:
#   bash uninstall.sh [--no-restart]
#
# Environment overrides:
#   KLIPPER_EXTRAS_DIR   path to klippy/extras/   (default: ~/klipper/klippy/extras)
#   KLIPPER_SERVICE      systemd service name      (default: klipper)

set -euo pipefail

KLIPPER_EXTRAS_DIR="${KLIPPER_EXTRAS_DIR:-${HOME}/klipper/klippy/extras}"
KLIPPER_SERVICE="${KLIPPER_SERVICE:-klipper}"
NO_RESTART=0

for arg in "$@"; do
    case "$arg" in
        --no-restart) NO_RESTART=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

DST="${KLIPPER_EXTRAS_DIR}/heater_slow.py"

if [ ! -f "$DST" ]; then
    echo "heater_slow.py not found at $DST — nothing to remove."
    exit 0
fi

rm "$DST"
echo "Removed: $DST"

if [ "$NO_RESTART" -eq 1 ]; then
    echo "Skipping Klipper restart (--no-restart)."
else
    echo "Restarting Klipper service: $KLIPPER_SERVICE"
    sudo systemctl restart "$KLIPPER_SERVICE"
    echo "Done."
fi
