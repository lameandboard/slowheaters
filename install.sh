#!/bin/sh
# install.sh - Install the slow_heater Klipper extra for Vivid heaters.
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
SOURCE_MODULE="$SCRIPT_DIR/slow_heater.py"
TARGET_MODULE="$EXTRAS_DIR/slow_heater.py"
BACKUP_DIR="$SCRIPT_DIR/backups"
KLIPPER_SERVICE=${KLIPPER_SERVICE:-klipper}
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_FILE="$BACKUP_DIR/vivid-heaters-$TIMESTAMP.cfg"
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

if [ ! -f "$SOURCE_MODULE" ]; then
    echo "Error: slow_heater.py not found at $SOURCE_MODULE" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: printer config not found at $CONFIG_FILE" >&2
    exit 1
fi

if [ ! -d "$EXTRAS_DIR" ]; then
    echo "Error: Klipper extras directory not found at $EXTRAS_DIR" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "Scanning $CONFIG_FILE for [heater_generic Vivid_*] sections..."
CONFIG_RESULT=$(CONFIG_FILE="$CONFIG_FILE" BACKUP_FILE="$BACKUP_FILE" python3 <<'PY'
import os
import re
import sys
from pathlib import Path

CONFIG_FILE = Path(os.environ["CONFIG_FILE"])
BACKUP_FILE = Path(os.environ["BACKUP_FILE"])
DEFAULTS = [
    ("refresh_time", "1.0"),
    ("max_mcu_duration", "3.0"),
    ("sensor_timeout", "15.0"),
    ("schedule_lead_time", "0.100"),
]
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


def add_defaults(block: str, heater_name: str) -> str:
    lines = block.splitlines(keepends=True)
    lines[0] = f"[slow_heater {heater_name}]\n"
    existing = set()
    for line in lines[1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        existing.add(stripped.split(":", 1)[0].strip())

    additions = [f"{key}: {value}\n" for key, value in DEFAULTS if key not in existing]
    if additions:
        if len(lines) > 1 and lines[-1].strip():
            lines.append("\n")
        lines.extend(additions)
        if lines[-1].strip():
            lines.append("\n")
    return "".join(lines)


original_text = CONFIG_FILE.read_text()
chunks = parse_sections(original_text)
backup_sections = []
updated = []
already = []

for index, (header, block) in enumerate(chunks):
    if header is None:
        continue
    section_type, heater_name = split_header(header)
    if section_type == "heater_generic" and heater_name.startswith("Vivid_"):
        updated.append(heater_name)
        backup_sections.append(block)
        chunks[index] = (header, add_defaults(block, heater_name))
    elif section_type == "slow_heater" and heater_name.startswith("Vivid_"):
        already.append(heater_name)

if not updated:
    if already:
        print("STATE=already_installed")
        print("HEATERS=" + ",".join(already))
        sys.exit(0)
    print("STATE=missing")
    sys.exit(2)

backup_text = "".join(backup_sections)
BACKUP_FILE.write_text(backup_text)
CONFIG_FILE.write_text("".join(block for _, block in chunks))

print("STATE=updated")
print("HEATERS=" + ",".join(updated))
print(f"BACKUP={BACKUP_FILE}")
PY
) || CONFIG_STATUS=$?
CONFIG_STATUS=${CONFIG_STATUS:-0}
printf '%s\n' "$CONFIG_RESULT"

case "$CONFIG_STATUS" in
    0)
        :
        ;;
    2)
        echo "No Vivid heater sections were found in $CONFIG_FILE." >&2
        exit 1
        ;;
    *)
        exit "$CONFIG_STATUS"
        ;;
esac

case "$CONFIG_RESULT" in
    *"STATE=updated"*)
        CONFIG_CHANGED=1
        ;;
esac

HEATERS=$(printf '%s\n' "$CONFIG_RESULT" | sed -n 's/^HEATERS=//p')
BACKUP_PATH=$(printf '%s\n' "$CONFIG_RESULT" | sed -n 's/^BACKUP=//p')

echo "Verifying Python syntax: $SOURCE_MODULE"
python3 -m py_compile "$SOURCE_MODULE"

if [ ! -f "$TARGET_MODULE" ] || ! cmp -s "$SOURCE_MODULE" "$TARGET_MODULE"; then
    cp "$SOURCE_MODULE" "$TARGET_MODULE"
    MODULE_CHANGED=1
    echo "Copied slow_heater.py to $TARGET_MODULE"
else
    echo "slow_heater.py is already up to date in $TARGET_MODULE"
fi

echo "Verifying Python syntax: $TARGET_MODULE"
python3 -m py_compile "$TARGET_MODULE"

if [ "$CONFIG_CHANGED" -eq 1 ] || [ "$MODULE_CHANGED" -eq 1 ]; then
    restart_klipper
else
    echo "No install changes were required; skipping Klipper restart."
fi

case "$CONFIG_RESULT" in
    *"STATE=updated"*)
        echo "Updated Vivid heaters: $HEATERS"
        echo "Backed up original sections to: $BACKUP_PATH"
        ;;
    *"STATE=already_installed"*)
        echo "Vivid heaters already use slow_heater: $HEATERS"
        ;;
esac

echo "Install complete."
