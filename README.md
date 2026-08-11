This plugin uses Klipper's existing heaters.Heater class and changes onlythe output scheduling behavior required for slow-reporting sensors.

The normal Klipper logic is retained for:

sensor setup and min/max checking

temperature_combined

PID control

watermark / bang-bang control

verify_heater

pid_calibrate

SET_HEATER_TEMPERATURE

TURN_OFF_HEATERS

temperature smoothing

M105 / heater status

main-thread heater safety checks

The difference is that PID/watermark updates store their requested heaterpower, while a short timer independently refreshes the MCU heater output.

1. Restore stock heaters.py

Remove the temporary Vivid-specific edit from heaters.py and put it back to:

self.mcu_pwm.setup_max_duration(MAX_HEAT_TIME)

Do not keep the special Vivid_1_dryer 10-second modification when testing thisplugin.

2. Install

Copy slow_heater.py to:

~/klipper/klippy/extras/slow_heater.py

Check Python syntax:

python3 -m py_compile ~/klipper/klippy/extras/slow_heater.py

Then restart Klipper:

sudo systemctl restart klipper

3. Change the Vivid dryer section

Replace:

[heater_generic Vivid_1_dryer]

with:

[slow_heater Vivid_1_dryer]

Keep the normal heater options and add the slow-heater options:

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

Keep these existing sections unchanged:

[verify_heater Vivid_1_dryer]
max_error:       300
check_gain_time: 600
hysteresis:      10
heating_gain:    1

[heater_fan Vivid_1_dryer_fan]
pin:            Vivid_1:DRY_FAN
max_power:      0.3
shutdown_speed: 0
heater:         Vivid_1_dryer

And leave your AHT sensor report time at its supported value:

aht10_report_time: 5

What the timing now looks like

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

So a slow sensor does not require extending the MCU watchdog to 10 seconds.If the Klipper host stops refreshing the MCU, the normal short MCU watchdog isstill present. If the sensor stops reporting while the host remains alive, theplugin stops refreshing heat after sensor_timeout.

First tests

This is experimental heater-control code. Test attended and at a conservativedryer temperature first.

Recommended sequence:

Start Klipper with target 0 and verify no config errors.

Set the dryer to a low target.

Confirm heater power appears in Mainsail.

Set target to 0 and verify heater turns off promptly.

Run TURN_OFF_HEATERS and verify it turns off promptly.

Let it regulate for a while while the printer is idle.

Run the same print that previously reproduced:Scheduled digital out event will exceed max_duration.

Check klippy.log for Vivid shutdowns.

Only after the above is stable, test longer prints.

Extra status values are exposed under printer["slow_heater Vivid_1_dryer"]:requested_power, refreshed_power, sensor_age, refresh_time,max_mcu_duration, and sensor_timeout.

Important

This plugin is intentionally separate from Klipper's normal heater implementation.It should only be used for slow-response dryer/chamber sensors where the normalheater scheduling path has been demonstrated to hit the MCU max_durationsafety check.
