# Slow-reporting sensor heater support for Klipper
#
# This module subclasses Klipper's normal Heater class so it keeps the
# existing heater behavior (PID / watermark control, temperature checks,
# verify_heater, pid_calibrate, SET_HEATER_TEMPERATURE, M105/status, etc.)
# and changes only the heater-output scheduling path.
#
# Intended for slow-reporting temperature sensors such as AHT10/AHT20/AHT3X
# used for filament dryers / chamber heaters.
#
# SPDX-License-Identifier: GPL-3.0-or-later

import logging

from . import heaters


class SlowHeater(heaters.Heater):
    """Normal Klipper heater logic with independent MCU PWM refresh.

    The stock Heater class updates the heater pin from the temperature
    callback. That works well for normal thermistors, but a sensor that only
    reports every several seconds can leave scheduled heater events farther
    apart than the MCU max_duration safety window.

    This subclass keeps Klipper's normal temperature and control logic, but:
      * set_pwm() stores the controller's requested PWM value
      * a reactor timer refreshes the MCU heater output independently
      * max_mcu_duration remains a short MCU-side failsafe
      * stale sensor data forces the requested output to zero
    """

    def __init__(self, config, sensor):
        # Slow-heater-specific settings must exist before calling Heater.__init__
        # because Heater installs callbacks that ultimately call self.set_pwm().
        self.refresh_time = config.getfloat(
            'refresh_time', 1.0, above=0.0)
        self.max_mcu_duration = config.getfloat(
            'max_mcu_duration', heaters.MAX_HEAT_TIME, above=0.0)
        self.sensor_timeout = config.getfloat(
            'sensor_timeout', 15.0, above=0.0)
        self.schedule_lead_time = config.getfloat(
            'schedule_lead_time', 0.100, above=0.0)

        # Require comfortable margin so a normal refresh should arrive well
        # before the MCU's max-duration watchdog can expire.
        if self.refresh_time >= (self.max_mcu_duration * 0.5):
            raise config.error(
                "slow_heater refresh_time (%.3fs) must be less than half "
                "max_mcu_duration (%.3fs)"
                % (self.refresh_time, self.max_mcu_duration))

        if self.schedule_lead_time >= self.max_mcu_duration:
            raise config.error(
                "slow_heater schedule_lead_time (%.3fs) must be less than "
                "max_mcu_duration (%.3fs)"
                % (self.schedule_lead_time, self.max_mcu_duration))

        self.requested_pwm = 0.0
        self.last_refresh_pwm = 0.0
        self.last_refresh_print_time = 0.0
        self._slow_ready = False

        # This is the complete normal Klipper Heater initialization path:
        # sensor min/max + callback, PID/watermark control, PWM pin setup,
        # verify_heater, pid_calibrate, SET_HEATER_TEMPERATURE, status, etc.
        super().__init__(config, sensor)

        # Override only this heater's MCU safety duration. Stock Klipper uses
        # MAX_HEAT_TIME here; this plugin keeps it configurable per slow heater.
        self.mcu_pwm.setup_max_duration(self.max_mcu_duration)

        # Workaround for temperature_combined sensors: Klipper's Heater.__init__
        # reads min_temp/max_temp from the sensor, but temperature_combined
        # doesn't expose heater-specific limits. Explicitly read them from config
        # if present, overriding the sensor defaults. This ensures Mainsail/Fluidd
        # can set target temperatures correctly.
        self.min_temp = config.getfloat('min_temp', default=0.0)
        self.max_temp = config.getfloat('max_temp', default=250.0)

        self._reactor = self.printer.get_reactor()
        self._refresh_timer = self._reactor.register_timer(self._refresh_event)

        self.printer.register_event_handler(
            "klippy:ready", self._handle_slow_ready)
        self.printer.register_event_handler(
            "gcode:request_restart", self._handle_slow_restart)

        logging.info(
            "%s: SlowHeater enabled: sensor_report=%.3fs refresh=%.3fs "
            "max_mcu_duration=%.3fs sensor_timeout=%.3fs lead=%.3fs "
            "temp_range=%.1f-%.1f°C",
            self.name, self.pwm_delay, self.refresh_time,
            self.max_mcu_duration, self.sensor_timeout,
            self.schedule_lead_time, self.min_temp, self.max_temp)

    def _handle_slow_ready(self):
        self._slow_ready = True
        eventtime = self._reactor.monotonic()
        self._reactor.update_timer(
            self._refresh_timer, eventtime + self.refresh_time)

    def _handle_slow_restart(self, print_time=0.0):
        self.requested_pwm = 0.0
        self.last_refresh_pwm = 0.0
        self._slow_ready = False

    def _handle_shutdown(self):
        # Preserve the stock Heater shutdown behavior.
        super()._handle_shutdown()
        self.requested_pwm = 0.0
        self.last_refresh_pwm = 0.0
        self._slow_ready = False

    def set_pwm(self, read_time, value):
        """Store the PWM request produced by Klipper's normal controller.

        This is the one stock Heater method we intentionally replace.
        PID / watermark still call heater.set_pwm() exactly as before, but
        we do not schedule a pin event here. The independent refresh timer
        does that at refresh_time intervals.
        """
        if self.target_temp <= 0.0 or read_time > self.verify_mainthread_time:
            value = 0.0

        value = max(0.0, min(self.max_power, value))
        self.requested_pwm = value

        # Preserve stock status semantics: "power" reflects the last requested
        # heater PWM. The actual pin is refreshed below on its own cadence.
        self.last_pwm_value = value

    def _refresh_event(self, eventtime):
        if not self._slow_ready or self.printer.is_shutdown():
            return self._reactor.NEVER

        mcu = self.mcu_pwm.get_mcu()
        print_time = mcu.estimated_print_time(eventtime)

        pwm = self.requested_pwm

        # Preserve Heater's host-side safety behavior.
        if self.target_temp <= 0.0:
            pwm = 0.0
        elif print_time > self.verify_mainthread_time:
            pwm = 0.0

        # Additional safety for a slow sensor: never keep refreshing heat if
        # the sensor has stopped reporting.
        if self.target_temp > 0.0:
            sensor_age = print_time - self.last_temp_time
            if self.last_temp_time <= 0.0 or sensor_age > self.sensor_timeout:
                pwm = 0.0
                self.requested_pwm = 0.0
                logging.warning(
                    "%s: temperature data stale (age=%.3fs, timeout=%.3fs); "
                    "forcing heater PWM off",
                    self.name, sensor_age, self.sensor_timeout)

        # Keep the command slightly ahead of estimated MCU print time.
        # Do not intentionally queue far into the future; the point of this
        # plugin is frequent refreshes inside max_mcu_duration.
        pwm_time = print_time + self.schedule_lead_time

        # Avoid a backwards / duplicate print-time request if the clock estimate
        # moves slightly between timer callbacks.
        if pwm_time <= self.last_refresh_print_time:
            pwm_time = self.last_refresh_print_time + 0.001

        # Prevent sensor-lag overshoot: slow sensors may not report a rising
        # temperature for several seconds.  If the last known reading is already
        # at or above the target, stop refreshing heat immediately rather than
        # continuing to blast the previous PID output.  Applied last so no
        # subsequent logic can re-enable heat before the MCU write.  PID will
        # resume sending positive PWM via set_pwm() once the sensor reports the
        # temperature has dropped below target again.
        if self.target_temp > 0.0 and self.last_temp >= self.target_temp:
            pwm = 0.0

        self.mcu_pwm.set_pwm(pwm_time, pwm)
        self.last_refresh_print_time = pwm_time
        self.last_refresh_pwm = pwm
        self.last_pwm_value = pwm

        return eventtime + self.refresh_time

    def get_status(self, eventtime):
        # Start with Klipper's normal heater status.
        # Guard against any exception inside super().get_status() (e.g. if
        # the MCU or lock is not yet ready) so Moonraker always receives a
        # well-formed dict rather than null values for all fields.
        try:
            status = super().get_status(eventtime)
        except Exception:
            status = {}

        # Mainsail/Fluidd determine the allowed target range from the
        # "temperature", "target", "power", "min_temp" and "max_temp" fields
        # of the printer object they render ("heater_generic <name>").
        # Klipper's base Heater.get_status() provides temperature/target/power,
        # but NOT min_temp/max_temp.  Moonraker returns null for any key that
        # is absent from the status dict, which causes the UI to clamp the
        # target slider to 0.  Force all five fields to explicit numeric values
        # so Moonraker always returns non-null for a printer/objects/query.
        status['temperature'] = float(
            status['temperature'] if status.get('temperature') is not None
            else 0.0)
        status['target'] = float(
            status['target'] if status.get('target') is not None
            else self.target_temp if self.target_temp is not None else 0.0)
        status['power'] = float(
            status['power'] if status.get('power') is not None
            else self.last_pwm_value if self.last_pwm_value is not None else 0.0)
        status['min_temp'] = float(self.min_temp)
        status['max_temp'] = float(self.max_temp)

        # Extra debugging fields are harmless to Mainsail / macros and make
        # testing this experimental heater easier.
        # Compute sensor age defensively; MCU may not be ready at query time.
        try:
            mcu = self.mcu_pwm.get_mcu()
            print_time = mcu.estimated_print_time(eventtime)
            sensor_age = round(max(0.0, print_time - self.last_temp_time), 3)
        except Exception:
            sensor_age = 0.0

        status.update({
            'slow_heater_active': True,
            'requested_power': self.requested_pwm,
            'refreshed_power': self.last_refresh_pwm,
            'sensor_age': sensor_age,
            'refresh_time': self.refresh_time,
            'max_mcu_duration': self.max_mcu_duration,
            'sensor_timeout': self.sensor_timeout,
            'schedule_lead_time': self.schedule_lead_time,
        })
        return status


