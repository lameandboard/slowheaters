#!/usr/bin/env bash
# install.sh - Install heater_slow Klipper extra
#
# Copies heater_slow.py into Klipper's extras directory and restarts Klipper.
#
# Usage:
#   bash install.sh [--no-restart]
#
# Environment overrides:
#   KLIPPER_EXTRAS_DIR   path to klippy/extras/   (default: ~/klipper/klippy/extras)
#   KLIPPER_SERVICE      systemd service name      (default: klipper)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KLIPPER_EXTRAS_DIR="${KLIPPER_EXTRAS_DIR:-${HOME}/klipper/klippy/extras}"
KLIPPER_SERVICE="${KLIPPER_SERVICE:-klipper}"
NO_RESTART=0

for arg in "$@"; do
    case "$arg" in
        --no-restart) NO_RESTART=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

SRC="${REPO_DIR}/extras/heater_slow.py"
DST="${KLIPPER_EXTRAS_DIR}/heater_slow.py"

if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC not found." >&2
    exit 1
fi

python3 -m py_compile "$SRC" || { echo "ERROR: $SRC failed syntax check." >&2; exit 1; }

if [ ! -d "$KLIPPER_EXTRAS_DIR" ]; then
    echo "ERROR: Klipper extras directory not found: $KLIPPER_EXTRAS_DIR" >&2
    echo "Set KLIPPER_EXTRAS_DIR to the correct path and re-run." >&2
    exit 1
fi

cp "$SRC" "$DST"
echo "Installed: $DST"

if [ "$NO_RESTART" -eq 1 ]; then
    echo "Skipping Klipper restart (--no-restart)."
else
    echo "Restarting Klipper service: $KLIPPER_SERVICE"
    sudo systemctl restart "$KLIPPER_SERVICE"
    echo "Done."
fi
