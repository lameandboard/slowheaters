# heater_slow.py - Slow-reporting sensor heater support for Klipper
#
# Mainsail-compatible custom heater type.
#
# Use:
#   [heater_slow my_heater]
#
# The "heater_" prefix is intentional. Mainsail treats objects whose names
# begin with "heater_" as controllable heaters and reads min_temp/max_temp
# from the matching config section.
#
# This class inherits Klipper's normal heaters.Heater implementation and only
# changes how heater PWM is scheduled:
#   - PID / watermark logic remains Klipper's normal logic
#   - slow sensor callbacks update the requested PWM
#   - a reactor timer refreshes the MCU output independently
#   - the MCU max_duration watchdog remains short
#   - stale sensor data forces heater output off
#
# Experimental heater-control code. Test attended.
#
# SPDX-License-Identifier: GPL-3.0-or-later

import logging

from . import heaters


class HeaterSlow(heaters.Heater):
    """Normal Klipper Heater logic with independent PWM refresh."""

    def __init__(self, config, sensor):
        # Plugin-specific timing options.
        self.refresh_time = config.getfloat(
            'refresh_time', 1.0, above=0.0)
        self.max_mcu_duration = config.getfloat(
            'max_mcu_duration', heaters.MAX_HEAT_TIME, above=0.0)
        self.sensor_timeout = config.getfloat(
            'sensor_timeout', 15.0, above=0.0)
        self.schedule_lead_time = config.getfloat(
            'schedule_lead_time', 0.100, above=0.0)

        # Keep enough watchdog margin for jitter / host scheduling delays.
        if self.refresh_time >= self.max_mcu_duration:
            raise config.error(
                "refresh_time (%.3fs) must be less than "
                "max_mcu_duration (%.3fs)"
                % (self.refresh_time, self.max_mcu_duration))

        if self.refresh_time > self.max_mcu_duration * 0.5:
            raise config.error(
                "refresh_time (%.3fs) must be no more than half of "
                "max_mcu_duration (%.3fs)"
                % (self.refresh_time, self.max_mcu_duration))

        if self.schedule_lead_time >= self.max_mcu_duration:
            raise config.error(
                "schedule_lead_time (%.3fs) must be less than "
                "max_mcu_duration (%.3fs)"
                % (self.schedule_lead_time, self.max_mcu_duration))

        if self.sensor_timeout <= self.refresh_time:
            raise config.error(
                "sensor_timeout (%.3fs) must be greater than "
                "refresh_time (%.3fs)"
                % (self.sensor_timeout, self.refresh_time))

        self.requested_pwm = 0.0
        self.refreshed_pwm = 0.0
        self.last_refresh_print_time = 0.0

        self._slow_ready = False
        self._stale_warning_active = False

        # Keep Klipper's complete normal Heater behavior:
        # sensor setup, min/max, smoothing, PID/watermark, verify_heater,
        # pid_calibrate, SET_HEATER_TEMPERATURE, status, shutdown handling.
        super().__init__(config, sensor)

        # Override max_duration only for this custom heater.
        self.mcu_pwm.setup_max_duration(self.max_mcu_duration)

        self._reactor = self.printer.get_reactor()
        self._refresh_timer = self._reactor.register_timer(
            self._refresh_event)

        self.printer.register_event_handler(
            "klippy:ready", self._handle_ready)
        self.printer.register_event_handler(
            "gcode:request_restart", self._handle_restart)

        logging.info(
            "%s: heater_slow enabled "
            "(sensor_report=%.3fs refresh=%.3fs "
            "max_mcu_duration=%.3fs sensor_timeout=%.3fs lead=%.3fs)",
            self.name, self.pwm_delay, self.refresh_time,
            self.max_mcu_duration, self.sensor_timeout,
            self.schedule_lead_time)

    def _handle_ready(self):
        self._slow_ready = True
        eventtime = self._reactor.monotonic()
        self._reactor.update_timer(
            self._refresh_timer, eventtime + self.refresh_time)

    def _handle_restart(self, print_time=0.0):
        self.requested_pwm = 0.0
        self.refreshed_pwm = 0.0
        self._slow_ready = False
        self._stale_warning_active = False

    def _handle_shutdown(self):
        # Preserve stock Heater shutdown behavior.
        super()._handle_shutdown()
        self.requested_pwm = 0.0
        self.refreshed_pwm = 0.0
        self._slow_ready = False

    def set_pwm(self, read_time, value):
        """Store controller output instead of scheduling it immediately.

        Klipper's stock ControlPID / ControlBangBang still call this method.
        The reactor heartbeat below performs the actual MCU refresh.
        """
        if self.target_temp <= 0.0 or read_time > self.verify_mainthread_time:
            value = 0.0

        value = max(0.0, min(self.max_power, value))
        self.requested_pwm = value
        self.last_pwm_value = value

    def _refresh_event(self, eventtime):
        if not self._slow_ready or self.printer.is_shutdown():
            return self._reactor.NEVER

        mcu = self.mcu_pwm.get_mcu()
        print_time = mcu.estimated_print_time(eventtime)
        pwm = self.requested_pwm

        # Retain Klipper's host-side target / main-thread safety behavior.
        if self.target_temp <= 0.0:
            pwm = 0.0
        elif print_time > self.verify_mainthread_time:
            pwm = 0.0

        # Slow-sensor fail-safe: do not keep refreshing heat indefinitely
        # when temperature reports stop.
        if self.target_temp > 0.0:
            if self.last_temp_time <= 0.0:
                sensor_age = float('inf')
            else:
                sensor_age = print_time - self.last_temp_time

            if sensor_age > self.sensor_timeout:
                pwm = 0.0
                self.requested_pwm = 0.0

                if not self._stale_warning_active:
                    age_text = (
                        "unknown" if sensor_age == float('inf')
                        else "%.3fs" % sensor_age
                    )
                    logging.warning(
                        "%s: temperature data stale "
                        "(age=%s timeout=%.3fs); forcing heater off",
                        self.name, age_text, self.sensor_timeout)
                    self._stale_warning_active = True
            else:
                self._stale_warning_active = False
        else:
            self._stale_warning_active = False

        # Schedule close to current MCU print time and refresh frequently.
        pwm_time = print_time + self.schedule_lead_time

        # Avoid duplicate/backwards scheduled timestamps.
        if pwm_time <= self.last_refresh_print_time:
            pwm_time = self.last_refresh_print_time + 0.001

        self.mcu_pwm.set_pwm(pwm_time, pwm)

        self.last_refresh_print_time = pwm_time
        self.refreshed_pwm = pwm
        self.last_pwm_value = pwm

        return eventtime + self.refresh_time

    def get_status(self, eventtime):
        # Keep stock heater status keys:
        # temperature, target, power
        status = super().get_status(eventtime)

        # Extra diagnostic fields. Frontends safely ignore unknown keys.
        mcu = self.mcu_pwm.get_mcu()
        print_time = mcu.estimated_print_time(eventtime)

        if self.last_temp_time <= 0.0:
            sensor_age = -1.0
        else:
            sensor_age = max(0.0, print_time - self.last_temp_time)

        status.update({
            # Also expose configured limits for API/debug consumers.
            'min_temp': self.min_temp,
            'max_temp': self.max_temp,

            'requested_power': self.requested_pwm,
            'refreshed_power': self.refreshed_pwm,
            'sensor_age': round(sensor_age, 3),
            'refresh_time': self.refresh_time,
            'max_mcu_duration': self.max_mcu_duration,
            'sensor_timeout': self.sensor_timeout,
        })
        return status


def load_config_prefix(config):
    """Load [heater_slow <name>] and register it as a normal Klipper heater."""
    printer = config.get_printer()
    pheaters = printer.load_object(config, 'heaters')

    heater_name = config.get_name().split()[-1]

    if heater_name in pheaters.heaters:
        raise config.error(
            "Heater %s already registered" % heater_name)

    # Same sensor factory path used by Klipper's normal setup_heater().
    sensor = pheaters.setup_sensor(config)

    # Create our Heater subclass.
    heater = HeaterSlow(config, sensor)

    # Same registration path used by Klipper's normal heaters.
    pheaters.heaters[heater_name] = heater
    pheaters.register_sensor(config, heater)
    pheaters.available_heaters.append(config.get_name())

    return heater
