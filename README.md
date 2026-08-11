# slowheaters

`slowheaters` is a Klipper extra for slow-reporting heater sensors such as AHT10/AHT20/AHT3X dryers or chambers. It keeps Klipper's normal heater logic and changes only the MCU output refresh path so the heater can be refreshed safely while a sensor reports less frequently.

## Quick start

> [!WARNING]
> Back up your printer config before testing any heater changes. `./install.sh` creates a timestamped backup of only the matching Vivid heater sections in `./backups/`, but you should still keep your own known-good printer backup.

Install:

```sh
./install.sh
```

Uninstall and restore the latest backed-up Vivid heater sections:

```sh
./uninstall.sh
```

By default the scripts use:

- Klipper config: `~/printer_data/config/printer.cfg`
- Klipper extras directory: `~/klipper/klippy/extras`
- Klipper service: `klipper`

For non-standard paths you can override them with `KLIPPER_CONFIG`, `KLIPPER_EXTRAS_DIR`, and `KLIPPER_SERVICE`.

## What the install script changes

`install.sh`:

- finds every `[heater_generic Vivid_*]` section in `printer.cfg`
- stores only those Vivid heater sections in a timestamped backup under `backups/`
- converts each matching section to `[slow_heater Vivid_*]`
- preserves the existing heater settings and adds these defaults when missing:
  - `refresh_time: 1.0`
  - `max_mcu_duration: 3.0`
  - `sensor_timeout: 15.0`
  - `schedule_lead_time: 0.100`
- copies `slow_heater.py` into Klipper's extras directory
- verifies Python syntax before restarting Klipper

`uninstall.sh`:

- finds every `[slow_heater Vivid_*]` section in `printer.cfg`
- restores those sections from the newest backup in `backups/`
- removes `slow_heater.py` from the Klipper extras directory
- restarts Klipper after restoration

Both scripts report which heaters were found and whether they were updated or restored. If the config already appears installed or uninstalled, the scripts say so and avoid duplicating changes.

## Example config

Replace:

```ini
[heater_generic Vivid_1_dryer]
```

with:

```ini
[slow_heater Vivid_1_dryer]
heater_pin:         Vivid_1:HEATER

sensor_type:        temperature_combined
sensor_list:        aht10 Vivid_1_dryer_left, aht10 Vivid_1_dryer_right
combination_method: max
maximum_deviation:  100

control:            pid
pid_Kp:             51.604
pid_Ki:             1.121
pid_Kd:             593.934

min_temp:           -20
max_temp:           75

# slow_heater-specific
refresh_time:       1.0
max_mcu_duration:   3.0
sensor_timeout:     15.0
schedule_lead_time: 0.100
```

Keep related sections such as `[verify_heater ...]` and `[heater_fan ...]` unchanged.

## How it works

The normal Klipper logic is retained for:

- sensor setup and min/max checking
- `temperature_combined`
- PID control
- watermark / bang-bang control
- `verify_heater`
- `pid_calibrate`
- `SET_HEATER_TEMPERATURE`
- `TURN_OFF_HEATERS`
- temperature smoothing
- `M105` / heater status
- main-thread heater safety checks

The difference is that PID or watermark updates store the requested heater power, while a short timer independently refreshes the MCU heater output.

```text
AHT temperature report (~5 s)
          |
          v
normal Klipper PID / watermark logic
          |
          v
requested PWM stored
          |
          +-----------------------------+
                                        |
1.0 s refresh timer <-------------------+
          |
          v
mcu_pwm.set_pwm()
          |
          v
Vivid heater output

MCU max-duration watchdog: 3.0 s
Sensor stale cutoff:      15.0 s
```

So a slow sensor does not require extending the MCU watchdog to 10 seconds. If the Klipper host stops refreshing the MCU, the normal short MCU watchdog is still present. If the sensor stops reporting while the host remains alive, the plugin stops refreshing heat after `sensor_timeout`.

Extra status values are exposed under `printer["slow_heater Vivid_1_dryer"]`: `requested_power`, `refreshed_power`, `sensor_age`, `refresh_time`, `max_mcu_duration`, and `sensor_timeout`.

## Testing sequence

This is experimental heater-control code. Test attended and at a conservative dryer temperature first.

1. Start Klipper with target `0` and verify no config errors.
2. Set the dryer to a low target.
3. Confirm heater power appears in Mainsail.
4. Set target to `0` and verify the heater turns off promptly.
5. Run `TURN_OFF_HEATERS` and verify it turns off promptly.
6. Let it regulate for a while while the printer is idle.
7. Run the same print that previously reproduced `Scheduled digital out event will exceed max_duration`.
8. Check `klippy.log` for Vivid shutdowns.
9. Only after the above is stable, test longer prints.

## Attribution

This project builds on the Klipper heater model and is intended to be used as a Klipper extra. Credit and thanks to:

- [Klipper](https://www.klipper3d.org/) for the core heater implementation that this plugin subclasses
- AFC (Adaptive Filament Cooling) for related dryer-control ideas and prior experimentation in this area

## License

This repository is licensed under GPL-3.0-or-later. See `LICENSE`.
