#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_MODULE="${REPO_DIR}/extras/heater_slow.py"
BACKUPS_DIR="${REPO_DIR}/backups"

KLIPPER_CONFIG="${KLIPPER_CONFIG:-${HOME}/printer_data/config/printer.cfg}"
KLIPPER_EXTRAS_DIR="${KLIPPER_EXTRAS_DIR:-${HOME}/klipper/klippy/extras}"
KLIPPER_SERVICE="${KLIPPER_SERVICE:-klipper}"
MOONRAKER_URL="${MOONRAKER_URL:-http://localhost:7125}"
MOONRAKER_CONF="${MOONRAKER_CONF:-${HOME}/printer_data/config/moonraker.conf}"

NO_RESTART=0
FIRMWARE_RESTART=0
DISCOVER_ONLY=0
INTERACTIVE_MODE=0
APPLY_ALL=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF_HELP'
Usage: bash install.sh [--discover] [--interactive] [--all] [--no-restart] [--firmware-restart]

Environment overrides:
  KLIPPER_CONFIG      Path to the root Klipper config (default: ~/printer_data/config/printer.cfg)
  KLIPPER_EXTRAS_DIR  Path to klippy/extras (default: ~/klipper/klippy/extras)
  KLIPPER_SERVICE     Klipper system service name (default: klipper)
  MOONRAKER_URL       Moonraker base URL used for restart (default: http://localhost:7125)
  MOONRAKER_CONF      Path to Moonraker config for update-manager entry (default: ~/printer_data/config/moonraker.conf)

Options:
  --discover          Scan and report candidate heaters only (no config/module/restart changes)
  --interactive       Show discovery report and prompt before applying conversion set
  --all               Apply all discovered candidates non-interactively (includes low confidence)
  --no-restart        Do not restart Klipper after install
  --firmware-restart  After the normal host restart, also issue a firmware restart via Moonraker.
                      Use this when an MCU-shutdown state prevents the host restart from loading
                      new config (equivalent to the FIRMWARE_RESTART gcode command).
  -h, --help          Show this help message

Behavior summary:
  - Default apply mode converts only high-confidence heater candidates.
  - --all broadens apply mode to convert every discovered candidate.
  - --interactive shows all candidates and prompts which confidence levels to apply.
  - --discover never copies heater_slow.py, never edits config, never restarts.
  - Normal install: host restart via Moonraker (or systemctl fallback).
  - --firmware-restart: additionally issues /printer/firmware_restart so MCUs
    reload config (mirrors the two-step restart used by the RFID project).
EOF_HELP
}

