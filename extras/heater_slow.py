# heater_slow.py - Minimal slow-sensor heater extra for Klipper
#
# Use:
#   [heater_slow <name>]
#
# Behaves like a normal Klipper heater but lets you extend the MCU PWM
# watchdog window via max_duration (useful for slow-reporting sensors).
#
# SPDX-License-Identifier: GPL-3.0-or-later

from . import heaters


class HeaterSlow(heaters.Heater):
    """Normal Klipper Heater with a configurable MCU PWM max_duration."""

    def __init__(self, config, sensor):
        super().__init__(config, sensor)
        max_duration = config.getfloat('max_duration', 10.0, above=0.0)
        self.mcu_pwm.setup_max_duration(max_duration)
        self._max_duration = max_duration

    def get_status(self, eventtime):
        status = super().get_status(eventtime)
        status['max_duration'] = self._max_duration
        return status


def load_config_prefix(config):
    """Register [heater_slow <name>] as a normal Klipper heater."""
    printer = config.get_printer()
    pheaters = printer.load_object(config, 'heaters')
    sensor = pheaters.setup_sensor(config)
    heater = HeaterSlow(config, sensor)
    heater_name = config.get_name().split()[-1]
    pheaters.heaters[heater_name] = heater
    pheaters.register_sensor(config, heater)
    pheaters.available_heaters.append(config.get_name())
    return heater