def load_config_prefix(config):
    """Create a heater from a [slow_heater <name>] config section."""
    printer = config.get_printer()
    pheaters = printer.load_object(config, 'heaters')

    heater_name = config.get_name().split()[-1]
    if heater_name in pheaters.heaters:
        raise config.error("Heater %s already registered" % (heater_name,))

    # Use the exact same sensor factory path as Klipper's setup_heater().
    sensor = pheaters.setup_sensor(config)

    # Build our Heater subclass, then register it with Klipper's global heater
    # registry exactly as heater_generic / heater_bed ultimately are.
    # NOTE: do NOT call pheaters.register_sensor() here.  That adds the heater
    # to available_sensors, which causes Moonraker frontends (Mainsail/Fluidd)
    # to treat it as a read-only temperature sensor instead of a controllable
    # heater with a target temperature input widget.
    heater = SlowHeater(config, sensor)
    pheaters.heaters[heater_name] = heater

    # Mainsail and Fluidd determine whether to show a target temperature input
    # widget by checking whether the printer object name starts with "heater_"
    # (or "extruder"/"temperature_fan").  Because our config section is named
    # [slow_heater <name>], Klipper registers the object as "slow_heater <name>"
    # which does not match that prefix, so the UI silently hides the target box.
    #
    # Fix: also register the same object under "heater_generic <name>" in the
    # Klipper printer object namespace, and expose that alias in
    # available_heaters.  Moonraker subscribes to "heater_generic <name>",
    # receives the canonical {temperature, target, power} status fields, and
    # the frontend correctly renders the target control.  SET_HEATER_TEMPERATURE
    # and all other gcode remain unaffected because they key off heater_name
    # (the bare name without prefix), not the full object name.
    heater_generic_name = 'heater_generic %s' % (heater_name,)
    printer.add_object(heater_generic_name, heater)
    pheaters.available_heaters.append(heater_generic_name)
    return heater