restart_klipper() {
    local service_url
    service_url="${MOONRAKER_URL}/machine/services/restart?service=${KLIPPER_SERVICE}"

    if [[ "${NO_RESTART}" -eq 1 ]]; then
        info "Skipping Klipper restart (--no-restart)"
        return 0
    fi

    local host_restarted=0

    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 3 --max-time 5 \
            "${MOONRAKER_URL}/server/info" >/dev/null 2>&1; then
            info "Restarting Klipper host via Moonraker at ${MOONRAKER_URL}"
            if curl -fsS --connect-timeout 5 --max-time 10 \
                -X POST "${service_url}" >/dev/null 2>&1; then
                info "Klipper host restart requested via Moonraker"
                host_restarted=1
            else
                warn "Moonraker service restart request failed; trying /printer/restart"
                if curl -fsS --connect-timeout 5 --max-time 10 \
                    -X POST "${MOONRAKER_URL}/printer/restart" >/dev/null 2>&1; then
                    info "Klipper host restart requested via Moonraker /printer/restart"
                    host_restarted=1
                else
                    warn "Moonraker host restart fallback failed"
                fi
            fi
        fi
    fi

    if [[ "${host_restarted}" -eq 0 ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            info "Restarting Klipper via systemctl (${KLIPPER_SERVICE})"
            if systemctl restart "${KLIPPER_SERVICE}" >/dev/null 2>&1; then
                info "Klipper restarted with systemctl"
                host_restarted=1
            elif command -v sudo >/dev/null 2>&1 && sudo -n systemctl restart "${KLIPPER_SERVICE}" >/dev/null 2>&1; then
                info "Klipper restarted with sudo systemctl"
                host_restarted=1
            fi
        fi
    fi

    if [[ "${host_restarted}" -eq 0 ]]; then
        warn "Could not restart Klipper automatically; please restart ${KLIPPER_SERVICE} manually"
        warn "If the printer is in MCU-shutdown state, run FIRMWARE_RESTART from your Klipper UI"
        return 1
    fi

    if [[ "${FIRMWARE_RESTART}" -eq 1 ]]; then
        firmware_restart_klipper
    fi

    return 0
}

firmware_restart_klipper() {
    if [[ "${NO_RESTART}" -eq 1 ]]; then
        info "Skipping firmware restart (--no-restart)"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 3 --max-time 5 \
            "${MOONRAKER_URL}/server/info" >/dev/null 2>&1; then
            info "Issuing firmware restart via Moonraker at ${MOONRAKER_URL}"
            if curl -fsS --connect-timeout 5 --max-time 10 \
                -X POST "${MOONRAKER_URL}/printer/firmware_restart" >/dev/null 2>&1; then
                info "Firmware restart requested via Moonraker"
                return 0
            fi
            warn "Moonraker firmware restart request failed"
        fi
    fi

    warn "Could not issue firmware restart automatically"
    warn "Run FIRMWARE_RESTART from your Klipper UI (Mainsail/Fluidd console) to reset MCU state"
    return 1
}

_SLOWHEATERS_BEGIN_MARKER="# >>> slowheaters update-manager >>>"
_SLOWHEATERS_END_MARKER="# <<< slowheaters update-manager <<<"

remove_moonraker_block() {
    local cfg="$1"
    [[ -f "${cfg}" ]] || return 0
    local tmp
    tmp="$(mktemp "${cfg}.XXXXXX")"
    if awk -v b="${_SLOWHEATERS_BEGIN_MARKER}" -v e="${_SLOWHEATERS_END_MARKER}" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}
    ' "${cfg}" > "${tmp}"; then
        mv "${tmp}" "${cfg}"
    else
        rm -f "${tmp}"
        warn "Failed to rewrite ${cfg}; leaving original unchanged"
    fi
}

add_moonraker_block() {
    local cfg="$1"
    if [[ ! -f "${cfg}" ]]; then
        warn "Moonraker config not found at ${cfg}; skipping update-manager entry"
        warn "Set MOONRAKER_CONF to your moonraker.conf path and re-run install.sh to add it later"
        return 0
    fi
    if ! grep -Fq "${_SLOWHEATERS_BEGIN_MARKER}" "${cfg}"; then
        info "Adding slowheaters update-manager block to ${cfg}"
        {
            printf '\n'
            printf '%s\n' "${_SLOWHEATERS_BEGIN_MARKER}"
            printf '[update_manager slowheaters]\n'
            printf 'type: git_repo\n'
            printf 'path: ~/slowheaters\n'
            printf 'origin: https://github.com/lameandboard/slowheaters.git\n'
            printf 'primary_branch: main\n'
            printf 'managed_services: klipper\n'
            printf 'install_script: install.sh\n'
            printf '%s\n' "${_SLOWHEATERS_END_MARKER}"
        } >> "${cfg}"
    else
        info "slowheaters update-manager block already present in ${cfg}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-restart)
            NO_RESTART=1
            shift
            ;;
        --firmware-restart)
            FIRMWARE_RESTART=1
            shift
            ;;
        --discover)
            DISCOVER_ONLY=1
            shift
            ;;
        --interactive)
            INTERACTIVE_MODE=1
            shift
            ;;
        --all)
            APPLY_ALL=1
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

if [[ "${INTERACTIVE_MODE}" -eq 1 ]] && [[ "${DISCOVER_ONLY}" -eq 0 ]] && [[ ! -t 0 ]]; then
    fail "--interactive requires a TTY"
fi

if [[ "${DISCOVER_ONLY}" -eq 1 ]] && [[ "${APPLY_ALL}" -eq 1 ]]; then
    warn "--all has no effect with --discover"
fi

