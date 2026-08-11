import importlib.util
import pathlib
import sys
import types
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "extras" / "slow_heater.py"


class FakeMCU:
    def estimated_print_time(self, eventtime):
        return eventtime


class FakeMCUPWM:
    def __init__(self):
        self.mcu = FakeMCU()
        self.max_duration = None
        self.calls = []

    def setup_max_duration(self, duration):
        self.max_duration = duration

    def get_mcu(self):
        return self.mcu

    def set_pwm(self, print_time, pwm):
        self.calls.append((print_time, pwm))


class FakeReactor:
    NEVER = object()

    def __init__(self):
        self.timer = None
        self.updated = None

    def register_timer(self, callback):
        self.timer = callback
        return callback

    def update_timer(self, timer, when):
        self.updated = (timer, when)

    def monotonic(self):
        return 100.0


class FakePrinter:
    def __init__(self):
        self.reactor = FakeReactor()
        self.shutdown = False
        self.handlers = {}
        self.objects = {}
        self.heaters_obj = None

    def get_reactor(self):
        return self.reactor

    def register_event_handler(self, event, handler):
        self.handlers[event] = handler

    def is_shutdown(self):
        return self.shutdown

    def add_object(self, name, obj):
        self.objects[name] = obj

    def load_object(self, _config, name):
        if name != "heaters":
            raise ValueError(name)
        return self.heaters_obj


class FakeConfig:
    def __init__(self, name, printer, values=None):
        self._name = name
        self._printer = printer
        self._values = values or {}

    def get_name(self):
        return self._name

    def get_printer(self):
        return self._printer

    def getfloat(self, key, default, above=None):
        value = float(self._values.get(key, default))
        if above is not None and value <= above:
            raise self.error(f"{key} must be above {above}")
        return value

    def error(self, msg):
        return ValueError(msg)


class FakeHeatersManager:
    def __init__(self):
        self.heaters = {}
        self.available_heaters = []

    def setup_sensor(self, _config):
        return object()


