# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Ziem.
#
# This work is licensed under the terms of the GNU GPL, version 3 or
# later. See the LICENSE file in the top-level directory.

import os
import struct
import sys
import unittest
import zipfile

import psutil


EXPECTED_VERSION = "7.2.2"
WHEEL_PATH = os.environ.get("PSUTIL_WHEEL")


class PsutilWheelSmokeTest(unittest.TestCase):
    def test_interpreter_and_version(self):
        self.assertEqual(4, struct.calcsize("P"), "the interpreter must be 32-bit")
        self.assertEqual(EXPECTED_VERSION, psutil.__version__)

    def test_process_name(self):
        self.assertTrue(psutil.Process().name())

    def test_process_iter_enumerates_current_process(self):
        current_pid = os.getpid()
        found_current = False
        for proc in psutil.process_iter(["name", "username"]):
            try:
                if proc.pid == current_pid and proc.info.get("name"):
                    found_current = True
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                continue
        self.assertTrue(found_current, "process_iter did not enumerate the current process")

    def test_disk_partitions_and_usage(self):
        self.assertTrue(psutil.disk_partitions())
        system_drive = os.environ.get("SystemDrive", "C:")
        usage = psutil.disk_usage(system_drive + "\\")
        self.assertGreater(usage.total, 0)
        self.assertGreater(usage.free, 0)

    def test_wheel_contents(self):
        self.assertTrue(WHEEL_PATH, "PSUTIL_WHEEL is not set")
        with zipfile.ZipFile(WHEEL_PATH) as wheel:
            names = set(wheel.namelist())
        dist_info = f"psutil-{EXPECTED_VERSION}.dist-info/"
        self.assertIn("psutil/_psutil_windows.pyd", names)
        self.assertIn(dist_info + "METADATA", names)
        license_files = [
            name
            for name in names
            if name.startswith(dist_info)
            and name.rsplit("/", 1)[-1].upper().startswith("LICENSE")
        ]
        self.assertTrue(license_files, "no license file found in dist-info")


if __name__ == "__main__":
    if not WHEEL_PATH:
        print("PSUTIL_WHEEL is not set", file=sys.stderr)
        sys.exit(2)
    unittest.main(verbosity=2)
