#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_MODULE="${REPO_DIR}/extras/slow_heater.py"
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
Usage: bash install.sh [--no-restart]

Environment overrides:
  KLIPPER_CONFIG      Path to the root Klipper config (default: ~/printer_data/config/printer.cfg)
  KLIPPER_EXTRAS_DIR  Path to klippy/extras (default: ~/klipper/klippy/extras)
  KLIPPER_SERVICE     Klipper system service name (default: klipper)
  MOONRAKER_URL       Moonraker base URL used for restart fallback (default: http://localhost:7125)

Options:
  --no-restart        Do not restart Klipper after install
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

[[ -f "${REPO_MODULE}" ]] || fail "Module not found: ${REPO_MODULE}"
[[ -f "${KLIPPER_CONFIG}" ]] || fail "Klipper config not found: ${KLIPPER_CONFIG}"
[[ -d "${KLIPPER_EXTRAS_DIR}" ]] || fail "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"

info "Using Klipper config: ${KLIPPER_CONFIG}"
info "Using Klipper extras: ${KLIPPER_EXTRAS_DIR}"
info "Using Klipper service: ${KLIPPER_SERVICE}"

python3 -m py_compile "${REPO_MODULE}"
info "Validated Python syntax: ${REPO_MODULE}"

mkdir -p "${BACKUPS_DIR}"
cp "${REPO_MODULE}" "${KLIPPER_EXTRAS_DIR}/slow_heater.py"
info "Copied module to ${KLIPPER_EXTRAS_DIR}/slow_heater.py"

python3 - "${KLIPPER_CONFIG}" "${BACKUPS_DIR}" <<'PY'
from __future__ import annotations

import glob
import json
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

root_config = Path(sys.argv[1]).expanduser().resolve()
backups_dir = Path(sys.argv[2]).expanduser().resolve()

include_re = re.compile(r"^\[include\s+(.+?)\]\s*$", re.IGNORECASE)
section_re = re.compile(r"^\[(.+?)\]\s*$")
option_re = re.compile(r"^\s*([A-Za-z0-9_]+)\s*[:=]")

defaults = [
    ("refresh_time", "1.0"),
    ("max_mcu_duration", "3.0"),
    ("sensor_timeout", "15.0"),
    ("schedule_lead_time", "0.100"),
]


def collect_config_paths(path: Path, seen: set[Path] | None = None) -> list[Path]:
    seen = seen or set()
    path = path.resolve()
    if path in seen or not path.exists():
        return []
    seen.add(path)
    paths = [path]
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SystemExit(f"Failed to read {path}: {exc}") from exc
    for line in lines:
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


def section_name(header: str) -> tuple[str, str] | tuple[None, None]:
    parts = header.split(None, 1)
    if len(parts) != 2:
        return None, None
    kind, name = parts
    if name.startswith("Vivid_") and kind in {"heater_generic", "slow_heater"}:
        return kind, name
    return None, None


def updated_section_text(lines: list[str], start: int, end: int, kind: str, name: str) -> tuple[str, list[str], bool]:
    original = "".join(lines[start:end])
    body = lines[start + 1:end]
    keys = {
        match.group(1)
        for line in body
        if (match := option_re.match(line))
    }
    additions = [f"{key}: {value}\n" for key, value in defaults if key not in keys]
    changed = False
    new_lines = [f"[slow_heater {name}]\n"] + body
    if kind != "slow_heater":
        changed = True
    if additions:
        changed = True
        if new_lines and new_lines[-1].strip():
            new_lines.append("\n")
        new_lines.extend(additions)
    return original, new_lines, changed


config_paths = collect_config_paths(root_config)
targets: list[dict[str, object]] = []
for config_path in config_paths:
    lines = config_path.read_text(encoding="utf-8").splitlines(keepends=True)
    for section in parse_sections(lines):
        kind, name = section_name(section["header"])
        if not kind:
            continue
        targets.append(
            {
                "path": config_path,
                "lines": lines,
                "kind": kind,
                "name": name,
                "start": int(section["start"]),
                "end": int(section["end"]),
            }
        )

if not targets:
    print("[INFO] No Vivid heater sections were found in the Klipper config tree")
    raise SystemExit(0)

per_file: dict[Path, list[dict[str, object]]] = defaultdict(list)
converted: list[tuple[str, Path]] = []
already_slow: list[tuple[str, Path]] = []
backup_sections: list[dict[str, str]] = []
defaults_added = 0

for target in targets:
    path = target["path"]
    lines = target["lines"]
    kind = str(target["kind"])
    name = str(target["name"])
    start = int(target["start"])
    end = int(target["end"])

    original, replacement, changed = updated_section_text(lines, start, end, kind, name)
    if kind == "heater_generic":
        converted.append((name, path))
        backup_sections.append(
            {
                "file": str(path),
                "name": name,
                "original_kind": kind,
                "section": original,
            }
        )
    else:
        already_slow.append((name, path))

    if changed:
        per_file[path].append(
            {
                "start": start,
                "end": end,
                "replacement": replacement,
            }
        )
        if any(f"{key}: {value}\n" in replacement for key, value in defaults):
            original_keys = {
                match.group(1)
                for line in lines[start + 1:end]
                if (match := option_re.match(line))
            }
            defaults_added += sum(1 for key, _ in defaults if key not in original_keys)

for path, replacements in per_file.items():
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    for replacement in sorted(replacements, key=lambda item: int(item["start"]), reverse=True):
        lines[int(replacement["start"]):int(replacement["end"])] = replacement["replacement"]
    path.write_text("".join(lines), encoding="utf-8")

backup_path = None
if backup_sections:
    backups_dir.mkdir(parents=True, exist_ok=True)
    backup_path = backups_dir / f"vivid_sections_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.json"
    backup_path.write_text(
        json.dumps(
            {
                "created_at": datetime.now(timezone.utc).isoformat(),
                "root_config": str(root_config),
                "sections": backup_sections,
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

print("[INFO] Vivid heater scan complete")
for name, path in converted:
    print(f"[INFO] Converted [heater_generic {name}] -> [slow_heater {name}] in {path}")
for name, path in already_slow:
    print(f"[INFO] Found existing [slow_heater {name}] in {path}")
if defaults_added:
    print(f"[INFO] Added {defaults_added} missing slow_heater default setting(s)")
if backup_path is not None:
    print(f"[INFO] Backed up original Vivid sections to {backup_path}")
if not per_file:
    print("[INFO] Config already matched the expected slow_heater layout")
PY

restart_klipper || true
info "Install complete"