def load_module():
    extras_pkg = types.ModuleType("extras")
    extras_pkg.__path__ = [str(MODULE_PATH.parent)]
    sys.modules["extras"] = extras_pkg

    heaters_mod = types.ModuleType("extras.heaters")
    heaters_mod.MAX_HEAT_TIME = 5.0

    class Heater:
        def __init__(self, config, _sensor):
            self.printer = config.get_printer()
            self.name = config.get_name()
            self.mcu_pwm = FakeMCUPWM()
            self.pwm_delay = 2.0
            self.target_temp = 0.0
            self.verify_mainthread_time = 1.0e9
            self.max_power = 1.0
            self.last_pwm_value = 0.0
            self.last_temp_time = 0.0
            # Klipper Heater sets these from config; expose them so SlowHeater
            # can include them in get_status() for Mainsail temperature limits.
            self.last_temp = 0.0
            self.min_temp = 0.0
            self.max_temp = 120.0

        def _handle_shutdown(self):
            return None

        def get_status(self, _eventtime):
            return {
                "temperature": 0.0,
                "target": self.target_temp,
                "power": self.last_pwm_value,
            }

    heaters_mod.Heater = Heater
    sys.modules["extras.heaters"] = heaters_mod

    spec = importlib.util.spec_from_file_location("extras.slow_heater", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["extras.slow_heater"] = module
    spec.loader.exec_module(module)
    return module


class SlowHeaterRegressionTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.printer = FakePrinter()
        self.config = FakeConfig("slow_heater chamber", self.printer)
        self.heater = self.module.SlowHeater(self.config, sensor=object())

    def test_set_pwm_does_not_directly_write_mcu_output(self):
        self.heater.target_temp = 60.0
        self.heater.set_pwm(read_time=10.0, value=0.7)
        self.assertEqual(self.heater.requested_pwm, 0.7)
        self.assertEqual(self.heater.last_pwm_value, 0.7)
        self.assertEqual(self.heater.mcu_pwm.calls, [])

    def test_refresh_timer_applies_requested_pwm(self):
        self.heater._slow_ready = True
        self.heater.target_temp = 60.0
        self.heater.last_temp_time = 19.9
        self.heater.requested_pwm = 0.4

        next_event = self.heater._refresh_event(20.0)

        self.assertAlmostEqual(next_event, 21.0)
        self.assertEqual(len(self.heater.mcu_pwm.calls), 1)
        pwm_time, pwm = self.heater.mcu_pwm.calls[0]
        self.assertAlmostEqual(pwm_time, 20.1)
        self.assertAlmostEqual(pwm, 0.4)

    def test_stale_sensor_forces_pwm_off(self):
        self.heater._slow_ready = True
        self.heater.target_temp = 60.0
        self.heater.last_temp_time = 0.0
        self.heater.requested_pwm = 0.9

        self.heater._refresh_event(30.0)

        _pwm_time, pwm = self.heater.mcu_pwm.calls[-1]
        self.assertEqual(pwm, 0.0)
        self.assertEqual(self.heater.requested_pwm, 0.0)

    def test_load_config_prefix_keeps_slow_heater_and_adds_ui_alias(self):
        pheaters = FakeHeatersManager()
        self.printer.heaters_obj = pheaters

        heater = self.module.load_config_prefix(self.config)

        self.assertIs(heater, pheaters.heaters["chamber"])
        self.assertIs(heater, self.printer.objects["heater_generic chamber"])
        self.assertIn("heater_generic chamber", pheaters.available_heaters)
        status = heater.get_status(0.0)
        self.assertTrue(status["slow_heater_active"])

    def test_status_exposes_temperature_limits_for_mainsail(self):
        # Root cause of "max temp is 0" in Mainsail: the printer object is
        # registered as "heater_generic <name>" but the Klipper configfile
        # section is "[slow_heater <name>]".  Mainsail cannot find max_temp
        # from the configfile for that alias, so it falls back to 0 and
        # rejects any positive target.  SlowHeater.get_status() must expose
        # max_temp and min_temp directly so Moonraker can forward them.
        self.heater.max_temp = 80.0
        self.heater.min_temp = 5.0

        status = self.heater.get_status(0.0)

        self.assertEqual(status["max_temp"], 80.0)
        self.assertEqual(status["min_temp"], 5.0)

    def test_refresh_cuts_pwm_when_temperature_at_or_above_target(self):
        # Slow sensors update infrequently (every few seconds).  Without a
        # temperature guard the refresh timer keeps sending the previous
        # PID output for the full sensor-report interval even after the
        # temperature has already reached the target, causing overshoot that
        # can trip Klipper's max_temp shutdown ("temp too high").
        self.heater._slow_ready = True
        self.heater.target_temp = 50.0
        self.heater.last_temp_time = 29.5
        self.heater.requested_pwm = 0.8  # PID last said "heat more"
        self.heater.last_temp = 50.0     # but sensor now reads at target

        self.heater._refresh_event(30.0)

        _pwm_time, pwm = self.heater.mcu_pwm.calls[-1]
        self.assertEqual(pwm, 0.0,
            "refresh must not keep heating when last_temp >= target_temp")

    def test_refresh_heats_normally_when_temperature_below_target(self):
        # Confirm the overshoot guard does NOT suppress heat when the
        # temperature is still below target.
        self.heater._slow_ready = True
        self.heater.target_temp = 60.0
        self.heater.last_temp_time = 29.5
        self.heater.requested_pwm = 0.6
        self.heater.last_temp = 40.0  # below target – heat should continue

        self.heater._refresh_event(30.0)

        _pwm_time, pwm = self.heater.mcu_pwm.calls[-1]
        self.assertGreater(pwm, 0.0,
            "refresh must continue heating when last_temp < target_temp")

    def test_moonraker_query_shape_all_fields_non_null(self):
        # Regression test: replicates the exact Moonraker printer/objects/query
        # shape that Mainsail uses.
        #   curl ".../printer/objects/query?heater_generic%20vivid1_dryer=
        #         min_temp,max_temp,temperature,target,power"
        # All five fields must be present and numeric (non-None) so Moonraker
        # returns non-null JSON and Mainsail's target slider accepts values
        # above 0.
        self.heater.min_temp = 0.0
        self.heater.max_temp = 70.0
        self.heater.target_temp = 40.0
        self.heater.last_pwm_value = 0.5

        status = self.heater.get_status(0.0)

        moonraker_fields = ('temperature', 'target', 'power', 'min_temp',
                            'max_temp')
        for field in moonraker_fields:
            self.assertIn(field, status,
                "get_status() must return '%s' so Moonraker does not send "
                "null to Mainsail" % field)
            self.assertIsNotNone(status[field],
                "get_status()['%s'] must not be None" % field)
            self.assertIsInstance(status[field], float,
                "get_status()['%s'] must be a float, got %r"
                % (field, status[field]))

        self.assertGreater(status['max_temp'], 0.0,
            "max_temp must be > 0 so Mainsail allows positive target input")

    def test_target_not_clamped_to_zero_when_limits_present(self):
        # Guard against Mainsail clamping target to 0 because of missing
        # min_temp/max_temp.  If max_temp is present and > 0 in get_status(),
        # Mainsail will accept targets up to max_temp.  Verify that a non-zero
        # target_temp is forwarded correctly alongside valid limits.
        self.heater.min_temp = 0.0
        self.heater.max_temp = 80.0
        self.heater.target_temp = 55.0

        status = self.heater.get_status(0.0)

        self.assertEqual(status['max_temp'], 80.0,
            "max_temp must equal configured max to prevent UI clamping")
        self.assertEqual(status['target'], 55.0,
            "target must reflect current target_temp (not clamped to 0)")
        self.assertGreaterEqual(status['target'], 0.0)
        self.assertLessEqual(status['target'], status['max_temp'])

    def test_get_status_survives_mcu_not_ready(self):
        # If get_status() is called before the MCU is fully initialised
        # (e.g. during Moonraker's initial object subscription), the call to
        # mcu_pwm.get_mcu().estimated_print_time() may raise.  Verify that
        # all five Mainsail-critical fields are still returned with numeric
        # values rather than allowing the exception to propagate and cause
        # Moonraker to return null for every field.
        def boom(_eventtime):
            raise RuntimeError("MCU not ready")

        self.heater.mcu_pwm.get_mcu = lambda: type(
            'BadMCU', (), {'estimated_print_time': boom})()
        self.heater.min_temp = 5.0
        self.heater.max_temp = 90.0
        self.heater.target_temp = 30.0

        # Must not raise; must return dict with all required numeric fields.
        status = self.heater.get_status(0.0)

        for field in ('temperature', 'target', 'power', 'min_temp', 'max_temp'):
            self.assertIn(field, status)
            self.assertIsNotNone(status[field])
            self.assertIsInstance(status[field], float)

        self.assertEqual(status['min_temp'], 5.0)
        self.assertEqual(status['max_temp'], 90.0)


if __name__ == "__main__":
    unittest.main()
