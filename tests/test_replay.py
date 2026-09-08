import json
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from diagnose import analyze
from replay_viewer import parse_session

class ReplayTests(unittest.TestCase):
    def test_schema_merge_zero_timing_and_disabled_commands(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'record.jsonl'
            rows = [{'ev': 'session_start', 'seed': 'x', 'build': {'sourceHash': 'abc'}},
                    {'frame': 10, 'tick': 1, 'room': 1, 'budgetMs': 0},
                    {'frame': 11, 'tick': 2, 'room': 1, 'budgetMs': 2, 'enabled': False, 'commandValid': True},
                    {'ev': 'context', 'eventId': 1, 'snapshot': {'frame': 10, 'tick': 1, 'room': 1, 'budgetMs': 0, 'plan': {'selected': 2}}}]
            path.write_text('\n'.join(map(json.dumps, rows))+'\n{bad', encoding='utf-8')
            _, frames, _, bad = parse_session(path)
            self.assertEqual(len(frames), 2)
            self.assertEqual(frames[0]['plan']['selected'], 2)
            self.assertEqual(bad, 1)
            report = analyze(path)
            self.assertEqual(report['decisionRecordedMeanMs'], 1)
            self.assertEqual(report['disabledCommandFrames'], [11])
            self.assertEqual(report['build']['sourceHash'], 'abc')

if __name__ == '__main__':
    unittest.main()
