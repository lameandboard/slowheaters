#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="${REPO_DIR}/backups"

KLIPPER_CONFIG="${KLIPPER_CONFIG:-${HOME}/printer_data/config/printer.cfg}"
KLIPPER_EXTRAS_DIR="${KLIPPER_EXTRAS_DIR:-${HOME}/klipper/klippy/extras}"
KLIPPER_SERVICE="${KLIPPER_SERVICE:-klipper}"
MOONRAKER_URL="${MOONRAKER_URL:-http://localhost:7125}"

NO_RESTART=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
Usage: bash uninstall.sh [--no-restart]

Environment overrides:
  KLIPPER_CONFIG      Path to the root Klipper config (default: ~/printer_data/config/printer.cfg)
  KLIPPER_EXTRAS_DIR  Path to klippy/extras (default: ~/klipper/klippy/extras)
  KLIPPER_SERVICE     Klipper system service name (default: klipper)
  MOONRAKER_URL       Moonraker base URL used for restart fallback (default: http://localhost:7125)

Options:
  --no-restart        Do not restart Klipper after uninstall
  -h, --help          Show this help message
EOF
}

restart_klipper() {
    local service_url
    service_url="${MOONRAKER_URL}/machine/services/restart?service=${KLIPPER_SERVICE}"

    if [[ "${NO_RESTART}" -eq 1 ]]; then
        info "Skipping Klipper restart (--no-restart)"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 3 --max-time 5 \
            "${MOONRAKER_URL}/server/info" >/dev/null 2>&1; then
            info "Restarting Klipper via Moonraker at ${MOONRAKER_URL}"
            if curl -fsS --connect-timeout 5 --max-time 10 \
                -X POST "${service_url}" >/dev/null 2>&1; then
                info "Klipper restart requested via Moonraker"
                return 0
            fi
            warn "Moonraker service restart request failed; trying /printer/restart"
            if curl -fsS --connect-timeout 5 --max-time 10 \
                -X POST "${MOONRAKER_URL}/printer/restart" >/dev/null 2>&1; then
                info "Firmware restart requested via Moonraker"
                return 0
            fi
            warn "Moonraker restart fallback failed"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        info "Restarting Klipper via systemctl (${KLIPPER_SERVICE})"
        if systemctl restart "${KLIPPER_SERVICE}" >/dev/null 2>&1; then
            info "Klipper restarted with systemctl"
            return 0
        fi
        if command -v sudo >/dev/null 2>&1 && sudo -n systemctl restart "${KLIPPER_SERVICE}" >/dev/null 2>&1; then
            info "Klipper restarted with sudo systemctl"
            return 0
        fi
    fi

    warn "Could not restart Klipper automatically; please restart ${KLIPPER_SERVICE} manually"
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-restart)
            NO_RESTART=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -f "${KLIPPER_CONFIG}" ]] || fail "Klipper config not found: ${KLIPPER_CONFIG}"

LATEST_BACKUP="$(
    python3 - "${BACKUPS_DIR}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

backups_dir = Path(sys.argv[1]).expanduser().resolve()
files = list(backups_dir.glob("heater_slow_sections_*.json")) + list(backups_dir.glob("slow_heater_sections_*.json")) + list(backups_dir.glob("vivid_sections_*.json"))
if not files:
    raise SystemExit(0)

timestamp_re = re.compile(r"_(\d{8}_\d{6})\.json$")


def sort_key(path: Path) -> tuple[str, float, str]:
    match = timestamp_re.search(path.name)
    timestamp = match.group(1) if match else ""
    return (timestamp, path.stat().st_mtime, path.name)


print(sorted(files, key=sort_key)[-1])
PY
)" || fail "Failed to evaluate backup files in ${BACKUPS_DIR}"

if [[ -z "${LATEST_BACKUP}" ]]; then
    fail "No heater_slow section backups were found in ${BACKUPS_DIR}"
fi

info "Using Klipper config: ${KLIPPER_CONFIG}"
info "Using Klipper extras: ${KLIPPER_EXTRAS_DIR}"
info "Using Klipper service: ${KLIPPER_SERVICE}"
info "Restoring from backup: ${LATEST_BACKUP}"

python3 - "${KLIPPER_CONFIG}" "${LATEST_BACKUP}" <<'PY'
from __future__ import annotations

import glob
import json
import re
import sys
from pathlib import Path

root_config = Path(sys.argv[1]).expanduser().resolve()
backup_path = Path(sys.argv[2]).expanduser().resolve()

include_re = re.compile(r"^\[include\s+(.+?)\]\s*$", re.IGNORECASE)
section_re = re.compile(r"^\[(.+?)\]\s*$")


