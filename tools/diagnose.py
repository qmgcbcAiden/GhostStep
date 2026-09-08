"""诊断 schema 1/2 JSONL。推断标签不等于伤害因果或反事实通关率。"""
import argparse
import json
import math
from collections import Counter
from pathlib import Path
from statistics import mean
from replay_viewer import parse_session


def analyze(path):
    seed, frames, events, bad = parse_session(path)
    values = [f['budgetMs'] for f in frames if isinstance(f.get('budgetMs'), (int, float))]
    complete_times = {f['perfPrevious']['tick']: f['perfPrevious']['totalMs']
                      for f in frames if isinstance(f.get('perfPrevious'), dict)
                      and isinstance(f['perfPrevious'].get('totalMs'), (int, float))}
    conflicts = [f['frame'] for f in frames if f.get('enabled') is False and f.get('commandValid') is True]
    gaps = []
    for a, b in zip(frames, frames[1:]):
        if b['frame']-a['frame'] > 1:
            gaps.append({'after': a['frame'], 'before': b['frame'], 'engineFrames': b['frame']-a['frame']-1})
    stuck, run = [], []
    for f in frames:
        active = f.get('active', (f.get('weight') or 0) > 0)
        previous = run[-1] if run else None
        consecutive = previous is None or (f['frame'] == previous['frame']+1 and f.get('room') == previous.get('room'))
        stationary = previous is None or math.hypot(f.get('px', 0)-previous.get('px', 0), f.get('py', 0)-previous.get('py', 0)) < .3
        if active and consecutive and stationary:
            run.append(f)
        else:
            if len(run) >= 6:
                stuck.append({'start': run[0]['frame'], 'end': run[-1]['frame'], 'samples': len(run), 'label': 'low_progress_suspect'})
            run = [f] if active else []
    if len(run) >= 6:
        stuck.append({'start': run[0]['frame'], 'end': run[-1]['frame'], 'samples': len(run), 'label': 'low_progress_suspect'})
    build = next((e.get('build') for e in events if e.get('ev') == 'session_start'), None)
    return {'file': str(path), 'seed': seed, 'build': build, 'snapshots': len(frames), 'malformedLines': bad,
            'decisionRecordedMeanMs': mean(values) if values else None,
            'completeUpdateRecordedMeanMs': mean(complete_times.values()) if complete_times else None,
            'completeUpdateSamples': len(complete_times),
            'events': dict(Counter(e['ev'] for e in events)),
            'reasons': dict(Counter(f['reason'] for f in frames if f.get('reason'))),
            'disabledCommandFrames': conflicts, 'lowProgressEpisodes': stuck, 'frameGaps': gaps,
            'detailSnapshots': sum(bool(f.get('hazards') or f.get('plan')) for f in frames),
            'coverageLimitedSnapshots': sum(bool(f.get('metrics') and not f['metrics'].get('coverageComplete', True)) for f in frames),
            'notes': ['Zero duration is included; missing timing is excluded.',
                      'Engine frame gaps are not converted to wall-clock duration.',
                      'Low progress can also be intentional braking; inspect command and feedback.',
                      'Damage callbacks precede damage resolution; hp_decrease is recorded separately.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = analyze(args.session)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(text+'\n', encoding='utf-8')
        print(f'诊断报告: {args.output}')
    else:
        print(text)

if __name__ == '__main__':
    main()
