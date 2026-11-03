"""Runs every companion app test, which live by area in tests/bridge. From the repo root: python3.14 tests/test_bridge.py

Extra arguments go to unittest, so -k picks tests by name, for example: python3.14 tests/test_bridge.py -k settling
"""
import sys
import unittest
from pathlib import Path

if sys.version_info < (3, 14):
    sys.exit("These tests need Python 3.14 or newer, the same as the installer. Try: python3.14 tests/test_bridge.py")

TESTS = str(Path(__file__).resolve().parent / "bridge")

if __name__ == "__main__":
    unittest.main(module=None, argv=[sys.argv[0], "discover", "-s", TESTS, "-t", TESTS, *sys.argv[1:]], verbosity=1)
