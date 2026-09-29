#!/usr/bin/env python3
"""Unit tests for zz's pure helpers. No ZFS or root needed: python3 tests/test_units.py"""
import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("zz", os.path.join(HERE, "..", "zz"))
_spec = importlib.util.spec_from_loader("zz", _loader)
zz = importlib.util.module_from_spec(_spec)
_loader.exec_module(zz)


class ParseDuration(unittest.TestCase):
    def test_units(self):
        self.assertEqual(zz.parse_duration("90"), 90 * 60)
        self.assertEqual(zz.parse_duration("30m"), 1800)
        self.assertEqual(zz.parse_duration("1h"), 3600)
        self.assertEqual(zz.parse_duration("1.5h"), 5400)
        self.assertEqual(zz.parse_duration("7d"), 7 * 86400)
        self.assertEqual(zz.parse_duration("2w"), 14 * 86400)
        self.assertEqual(zz.parse_duration("1y"), 365 * 86400)
        self.assertEqual(zz.parse_duration(" 8D "), 8 * 86400)

    def test_invalid_raises_instead_of_zero(self):
        # A silent 0 here once meant "prune everything beyond keep_min"
        for bad in ["", "-", "7days", "1year", "forever", "h", "0m", "0", "-5m", "abc"]:
            with self.assertRaises(ValueError, msg=bad):
                zz.parse_duration(bad)


class ParseTarget(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(zz.parse_target("backup:pool/data"), ("backup", "pool/data"))
        self.assertEqual(zz.parse_target("root@10.0.0.2:tank/a/b/"), ("root@10.0.0.2", "tank/a/b"))

    def test_invalid(self):
        for bad in ["nocolon", "host:", ":pool/data", "host:pool", "host:/pool"]:
            with self.assertRaises(ValueError, msg=bad):
                zz.parse_target(bad)


class Formatting(unittest.TestCase):
    def test_human_bytes(self):
        self.assertEqual(zz.human_bytes(0), "0B")
        self.assertEqual(zz.human_bytes(1023), "1023B")
        self.assertEqual(zz.human_bytes(1024), "1.0K")
        self.assertEqual(zz.human_bytes(int(5.8 * 1024 ** 2)), "5.8M")
        self.assertEqual(zz.human_bytes(3 * 1024 ** 5), "3072.0T")

    def test_fmt_gap_rounds_to_nearest_minute(self):
        self.assertEqual(zz.fmt_gap(3600), "1:00")
        self.assertEqual(zz.fmt_gap(3571), "1:00")   # 30s schedule allowance must not show 0:59
        self.assertEqual(zz.fmt_gap(300), "0:05")
        self.assertEqual(zz.fmt_gap(2 * 86400 + 3 * 3600 + 900), "2d 3:15")

    def test_snap_time(self):
        self.assertEqual(zz.snap_time("zz_auto_1790626501"), 1790626501)
        self.assertEqual(zz.snap_time("block"), 0)
        self.assertEqual(zz.snap_time("zz_auto_x"), 0)


class BusyPattern(unittest.TestCase):
    """is_busy_local's matching, checked against sample process lines."""

    def matches(self, line, dataset):
        import re
        pattern = re.compile(r'(^|[\s/])zfs\s.*(send|recv|receive).*\s' + re.escape(dataset) + r'(@|\s|$)')
        return bool(pattern.search(line))

    def test_pattern_source_matches_code(self):
        import inspect
        self.assertIn(r"(^|[\s/])zfs\s.*(send|recv|receive).*\s", inspect.getsource(zz.is_busy_local))

    def test_lines(self):
        self.assertTrue(self.matches("zfs send -R -i @a tank/burp1@b", "tank/burp1"))
        self.assertTrue(self.matches("ssh host zfs recv -s -u tank/burp1", "tank/burp1"))
        self.assertTrue(self.matches("/usr/sbin/zfs send tank/burp1@x", "tank/burp1"))
        self.assertFalse(self.matches("zfs send tank/burp10@x", "tank/burp1"))
        self.assertFalse(self.matches("zfs send tank/burp1/child@x", "tank/burp1"))
        self.assertFalse(self.matches("zfs list tank/burp1", "tank/burp1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
