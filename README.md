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
bash install.sh
```

The script copies `heater_slow.py` into `~/klipper/klippy/extras/` and restarts Klipper.

**Options:**

```bash
# Skip the Klipper restart (restart manually afterwards)
bash install.sh --no-restart
```

**Environment overrides:**

```bash
KLIPPER_EXTRAS_DIR=~/klipper/klippy/extras \
KLIPPER_SERVICE=klipper \
bash install.sh
```

## Uninstall

```bash
cd ~/slowheaters
bash uninstall.sh
```

Removes `heater_slow.py` from the Klipper extras directory and restarts Klipper.
Accepts the same `--no-restart` flag and environment overrides as `install.sh`.

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

## License

GPL-3.0-or-later. See `LICENSE`.