if [[ "${DISCOVER_ONLY}" -eq 1 ]] && [[ "${INTERACTIVE_MODE}" -eq 1 ]]; then
    warn "--interactive has no effect with --discover"
fi

[[ -f "${REPO_MODULE}" ]] || fail "Module not found: ${REPO_MODULE}"
[[ -f "${KLIPPER_CONFIG}" ]] || fail "Klipper config not found: ${KLIPPER_CONFIG}"

if [[ "${DISCOVER_ONLY}" -eq 0 ]]; then
    [[ -d "${KLIPPER_EXTRAS_DIR}" ]] || fail "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"
fi

info "Using Klipper config: ${KLIPPER_CONFIG}"
info "Using Klipper extras: ${KLIPPER_EXTRAS_DIR}"
info "Using Klipper service: ${KLIPPER_SERVICE}"

python3 -m py_compile "${REPO_MODULE}"
info "Validated Python syntax: ${REPO_MODULE}"

run_config_scan() {
    local action="$1"
    local apply_policy="$2"
    local report_mode="${3:-full}"

    python3 - "${KLIPPER_CONFIG}" "${BACKUPS_DIR}" "${action}" "${apply_policy}" "${report_mode}" <<'PY'
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
action = sys.argv[3]
apply_policy = sys.argv[4]
report_mode = sys.argv[5]

include_re = re.compile(r"^\[include\s+(.+?)\]\s*$", re.IGNORECASE)
section_re = re.compile(r"^\[(.+?)\]\s*$")
option_re = re.compile(r"^\s*([A-Za-z0-9_]+)\s*[:=]\s*(.*?)\s*(?:#.*)?$")

KNOWN_SLOW_SENSOR_TYPES = {"aht10", "aht20", "aht3x"}
HEURISTIC_TOKENS = {
    "aht": "medium",
    "vivid": "medium",
    "dryer": "medium",
    "chamber": "low",
}
SENSOR_REFERENCE_KEYS = (
    "sensor",
    "temperature_sensor",
    "sensor_name",
    "sensor_section",
)
SLOW_HEATER_OPTION_KEYS = {
    "max_duration",
}

defaults = [
    ("max_duration", "10.0"),
]

CONFIDENCE_LEVEL = {"none": 0, "low": 1, "medium": 2, "high": 3}
CONFIDENCE_FROM_LEVEL = {value: key for key, value in CONFIDENCE_LEVEL.items()}


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
        raise SystemExit(f"[ERROR] Failed to read {path}: {exc}") from exc
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


def split_header(header: str) -> tuple[str, str]:
    parts = header.split(None, 1)
    if len(parts) == 1:
        return parts[0].strip(), ""
    return parts[0].strip(), parts[1].strip()


def parse_options(lines: list[str], start: int, end: int) -> dict[str, str]:
    options: dict[str, str] = {}
    for line in lines[start + 1:end]:
        match = option_re.match(line)
        if not match:
            continue
        key = match.group(1).strip().lower()
        value = match.group(2).strip()
        options[key] = value
    return options


def update_confidence(current_level: int, requested: str) -> int:
    return max(current_level, CONFIDENCE_LEVEL[requested])


def collect_token_matches(text: str) -> list[tuple[str, str]]:
    lowered = text.lower()
    matches: list[tuple[str, str]] = []
    for token, confidence in HEURISTIC_TOKENS.items():
        if token in lowered:
            matches.append((token, confidence))
    return matches


def section_slow_signal(section: dict[str, object]) -> dict[str, object]:
    reasons: list[str] = []
    confidence_level = 0

    kind = str(section["kind"])
    name = str(section["name"])
    options = dict(section["options"])

    if kind.lower() in KNOWN_SLOW_SENSOR_TYPES:
        confidence_level = update_confidence(confidence_level, "high")
        reasons.append(f"section type is known slow sensor '{kind}'")

    for key, value in options.items():
        normalized_value = value.strip().lower()
        if normalized_value in KNOWN_SLOW_SENSOR_TYPES:
            confidence_level = update_confidence(confidence_level, "high")
            reasons.append(f"option '{key}' is known slow sensor type '{value.strip()}'")

    searchable_text = " ".join([section["header"], kind, name] + [str(v) for v in options.values()])
    for token, confidence in collect_token_matches(searchable_text):
        confidence_level = update_confidence(confidence_level, confidence)
        reasons.append(f"name/value contains token '{token}'")

    return {
        "confidence_level": confidence_level,
        "confidence": CONFIDENCE_FROM_LEVEL[confidence_level],
        "reasons": sorted(set(reasons)),
    }


def resolve_sensor_reference(reference: str, sections_by_header: dict[str, dict[str, object]], sections_by_name: dict[str, list[dict[str, object]]]) -> dict[str, object] | None:
    cleaned = reference.strip()
    if not cleaned:
        return None
    lowered = cleaned.lower()
    if lowered in sections_by_header:
        return sections_by_header[lowered]
    matches = sections_by_name.get(lowered, [])
    if len(matches) == 1:
        return matches[0]
    return None


def confidence_label_from_reasons(level: int) -> str:
    return CONFIDENCE_FROM_LEVEL.get(level, "none")


def section_output(lines: list[str], start: int, end: int, kind: str, name: str) -> tuple[str, list[str], bool, int]:
    original = "".join(lines[start:end])
    body = lines[start + 1:end]
    original_keys = {
        match.group(1).strip().lower()
        for line in body
        if (match := option_re.match(line))
    }
    additions = [f"{key}: {value}\n" for key, value in defaults if key not in original_keys] if kind == "heater_generic" else []

    changed = False
    new_lines = [f"[heater_slow {name}]\n"] + body
    if kind != "heater_slow":
        changed = True
    if additions:
        changed = True
        if new_lines and new_lines[-1].strip():
            new_lines.append("\n")
        new_lines.extend(additions)

    return original, new_lines, changed, len(additions)


config_paths = collect_config_paths(root_config)

all_sections: list[dict[str, object]] = []
sections_by_header: dict[str, dict[str, object]] = {}
sections_by_name: dict[str, list[dict[str, object]]] = defaultdict(list)

for config_path in config_paths:
    lines = config_path.read_text(encoding="utf-8").splitlines(keepends=True)
    for section in parse_sections(lines):
        header = str(section["header"])
        kind, name = split_header(header)
        entry = {
            "id": len(all_sections),
            "path": config_path,
            "lines": lines,
            "header": header,
            "kind": kind,
            "name": name,
            "start": int(section["start"]),
            "end": int(section["end"]),
        }
        entry["options"] = parse_options(lines, int(section["start"]), int(section["end"]))
        all_sections.append(entry)
        sections_by_header[header.lower()] = entry
        if name:
            sections_by_name[name.lower()].append(entry)

sensor_signals: dict[int, dict[str, object]] = {}
for section in all_sections:
    sensor_signals[int(section["id"])] = section_slow_signal(section)

candidate_heaters: list[dict[str, object]] = []
for section in all_sections:
    kind = str(section["kind"])
    if kind not in {"heater_generic", "heater_slow"}:
        continue

    name = str(section["name"])
    options = dict(section["options"])
    confidence_level = 0
    reasons: list[str] = []
    linked_sensor = ""

    direct_sensor_type = options.get("sensor_type", "").strip()
    if direct_sensor_type and direct_sensor_type.lower() in KNOWN_SLOW_SENSOR_TYPES:
        confidence_level = update_confidence(confidence_level, "high")
        reasons.append(f"heater sensor_type is known slow sensor '{direct_sensor_type}'")
        linked_sensor = f"sensor_type={direct_sensor_type}"
    elif direct_sensor_type.lower() == "temperature_combined":
        sensor_list_val = options.get("sensor_list", "")
        slow_in_list = [
            tok for tok in re.split(r"[\s,]+", sensor_list_val.lower())
            if tok in KNOWN_SLOW_SENSOR_TYPES
        ]
        if slow_in_list:
            confidence_level = update_confidence(confidence_level, "high")
            reasons.append(
                f"temperature_combined sensor_list references slow sensor(s): {', '.join(slow_in_list)}"
            )
            linked_sensor = "sensor_type=temperature_combined"

    if kind == "heater_generic":
        slow_option_keys = sorted(set(options).intersection(SLOW_HEATER_OPTION_KEYS))
        if slow_option_keys:
            confidence_level = update_confidence(confidence_level, "high")
            reasons.append(
                "heater_generic already contains heater_slow-only option(s): "
                + ", ".join(slow_option_keys)
            )

    heater_text = " ".join([str(section["header"]), name])
    for token, token_confidence in collect_token_matches(heater_text):
        confidence_level = update_confidence(confidence_level, token_confidence)
        reasons.append(f"heater name contains token '{token}'")

    for key in SENSOR_REFERENCE_KEYS:
        if key not in options:
            continue
        referenced = resolve_sensor_reference(options[key], sections_by_header, sections_by_name)
        if referenced is None:
            ref_value = options[key].strip()
            for token, token_confidence in collect_token_matches(ref_value):
                confidence_level = update_confidence(confidence_level, token_confidence)
                reasons.append(f"sensor reference '{key}' contains token '{token}'")
            continue

        linked_sensor = referenced["header"]
        ref_index = int(referenced["id"])
        ref_signal = sensor_signals[ref_index]
        ref_level = int(ref_signal["confidence_level"])
        if ref_level > 0:
            confidence_level = max(confidence_level, ref_level)
            for reason in ref_signal["reasons"]:
                reasons.append(f"{key} references [{referenced['header']}]: {reason}")

    if confidence_level == 0:
        continue

    candidate_heaters.append(
        {
            "path": section["path"],
            "kind": kind,
            "name": name,
            "header": section["header"],
            "start": int(section["start"]),
            "end": int(section["end"]),
            "lines": section["lines"],
            "linked_sensor": linked_sensor,
            "confidence_level": confidence_level,
            "confidence": confidence_label_from_reasons(confidence_level),
            "reasons": sorted(set(reasons)),
        }
    )

candidate_heaters.sort(
    key=lambda item: (
        -int(item["confidence_level"]),
        str(item["path"]),
        str(item["name"]),
    )
)

if not candidate_heaters:
    print("[INFO] No slow-sensor heater candidates were found in the Klipper config tree")
    raise SystemExit(0)

if report_mode == "full":
    print("[INFO] Slow sensor discovery report")
    for heater in candidate_heaters:
        path = heater["path"]
        kind = heater["kind"]
        name = heater["name"]
        linked_sensor = heater["linked_sensor"] if heater["linked_sensor"] else "n/a"
        print(
            "[INFO] Candidate: "
            f"file={path} heater_section={name} current_kind={kind} "
            f"linked_sensor={linked_sensor} confidence={heater['confidence']}"
        )
        for reason in heater["reasons"]:
            print(f"[INFO]   reason: {reason}")

threshold = (
    CONFIDENCE_LEVEL["low"]
    if apply_policy == "all"
    else CONFIDENCE_LEVEL["high"]
)
eligible = [
    heater for heater in candidate_heaters
    if heater["kind"] == "heater_generic" and int(heater["confidence_level"]) >= threshold
]
below_threshold_candidates = [
    heater for heater in candidate_heaters
    if heater["kind"] == "heater_generic" and int(heater["confidence_level"]) < threshold
]
existing_slow = [heater for heater in candidate_heaters if heater["kind"] in ("heater_slow", "slow_heater")]

print(
    "[INFO] Discovery summary: "
    f"eligible_conversions={len(eligible)} existing_slow={len(existing_slow)} "
    f"below_threshold={len(below_threshold_candidates)} apply_policy={apply_policy}"
)

if action == "discover":
    if below_threshold_candidates and apply_policy != "all":
        print("[WARN] Some below-threshold heater_generic candidates were not marked eligible by the current apply policy")
        print("[WARN] Use --interactive --all after reviewing the report if you want to include them")
    raise SystemExit(0)

per_file: dict[Path, list[dict[str, object]]] = defaultdict(list)
converted: list[tuple[str, Path]] = []
already_slow: list[tuple[str, Path]] = []
backup_sections: list[dict[str, str]] = []
defaults_added = 0

for heater in candidate_heaters:
    path = heater["path"]
    lines = heater["lines"]
    kind = str(heater["kind"])
    name = str(heater["name"])
    start = int(heater["start"])
    end = int(heater["end"])

    should_update = False
    if kind == "heater_slow":
        should_update = True
    elif kind == "heater_generic" and int(heater["confidence_level"]) >= threshold:
        should_update = True

    if not should_update:
        continue

    original, replacement, changed, added_count = section_output(lines, start, end, kind, name)

    if kind == "heater_generic":
        converted.append((name, path, kind))
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
        defaults_added += added_count
        per_file[path].append(
            {
                "start": start,
                "end": end,
                "replacement": replacement,
            }
        )

for path, replacements in per_file.items():
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    for replacement in sorted(replacements, key=lambda item: int(item["start"]), reverse=True):
        lines[int(replacement["start"]):int(replacement["end"])] = replacement["replacement"]
    path.write_text("".join(lines), encoding="utf-8")

backup_path = None
if backup_sections:
    backups_dir.mkdir(parents=True, exist_ok=True)
    backup_path = backups_dir / f"heater_slow_sections_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"
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

print("[INFO] Conversion run complete")
for name, path, orig_kind in converted:
    print(f"[INFO] Converted [{orig_kind} {name}] -> [heater_slow {name}] in {path}")
for name, path in already_slow:
    print(f"[INFO] Found existing [heater_slow {name}] in {path}")
if defaults_added:
    print(f"[INFO] Added {defaults_added} missing heater_slow default setting(s)")
if backup_path is not None:
    print(f"[INFO] Backed up original converted sections to {backup_path}")
if below_threshold_candidates and apply_policy != "all":
    print("[WARN] Skipped below-threshold heater_generic candidates under default apply policy")
    print("[WARN] Re-run with --interactive --all after review if you want to convert them")
if not per_file:
    print("[INFO] Config already matched the expected heater_slow layout for the selected candidates")
PY
}