def collect_config_paths(path: Path, seen: set[Path] | None = None) -> list[Path]:
    seen = seen or set()
    path = path.resolve()
    if path in seen or not path.exists():
        return []
    seen.add(path)
    paths = [path]
    for line in path.read_text(encoding="utf-8").splitlines():
        match = include_re.match(line.strip())
        if not match:
            continue
        pattern = match.group(1).strip()
        expanded = Path(pattern).expanduser()
        if expanded.is_absolute():
            base_pattern = str(expanded)
        else:
            base_pattern = str((path.parent / pattern).expanduser())
        for match_path in sorted(Path(p).resolve() for p in glob.glob(base_pattern)):
            paths.extend(collect_config_paths(match_path, seen))
    return paths


def parse_sections(lines: list[str]) -> list[dict[str, object]]:
    sections: list[dict[str, object]] = []
    start = None
    header = None
    for idx, line in enumerate(lines):
        match = section_re.match(line.strip())
        if not match:
            continue
        if start is not None:
            sections.append({"start": start, "end": idx, "header": header})
        start = idx
        header = match.group(1)
    if start is not None:
        sections.append({"start": start, "end": len(lines), "header": header})
    return sections


def header_parts(header: str) -> tuple[str, str] | tuple[None, None]:
    parts = header.split(None, 1)
    if len(parts) != 2:
        return None, None
    return parts[0], parts[1]


backup_data = json.loads(backup_path.read_text(encoding="utf-8"))
backup_sections = backup_data.get("sections", [])
if not backup_sections:
    print(f"[WARN] Backup file is empty: {backup_path}")
    raise SystemExit(0)

config_paths = set(collect_config_paths(root_config))
for entry in backup_sections:
    config_paths.add(Path(entry["file"]).expanduser().resolve())

restored = []
missing = []
per_file_changes: dict[Path, list[dict[str, object]]] = {}

for entry in backup_sections:
    path = Path(entry["file"]).expanduser().resolve()
    name = entry["name"]
    original_text = entry["section"]
    if not path.exists():
        missing.append((name, path))
        continue
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    target_section = None
    for section in parse_sections(lines):
        kind, current_name = header_parts(section["header"])
        if current_name != name:
            continue
        if kind not in {"heater_slow", "slow_heater", "heater_generic"}:
            continue
        target_section = section
        break
    replacement = original_text if original_text.endswith("\n") else f"{original_text}\n"
    change = {
        "start": int(target_section["start"]) if target_section else len(lines),
        "end": int(target_section["end"]) if target_section else len(lines),
        "replacement": replacement.splitlines(keepends=True),
    }
    per_file_changes.setdefault(path, []).append(change)
    restored.append((name, path, target_section is not None))

for path, changes in per_file_changes.items():
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    for change in sorted(changes, key=lambda item: int(item["start"]), reverse=True):
        start = int(change["start"])
        end = int(change["end"])
        if start == len(lines) and lines and lines[-1].strip():
            lines.append("\n")
        lines[start:end] = change["replacement"]
    path.write_text("".join(lines), encoding="utf-8")

active_slow = []
for config_path in sorted(config_paths):
    if not config_path.exists():
        continue
    lines = config_path.read_text(encoding="utf-8").splitlines(keepends=True)
    for section in parse_sections(lines):
        kind, name = header_parts(section["header"])
        if kind in ("heater_slow", "slow_heater") and name.startswith("Vivid_"):
            active_slow.append((name, config_path))

print("[INFO] Vivid heater restore complete")
for name, path, replaced in restored:
    action = "Restored" if replaced else "Re-added"
    print(f"[INFO] {action} [heater_generic {name}] in {path}")
for name, path in missing:
    print(f"[WARN] Config file missing for backup entry [heater_generic {name}]: {path}")
for name, path in active_slow:
    if all(name != restored_name or path != restored_path for restored_name, restored_path, _ in restored):
        print(f"[WARN] Remaining [heater_slow {name}] not covered by backup: {path}")
PY

TARGET_MODULE="${KLIPPER_EXTRAS_DIR}/heater_slow.py"
if [[ -e "${TARGET_MODULE}" ]]; then
    rm -f "${TARGET_MODULE}"
    info "Removed ${TARGET_MODULE}"
else
    info "No installed module found at ${TARGET_MODULE}"
fi

LEGACY_MODULE="${KLIPPER_EXTRAS_DIR}/slow_heater.py"
if [[ -e "${LEGACY_MODULE}" ]]; then
    rm -f "${LEGACY_MODULE}"
    info "Removed legacy module ${LEGACY_MODULE}"
fi

restart_klipper || true
info "Uninstall complete"
