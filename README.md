# slowheaters

`slowheaters` adds a Klipper `slow_heater` extra for slow-reporting sensors such as Vivid dryer sensors. It keeps Klipper's normal heater behavior and only changes the heater-output refresh path so the MCU watchdog is refreshed safely between slow temperature reports.

## Repository layout

- `/extras/slow_heater.py` - the Klipper extra installed by `install.sh`
- `/install.sh` - installs the extra and converts matching Vivid heaters
- `/uninstall.sh` - restores the most recent backed-up Vivid sections
- `/backups/` - created by the installer for timestamped Vivid-section backups

## What the installer does

`install.sh` follows the same workflow pattern as the RFID project:

1. Validates `extras/slow_heater.py`
2. Copies it to `~/klipper/klippy/extras/slow_heater.py`
3. Scans the full Klipper config tree starting from `printer.cfg`, including `[include ...]` files
4. Finds every `[heater_generic Vivid_*]` section
5. Backs up only those Vivid sections to `backups/vivid_sections_YYYYMMDD_HHMMSS.json`
6. Converts them to `[slow_heater Vivid_*]`
7. Adds default slow-heater settings when missing:
   - `refresh_time: 1.0`
   - `max_mcu_duration: 3.0`
   - `sensor_timeout: 15.0`
   - `schedule_lead_time: 0.100`
8. Restarts Klipper through Moonraker when available, otherwise falls back to `systemctl`

Running the installer again is safe: existing `slow_heater` sections are detected and only missing defaults are added.

## Install

```bash
cd ~/slowheaters
bash install.sh
```

Optional environment overrides:

```bash
KLIPPER_CONFIG=~/printer_data/config/printer.cfg \
KLIPPER_EXTRAS_DIR=~/klipper/klippy/extras \
KLIPPER_SERVICE=klipper \
bash install.sh
```

Use `--no-restart` if you want to restart Klipper manually.

## Uninstall

```bash
cd ~/slowheaters
bash uninstall.sh
```

The uninstall script:

- locates the newest backup in `/backups/`
- restores the original `[heater_generic Vivid_*]` sections
- removes `slow_heater.py` from Klipper's extras directory
- restarts Klipper

Running uninstall again is also safe as long as a backup file still exists.

## Manual validation

Validate the Klipper extra syntax:

```bash
python3 -m py_compile extras/slow_heater.py
```

Validate the shell scripts:

```bash
bash -n install.sh uninstall.sh
```

Recommended functional test:

1. Start with one or more `[heater_generic Vivid_*]` sections.
2. Run `bash install.sh`.
3. Confirm the sections became `[slow_heater Vivid_*]` and that a backup file was created in `backups/`.
4. Run `bash uninstall.sh`.
5. Confirm the original `[heater_generic Vivid_*]` sections were restored.

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
