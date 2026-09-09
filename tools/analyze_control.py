"""Stream a schema-2 replay into aggregate control/timing diagnostics (no raw positions exported)."""
import argparse
import collections
import json
import math
from pathlib import Path


def analyze(path):
    counts = collections.Counter()
    reasons = collections.Counter()
    amplitudes = collections.Counter()
    cadence = collections.Counter()
    previous = None
    max_evaluated = 0
    for line in Path(path).open(encoding='utf-8-sig'):
        if not line.strip():
            continue
        row = json.loads(line)
        if 'metrics' not in row or 'px' not in row:
            continue
        counts['decisions'] += 1
        reasons[row.get('reason', 'unknown')] += 1
        max_evaluated = max(max_evaluated, row['metrics'].get('evaluated', 0))
        if row.get('active'):
            counts['active'] += 1
            amplitudes[f"{math.hypot(row.get('cx', 0), row.get('cy', 0)):.2f}"] += 1
        feedback = row.get('feedback', {})
        if previous and feedback.get('decisionId') == previous.get('decisionId'):
            cadence[str(feedback.get('dt'))] += 1
            if previous.get('active'):
                counts['active_hook_seen' if feedback.get('hookSeen') else 'active_hook_missing'] += 1
        if (previous and row['frame'] == previous['frame'] + 1
                and row.get('room') == previous.get('room')
                and math.hypot(previous.get('vx', 0), previous.get('vy', 0)) > 0.2):
            counts['moving_pairs'] += 1
            error = math.hypot(row['px'] - previous['px'] - previous['vx'],
                               row['py'] - previous['py'] - previous['vy'])
            if error < 0.01:
                counts['position_matches_previous_velocity'] += 1
        previous = row
    return dict(counts=counts, reasons=reasons, active_amplitudes=amplitudes,
                feedback_cadence=cadence, max_evaluated=max_evaluated)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('replay', type=Path)
    print(json.dumps(analyze(parser.parse_args().replay), ensure_ascii=False, indent=2))
