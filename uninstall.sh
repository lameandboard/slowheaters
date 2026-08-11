#!/bin/sh
# uninstall.sh - Remove the slow_heater Klipper extra for Vivid heaters.
# Copyright (C) 2026 slowheaters contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${KLIPPER_CONFIG:-"$HOME/printer_data/config/printer.cfg"}
EXTRAS_DIR=${KLIPPER_EXTRAS_DIR:-"$HOME/klipper/klippy/extras"}
TARGET_MODULE="$EXTRAS_DIR/slow_heater.py"
BACKUP_DIR="$SCRIPT_DIR/backups"
KLIPPER_SERVICE=${KLIPPER_SERVICE:-klipper}
CONFIG_CHANGED=0
MODULE_CHANGED=0

restart_klipper() {
    if [ "${SKIP_RESTART:-0}" = "1" ]; then
        echo "Skipping Klipper restart (SKIP_RESTART=1)."
        return
    fi

    echo "Restarting Klipper service: $KLIPPER_SERVICE"
    if command -v sudo >/dev/null 2>&1; then
        sudo systemctl restart "$KLIPPER_SERVICE"
    else
        systemctl restart "$KLIPPER_SERVICE"
    fi
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: printer config not found at $CONFIG_FILE" >&2
    exit 1
fi

echo "Scanning $CONFIG_FILE for [slow_heater Vivid_*] sections..."
LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'vivid-heaters-*.cfg' 2>/dev/null | sort | tail -n 1 || true)

if [ -n "$LATEST_BACKUP" ]; then
    echo "Using backup file: $LATEST_BACKUP"
else
    echo "No Vivid heater backup was found in $BACKUP_DIR"
fi

CONFIG_RESULT=$(CONFIG_FILE="$CONFIG_FILE" LATEST_BACKUP="$LATEST_BACKUP" python3 <<'PY'
import os
import re
import sys
from pathlib import Path

CONFIG_FILE = Path(os.environ["CONFIG_FILE"])
LATEST_BACKUP = os.environ.get("LATEST_BACKUP", "")
SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")


def split_header(header: str):
    parts = header.split(None, 1)
    if len(parts) == 1:
        return parts[0], ""
    return parts[0], parts[1]


def parse_sections(text: str):
    chunks = []
    current_header = None
    current_lines = []
    preamble = []
    for line in text.splitlines(keepends=True):
        match = SECTION_RE.match(line)
        if match:
            if current_header is None:
                if preamble:
                    chunks.append((None, "".join(preamble)))
                    preamble = []
            else:
                chunks.append((current_header, "".join(current_lines)))
            current_header = match.group(1).strip()
            current_lines = [line]
        else:
            if current_header is None:
                preamble.append(line)
            else:
                current_lines.append(line)
    if current_header is None:
        chunks.append((None, "".join(preamble)))
    else:
        chunks.append((current_header, "".join(current_lines)))
    return chunks


original_text = CONFIG_FILE.read_text()
chunks = parse_sections(original_text)
restored = []
slow_indexes = []

for index, (header, _block) in enumerate(chunks):
    if header is None:
        continue
    section_type, heater_name = split_header(header)
    if section_type == "slow_heater" and heater_name.startswith("Vivid_"):
        slow_indexes.append((index, heater_name))

if not slow_indexes:
    print("STATE=already_uninstalled")
    sys.exit(0)

if not LATEST_BACKUP:
    print("STATE=missing_backup")
    print("HEATERS=" + ",".join(name for _, name in slow_indexes))
    sys.exit(3)

backup_path = Path(LATEST_BACKUP)
backup_sections = {}
for header, block in parse_sections(backup_path.read_text()):
    if header is None:
        continue
    section_type, heater_name = split_header(header)
    if section_type == "heater_generic" and heater_name.startswith("Vivid_"):
        backup_sections[heater_name] = block

missing = [name for _, name in slow_indexes if name not in backup_sections]
if missing:
    print("STATE=incomplete_backup")
    print("HEATERS=" + ",".join(missing))
    sys.exit(4)

for index, heater_name in slow_indexes:
    chunks[index] = (chunks[index][0], backup_sections[heater_name])
    restored.append(heater_name)

CONFIG_FILE.write_text("".join(block for _, block in chunks))
print("STATE=restored")
print("HEATERS=" + ",".join(restored))
print(f"BACKUP={backup_path}")
PY
) || CONFIG_STATUS=$?
CONFIG_STATUS=${CONFIG_STATUS:-0}
printf '%s\n' "$CONFIG_RESULT"

case "$CONFIG_STATUS" in
    0)
        :
        ;;
    3)
        echo "Unable to restore Vivid heaters without a backup file." >&2
        exit 1
        ;;
    4)
        echo "Backup file does not contain every configured Vivid slow_heater section." >&2
        exit 1
        ;;
    *)
        exit "$CONFIG_STATUS"
        ;;
esac

case "$CONFIG_RESULT" in
    *"STATE=restored"*)
        CONFIG_CHANGED=1
        ;;
esac

HEATERS=$(printf '%s\n' "$CONFIG_RESULT" | sed -n 's/^HEATERS=//p')
BACKUP_PATH=$(printf '%s\n' "$CONFIG_RESULT" | sed -n 's/^BACKUP=//p')

if [ -f "$TARGET_MODULE" ]; then
    rm -f "$TARGET_MODULE"
    MODULE_CHANGED=1
    echo "Removed $TARGET_MODULE"
else
    echo "No installed slow_heater.py was found at $TARGET_MODULE"
fi

if [ "$CONFIG_CHANGED" -eq 1 ] || [ "$MODULE_CHANGED" -eq 1 ]; then
    restart_klipper
else
    echo "No uninstall changes were required; skipping Klipper restart."
fi

case "$CONFIG_RESULT" in
    *"STATE=restored"*)
        echo "Restored Vivid heaters: $HEATERS"
        echo "Restored from backup: $BACKUP_PATH"
        ;;
    *"STATE=already_uninstalled"*)
        echo "No Vivid slow_heater sections were found to restore."
        ;;
esac

echo "Uninstall complete."
