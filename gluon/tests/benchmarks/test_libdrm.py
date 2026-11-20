import json
import pathlib
import tempfile
import unittest

import libdrm


class LibdrmTests(unittest.TestCase):
    def anchor(self):
        return {'commit': 'a' * 40, 'host': 'host', 'date': '2026-11-20', 'metrics': {p: {'value': 1.0, 'tolerance': 0.1} for p in libdrm.PHASES}}

    def test_anchor_parsing(self):
        scratch = libdrm.ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = pathlib.Path(directory) / 'anchor.json'
            data = self.anchor()
            path.write_text(json.dumps(data))
            self.assertEqual(libdrm.load_anchor(path), data)
            data['metrics']['noop']['value'] = -1
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                libdrm.load_anchor(path)

    def test_verdicts(self):
        values = dict.fromkeys(libdrm.PHASES, 1.0)
        anchor = self.anchor()
        self.assertEqual(libdrm.verdict(anchor, values, True, 'host')[0], 'within budget')
        values['build'] = 1.2
        self.assertEqual(libdrm.verdict(anchor, values, True, 'host')[0], 'regression')
        self.assertEqual(libdrm.verdict(anchor, values, False, 'host')[0], 'inconclusive')
        self.assertEqual(libdrm.verdict(None, values, True, 'host')[0], 'inconclusive')
        self.assertEqual(libdrm.verdict(anchor, values, True, 'other')[0], 'inconclusive')

    def test_oracle_rejects_missing_work_and_mismatches(self):
        good = {'counts': {'build': 7, 'noop': 0, 'incremental': 2}, 'outputs': ['a.o', 'libdrm.so.2.134.0']}
        libdrm.check_oracle(good, good)
        for bad in ({'counts': {'build': 7, 'noop': 1, 'incremental': 2}, 'outputs': good['outputs']}, {'counts': good['counts'], 'outputs': ['a.o']}, {'counts': {'build': 7, 'noop': 0, 'incremental': 0}, 'outputs': good['outputs']}):
            with self.assertRaises(ValueError):
                libdrm.check_oracle(good, bad)


if __name__ == '__main__':
    unittest.main()
