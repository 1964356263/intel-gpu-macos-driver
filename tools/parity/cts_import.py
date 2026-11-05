#!/usr/bin/env python3
"""Import one Vulkan CTS run (deqp-vk shards written by user/tests' run.sh on the hackintosh) into the repository.

Reads <results>/<group>/*.qpa (+ events.txt CRASH/TIMEOUT lines, run.log) exactly like the run's own
parse_results.py, and writes data/cts/<run-id>.tsv.gz (case, status, shard group) plus an entry in data/cts/runs.json
with the date and driver stack you give (--date, --stack). Only cases that actually ran are recorded; shard groups the
runner stopped early are listed as partial.

  python3 tools/parity/cts_import.py --results <dir> --run-id 2026-10-29-g1-g7 --date "2026-10-29 21:03-21:15" \
      --stack "kernel sv7 c3372d3b, Mesa wsi 44c36957 (internal shaders stub)" --source "<where the files came from>"
"""
import argparse, collections, glob, gzip, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def parse_qpa(path):
    out, cur, buf = {}, None, []
    with open(path, errors='replace') as f:
        for line in f:
            if line.startswith('#beginTestCaseResult'):
                cur, buf = line.split()[1], []
            elif line.startswith('#endTestCaseResult') and cur:
                m = re.search(r'StatusCode="([A-Za-z]+)"', ''.join(buf))
                out[cur] = m.group(1) if m else 'Other'
                cur = None
            elif line.startswith('#terminateTestCaseResult') and cur:
                out[cur] = 'Timeout' if 'Timeout' in line else 'Crash'
                cur = None
            elif cur:
                buf.append(line)
    if cur:
        out[cur] = 'Crash'   # process died inside the case
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--results', required=True)
    ap.add_argument('--run-id', required=True)
    ap.add_argument('--date', required=True)
    ap.add_argument('--stack', required=True)
    ap.add_argument('--source', default='')
    ap.add_argument('--note', default='')
    ap.add_argument('--out-dir', default=os.path.join(ROOT, 'data/cts'))
    a = ap.parse_args()
    rows, partial, per = [], [], {}
    log = open(os.path.join(a.results, 'run.log')).read() if os.path.exists(os.path.join(a.results, 'run.log')) else ''
    # <group>.runN directories hold earlier attempts of a group the runner was restarted on: they are read first and
    # the later attempt (<group>) overrides each case it ran again
    dirs = [d for d in glob.glob(os.path.join(a.results, '[gp]*')) if os.path.isdir(d)]
    dirs.sort(key=lambda d: (os.path.basename(d).split('.')[0], 0 if '.run' in os.path.basename(d) else 1, d))
    merged = {}
    for gdir in dirs:
        g = os.path.basename(gdir).split('.')[0]
        res = merged.setdefault(g, {})
        key = lambda p: (os.path.basename(p).split('.')[0], int(re.search(r'\.a(\d+)\.qpa', p).group(1)))
        for q in sorted(glob.glob(os.path.join(gdir, '*.qpa')), key=key):
            res.update(parse_qpa(q))
        ev = os.path.join(gdir, 'events.txt')
        if os.path.exists(ev):
            for l in open(ev):
                p = l.split()
                if len(p) > 1 and p[0] == 'TIMEOUT' and p[1] in res:
                    res[p[1]] = 'Timeout'
                if len(p) > 2 and p[0] == 'CRASH':
                    res[p[2]] = 'Crash'
        if re.search(r'GROUP %s: .*group stopped|STOP RUN after \w+ in %s/' % (g, g), log) and g not in partial:
            partial.append(g)
    for g, res in merged.items():
        per[g] = dict(collections.Counter(res.values()))
        rows += [(c, s, g) for c, s in sorted(res.items())]
    os.makedirs(a.out_dir, exist_ok=True)
    with gzip.open(os.path.join(a.out_dir, a.run_id + '.tsv.gz'), 'wt') as f:
        f.write('case\tstatus\tshard_group\n')
        for r in rows:
            f.write('\t'.join(r) + '\n')
    runs_p = os.path.join(a.out_dir, 'runs.json')
    runs = json.load(open(runs_p)) if os.path.exists(runs_p) else []
    runs = [r for r in runs if r['id'] != a.run_id]
    runs.append({'id': a.run_id, 'date': a.date, 'stack': a.stack, 'source': a.source, 'note': a.note, 'cases': len(rows),
                 'status': dict(collections.Counter(s for _, s, _ in rows)), 'shard_groups': per,
                 'partial_groups': partial})
    json.dump(runs, open(runs_p, 'w'), indent=1)
    print('%s: %d cases %s; partial groups: %s' % (a.run_id, len(rows), runs[-1]['status'], ', '.join(partial) or 'none'))


if __name__ == '__main__':
    main()
