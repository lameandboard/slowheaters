# slowheaters

`slowheaters` adds a Klipper `heater_slow` extra for slow-reporting sensors such as Vivid dryer sensors. It keeps Klipper's normal heater behavior and only changes the heater-output refresh path so the MCU watchdog is refreshed safely between slow temperature reports.

> **⚠️ Breaking change (v2+):** The config section type was renamed from `slow_heater` to `heater_slow`. Existing `[slow_heater <name>]` sections must be updated to `[heater_slow <name>]`. Re-running `install.sh` will automatically migrate any remaining `[slow_heater ...]` sections in your config.

## Repository layout

- `/extras/heater_slow.py` - the Klipper extra installed by `install.sh`
- `/install.sh` - installs the extra and discovers/converts matching slow-sensor heaters
- `/uninstall.sh` - restores the most recent backed-up converted sections
- `/backups/` - created by the installer for timestamped converted-section backups

## What the installer does

`install.sh` follows the same workflow pattern as the RFID project:

1. Validates `extras/heater_slow.py`
2. Scans the full Klipper config tree starting from `printer.cfg`, including `[include ...]` files
3. Builds heater candidates from:
   - known slow sensor type matches (`aht10`, `aht20`, `aht3x`)
   - name/reference heuristics (`aht`, `vivid`, `dryer`, `chamber`)
4. Reports candidate heater sections with confidence and reason(s)
5. In apply mode, backs up converted sections to `backups/heater_slow_sections_YYYYMMDD_HHMMSS.json`
6. Converts selected `[heater_generic ...]` sections to `[heater_slow ...]`
7. Adds default slow-heater settings when missing:
   - `refresh_time: 1.0`
   - `max_mcu_duration: 3.0`
   - `sensor_timeout: 15.0`
   - `schedule_lead_time: 0.100`
8. In apply mode, copies `heater_slow.py` and restarts Klipper through Moonraker when available, otherwise falls back to `systemctl`

Running the installer again is safe: existing `heater_slow` sections are detected and only missing defaults are added.

By default, apply mode converts **high-confidence** candidates only. Use `--all` to include lower-confidence matches after you review the report.

## Example `[heater_slow <name>]` config

Minimal section:

```ini
[heater_slow Vivid_Dryer]
heater_pin: PB1
sensor_type: AHT20
sensor_pin: PA0
control: pid
pid_kp: 12.0
pid_ki: 0.5
pid_kd: 45.0
```

Tuned section:

```ini
[heater_slow Chamber_Dryer]
heater_pin: PB1
sensor_type: AHT20
sensor_pin: PA0
control: pid
pid_kp: 12.0
pid_ki: 0.5
pid_kd: 45.0
refresh_time: 1.2
max_mcu_duration: 3.0
sensor_timeout: 20.0
schedule_lead_time: 0.150
```

Slow-heater settings:

- `refresh_time`: how often Klipper refreshes heater output while waiting for the next sensor update.
- `max_mcu_duration`: maximum watchdog-safe output duration scheduled on the MCU per refresh.
- `sensor_timeout`: how old a sensor reading can be before `heater_slow` treats it as stale.
- `schedule_lead_time`: small lead-time margin used when scheduling refreshes so updates land safely before deadlines.
- Standard Klipper heater options like `max_power` still apply and are the preferred way to cap heater duty if you also want a slower ramp.

## Mainsail / Fluidd behavior

- `[heater_slow <name>]` is still the required config section for slow-sensor-safe control.
- For UI compatibility, the same object is also published as `heater_generic <name>`, so Mainsail/Fluidd can show target controls.
- This alias does **not** switch to regular heater behavior: control still goes through HeaterSlow's independent refresh timer and stale-sensor cutoff.
- `get_status()` explicitly includes `max_temp` and `min_temp` so Moonraker can forward the correct temperature range to the frontend. Without this, Mainsail cannot find the limits from the configfile (because the config section is named `[heater_slow ...]`, not `[heater_generic ...]`) and falls back to **max_temp = 0**, blocking any positive target input.
- Frontends usually show only standard heater fields (`temperature`, `target`, `power`). Slow-heater internals are available in Klipper status/output:
  - `heater_slow_active`
  - `requested_power`
  - `refreshed_power`
  - `sensor_age`
  - `refresh_time`
  - `max_mcu_duration`
  - `sensor_timeout`
  - `schedule_lead_time`

### Overshoot protection

Slow sensors report temperature only every few seconds.  During that interval
the refresh timer would otherwise keep replaying the last PID output even after
the temperature has already reached the target, causing overshoot that can trip
Klipper's `max_temp` shutdown ("temp too high").