APPLY_POLICY="high"
if [[ "${APPLY_ALL}" -eq 1 ]]; then
    APPLY_POLICY="all"
fi

if [[ "${DISCOVER_ONLY}" -eq 1 ]]; then
    info "Running discovery-only scan"
    run_config_scan discover "${APPLY_POLICY}" full
    info "Discovery complete (no changes made)"
    exit 0
fi

if [[ "${INTERACTIVE_MODE}" -eq 1 ]]; then
    info "Running discovery scan with all candidates"
    run_config_scan discover "all" full
    printf '\n[INFO] Which candidates would you like to convert?\n'
    printf '[INFO]   1) High-confidence only (sensor type match)\n'
    printf '[INFO]   2) All discovered (includes heuristic matches)\n'
    printf '[INFO]   3) Cancel (no changes)\n'
    read -r -p "[INFO] Choose [1-3]: " choice
    case "${choice}" in
        1) info "User selected: high-confidence conversions"; APPLY_POLICY="high" ;;
        2) info "User selected: all discovered conversions"; APPLY_POLICY="all" ;;
        *) info "User cancelled; exiting with no changes"; exit 0 ;;
    esac
else
    info "Running pre-install discovery scan"
    scan_output=$(run_config_scan discover "${APPLY_POLICY}" full)
    printf '%s\n' "${scan_output}"
    if printf '%s\n' "${scan_output}" | grep -q "eligible_conversions=0 existing_slow=0"; then
        warn "No eligible heater_slow conversions were found under the current apply policy."
        warn "The heater_slow module has NOT been installed and Klipper has not been restarted."
        warn "To include lower-confidence candidates, re-run with: ./install.sh --interactive"
        exit 0
    fi
fi

mkdir -p "${BACKUPS_DIR}"
cp "${REPO_MODULE}" "${KLIPPER_EXTRAS_DIR}/heater_slow.py"
info "Copied module to ${KLIPPER_EXTRAS_DIR}/heater_slow.py"

run_config_scan apply "${APPLY_POLICY}" full

remove_moonraker_block "${MOONRAKER_CONF}"
add_moonraker_block "${MOONRAKER_CONF}"

restart_klipper || true
info "Install complete"
