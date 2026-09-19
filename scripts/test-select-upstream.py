#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('select_upstream', Path(__file__).with_name('select-upstream.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SelectionTests(unittest.TestCase):
    def test_skipped_latest_and_ahead_of_channel(self):
        candidates = [('1.0.38', 'ahead'), ('1.0.32', 'new'), ('1.0.32', 'old'), ('1.0.13', 'older')]
        self.assertEqual(module.select(candidates, {'1.0.38', '1.0.34', '1.0.32', '1.0.13'}, '1.0.34'), ('1.0.32', 'new'))

    def test_unpublished_and_prerelease_are_excluded(self):
        candidates = [('1.0.34', 'unpublished'), ('1.0.34-beta.1', 'beta'), ('1.0.9', 'stable')]
        self.assertEqual(module.select(candidates, {'1.0.34-beta.1', '1.0.9'}, '1.0.34'), ('1.0.9', 'stable'))

    def test_no_match_fails(self):
        with self.assertRaises(ValueError):
            module.select([('1.0.38', 'ahead')], {'1.0.38'}, '1.0.34')


unittest.main()