`heater_slow` guards against this: if `last_temp >= target_temp` at refresh
time, PWM is cut to zero immediately.  PID resumes sending positive output via
`set_pwm()` as soon as the sensor reports the temperature has dropped back below
target.

## Install

SSH into your Klipper host and clone the repository:

```bash
cd ~
if [ -d "slowheaters/.git" ]; then
  git -C slowheaters pull
else
  git clone https://github.com/lameandboard/slowheaters.git slowheaters
fi
cd slowheaters
./install.sh --interactive
```

Common options:

```bash
# Report-only scan. No module copy, no config changes, no restart.
bash install.sh --discover

# Review report, then prompt before applying high-confidence conversions.
bash install.sh --interactive

# Apply all discovered candidates non-interactively (including low confidence).
bash install.sh --all
```

Optional environment overrides:

```bash
KLIPPER_CONFIG=~/printer_data/config/printer.cfg \
KLIPPER_EXTRAS_DIR=~/klipper/klippy/extras \
KLIPPER_SERVICE=klipper \
bash install.sh
```

Use `--no-restart` if you want to restart Klipper manually.

## Discovery and interactive safety model

Detection uses two confidence levels of evidence:

- **High confidence**:
  - exact known slow sensor type matches: `aht10`, `aht20`, `aht3x`
  - directly in heater options (for example `sensor_type`) or in linked sensor sections
- **Heuristics (medium/low confidence)**:
  - heater/sensor/section names or references containing tokens: `aht`, `vivid`, `dryer`, `chamber`

`--discover` always prints a candidate report with file path, heater section name, current kind, linked sensor reference (when known), reason(s), and confidence.

In interactive mode (`--interactive`), the report is shown first and you are prompted before any conversion is applied. If you decline, installer exits cleanly with no changes.

Recommendation: always review the proposed conversions before applying, especially when heuristic/low-confidence matches are present.

Migration/backward-compatibility note:

- If a `[heater_generic ...]` section already contains slow-heater-only options (`refresh_time`, `max_mcu_duration`, `sensor_timeout`, `schedule_lead_time`), the installer now treats it as high-confidence and converts it to `[heater_slow ...]` automatically.
- Existing `[heater_slow ...]` sections remain supported; installer runs continue to be idempotent and only add missing defaults.
- **Migrating from `[slow_heater ...]`:** If your config still has `[slow_heater <name>]` sections from a previous install, re-running `install.sh` will automatically detect and rename them to `[heater_slow <name>]`. No manual editing is required.

## Uninstall

```bash
cd ~/slowheaters
bash uninstall.sh
```

The uninstall script:

- locates the newest backup in `/backups/`
- restores the original `[heater_generic ...]` sections from backup
- removes `heater_slow.py` from Klipper's extras directory
- restarts Klipper

Running uninstall again is also safe as long as a backup file still exists.

## Update

```bash
cd ~/slowheaters
git pull
bash install.sh
```

## Manual validation

Validate the Klipper extra syntax:

```bash
python3 -m py_compile extras/heater_slow.py
```

Validate the shell scripts:

```bash
bash -n install.sh uninstall.sh
```

Run regression tests for slow-heater control semantics:

```bash
python3 -m unittest discover -s tests
```

Recommended functional test:

1. Start with one or more `[heater_generic ...]` sections tied to slow-reporting sensors.
2. Run `bash install.sh --discover` and review confidence/reasons.
3. Run `bash install.sh --interactive --all` (or `bash install.sh` for high-confidence-only apply).
4. Confirm converted sections became `[heater_slow ...]` and that a backup file was created in `backups/`.
5. Run `bash uninstall.sh`.
6. Confirm the original `[heater_generic ...]` sections were restored.

## Notes

- Keep your normal `verify_heater`, `heater_fan`, and sensor sections unchanged.
- The extra exposes `requested_power`, `refreshed_power`, `sensor_age`, `refresh_time`, `max_mcu_duration`, and `sensor_timeout` in status output for debugging.
- This project is intended for experimentally validating slow-response heater setups. Test attended and conservatively first.

## License and acknowledgements

This project is licensed under GPL-3.0-or-later. See `/LICENSE`.

Thanks to:

- [Klipper](https://www.klipper3d.org/) for the host and heater framework this extra builds on
- [AFC-Klipper-Add-On](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On) for the surrounding ecosystem that helped motivate this workflow
- the `lameandboard/rfid` project for the installer structure this repository now follows
