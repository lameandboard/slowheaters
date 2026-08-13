import importlib.util
import pathlib
import sys
import types
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "extras" / "heater_slow.py"


class FakeMCUPWM:
    def __init__(self):
        self.max_duration = None

    def setup_max_duration(self, duration):
        self.max_duration = duration


class FakePrinter:
    def __init__(self):
        self.objects = {}
        self.heaters_obj = None

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

    def register_sensor(self, _config, _heater):
        pass


def load_module():
    extras_pkg = types.ModuleType("extras")
    extras_pkg.__path__ = [str(MODULE_PATH.parent)]
    sys.modules["extras"] = extras_pkg

    heaters_mod = types.ModuleType("extras.heaters")

    class Heater:
        def __init__(self, config, _sensor):
            self.printer = config.get_printer()
            self.name = config.get_name()
            self.mcu_pwm = FakeMCUPWM()

        def get_status(self, _eventtime):
            return {"temperature": 0.0, "target": 0.0, "power": 0.0}

    heaters_mod.Heater = Heater
    sys.modules["extras.heaters"] = heaters_mod

    spec = importlib.util.spec_from_file_location("extras.heater_slow", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["extras.heater_slow"] = module
    spec.loader.exec_module(module)
    return module


class HeaterSlowTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.printer = FakePrinter()
        self.config = FakeConfig("heater_slow chamber", self.printer)
        self.heater = self.module.HeaterSlow(self.config, sensor=object())

    def test_default_max_duration_applied(self):
        self.assertAlmostEqual(self.heater.mcu_pwm.max_duration, 10.0)

    def test_custom_max_duration_applied(self):
        config = FakeConfig("heater_slow x", self.printer, {"max_duration": "20.0"})
        heater = self.module.HeaterSlow(config, sensor=object())
        self.assertAlmostEqual(heater.mcu_pwm.max_duration, 20.0)

    def test_get_status_exposes_max_duration(self):
        status = self.heater.get_status(0.0)
        self.assertIn("max_duration", status)
        self.assertAlmostEqual(status["max_duration"], 10.0)

    def test_get_status_includes_standard_fields(self):
        status = self.heater.get_status(0.0)
        for field in ("temperature", "target", "power"):
            self.assertIn(field, status)

    def test_load_config_prefix_registers_heater(self):
        pheaters = FakeHeatersManager()
        self.printer.heaters_obj = pheaters
        heater = self.module.load_config_prefix(self.config)
        self.assertIs(heater, pheaters.heaters["chamber"])
        self.assertIn("heater_slow chamber", pheaters.available_heaters)


if __name__ == "__main__":
    unittest.main()
