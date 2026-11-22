"""Run app-owned source contracts without a Python ML environment."""
import importlib.util
from pathlib import Path
import unittest

def load_tests(loader, tests, pattern):
    for path in sorted(Path(__file__).with_name("AppContracts").glob("test_*.py")):
        spec = importlib.util.spec_from_file_location(path.stem, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for name, value in vars(module).items():
            if name.startswith("test_") and callable(value):
                tests.addTest(unittest.FunctionTestCase(value, description=path.stem + "." + name))
    return tests
