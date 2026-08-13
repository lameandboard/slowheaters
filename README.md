# heater_slow

## ⚠️ DISCLAIMER: USE AT YOUR OWN RISK

**This project modifies critical heater control functionality in Klipper. Improper configuration or malfunction could result in:**
- **Fire hazard** — uncontrolled heating could ignite printer components or nearby materials
- **Equipment damage** — thermal runaway or sensor failures may destroy heating elements
- **Personal injury** — severe burns or property damage from overheating

**By using this project, you assume ALL risk.** The authors provide NO WARRANTY, GUARANTEE, or ASSUMPTION OF LIABILITY.

---

`heater_slow` is a tiny Klipper extra for slow-reporting sensors (e.g. AHT20, Vivid dryer probes).

It behaves exactly like a normal Klipper heater, with one additional option: `max_duration`, which extends the MCU PWM watchdog window so the MCU does not cut heater output between slow sensor reports.

## Install

Clone the repository and run the install script:

```bash
cd ~
git clone https://github.com/lameandboard/slowheaters.git slowheaters
cd slowheaters
bash install.sh --interactive
```

The installer will:
1. Scan your full Klipper config tree for slow-sensor heater candidates
2. Show a discovery report with confidence and reasons
3. Prompt you before converting any `[heater_generic X]` sections to `[heater_slow X]`
4. Back up converted sections to `backups/`
5. Copy `heater_slow.py` into `klippy/extras/`
6. Add a `[update_manager slowheaters]` block to `moonraker.conf`
7. Restart Klipper

**Common options:**

```bash
# Report-only scan — no changes, no restart
bash install.sh --discover

# Show report and prompt before applying (recommended first run)
bash install.sh --interactive

# Apply all discovered candidates non-interactively
bash install.sh --all

# Skip Klipper restart
bash install.sh --no-restart
```

**Environment overrides:**

```bash
KLIPPER_CONFIG=~/printer_data/config/printer.cfg \
KLIPPER_EXTRAS_DIR=~/klipper/klippy/extras \
KLIPPER_SERVICE=klipper \
MOONRAKER_CONF=~/printer_data/config/moonraker.conf \
bash install.sh
```

## Uninstall

```bash
cd ~/slowheaters
bash uninstall.sh
```

The uninstall script:
- Restores the original `[heater_generic X]` sections from the most recent backup
- Removes `heater_slow.py` from Klipper extras
- Removes the `[update_manager slowheaters]` block from `moonraker.conf`
- Restarts Klipper

Accepts the same `--no-restart` flag and environment overrides as `install.sh`.

## Moonraker Update Manager

After install, `moonraker.conf` will contain:

```ini
# >>> slowheaters update-manager >>>
[update_manager slowheaters]
type: git_repo
path: ~/slowheaters
origin: https://github.com/lameandboard/slowheaters.git
primary_branch: main
managed_services: klipper
install_script: install.sh
# <<< slowheaters update-manager <<<
```

This lets you update `heater_slow` directly from Mainsail or Fluidd without running `git pull` manually.

## Configure

Use a normal Klipper heater config block, but change the section type from `[heater_generic <name>]` to `[heater_slow <name>]`.

All standard Klipper heater options (`heater_pin`, `sensor_type`, `min_temp`, `max_temp`, `control`, PID settings, `max_power`, etc.) work exactly as normal.

The only custom option this extra adds is:

- `max_duration` *(optional, default: `10.0`)* — MCU PWM watchdog window in seconds. Increase this if your sensor reports less frequently than the default Klipper watchdog allows.

### Example

```ini
[heater_slow my_dryer]
heater_pin: PB1
sensor_type: AHT20
sensor_pin: PA0
min_temp: 0
max_temp: 70
control: pid
pid_kp: 12.0
pid_ki: 0.5
pid_kd: 45.0
# max_duration is optional; default is 10.0 seconds
max_duration: 10.0
```

See `heater_slow_simple_example.cfg` for a ready-to-paste example.

## Validation

```bash
python3 -m py_compile extras/heater_slow.py
```

## License and Acknowledgments

This project is licensed under **GPL-3.0-or-later**. See `/LICENSE`.

`extras/heater_slow.py` inherits from Klipper's `heaters.Heater` class, so this project is a **derived GPL work** and must remain distributed under GPL-compatible terms.

### Attribution

- [Klipper](https://www.klipper3d.org/) — core host firmware framework and the GPL v3 `heaters.Heater` base class this project builds on
- [AFC-Klipper-Add-On](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On) — ecosystem inspiration
- [lameandboard/rfid](https://github.com/lameandboard/rfid) — installer and restart-flow patterns
- BTT (BigTreeTech) — Vivid temperature sensor hardware support target
