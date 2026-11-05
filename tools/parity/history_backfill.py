#!/usr/bin/env python3
"""Re-measure the code numbers (Linux functions, xe uAPI) at every repository commit that changed kernel/ and write
them to data/history.json (oldest first). CTS and video columns stay empty for these rows: those results are tied to
test runs, not to commits. Run once; tools/parity/build.sh appends the current state afterwards.

  python3 tools/parity/history_backfill.py --linux <linux tree> [--scratch <dir>]
"""
import argparse, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))


def git(*a):
    return subprocess.run(['git', '-C', ROOT] + list(a), check=True, capture_output=True, text=True).stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--linux', required=True)
    ap.add_argument('--scratch', default=None)
    ap.add_argument('--out', default=os.path.join(ROOT, 'data/history.json'))
    a = ap.parse_args()
    tmp = a.scratch or tempfile.mkdtemp(prefix='parity-history-')
    commits = git('log', '--reverse', '--format=%h\t%ci\t%s', '--', 'kernel').strip().splitlines()
    hist = []
    for line in commits:
        h, date, subj = line.split('\t')
        d = os.path.join(tmp, h)
        os.makedirs(d, exist_ok=True)
        tar = subprocess.run(['git', '-C', ROOT, 'archive', h, 'kernel'], check=True, capture_output=True).stdout
        subprocess.run(['tar', '-x', '-C', d], input=tar, check=True)
        kdir, fdir = os.path.join(d, 'kernel/IntelXe'), os.path.join(d, 'kernel/IntelXeFB')
        os.makedirs(kdir, exist_ok=True)
        os.makedirs(fdir, exist_ok=True)
        pj, uj = os.path.join(d, 'parity.json'), os.path.join(d, 'uapi.json')
        subprocess.run([sys.executable, os.path.join(HERE, 'scan.py'), '--linux', a.linux, '--kernel', kdir, '--fb', fdir,
                        '--out', pj], check=True, capture_output=True)
        subprocess.run([sys.executable, os.path.join(HERE, 'uapi.py'), '--linux', a.linux, '--kernel', kdir, '--fb', fdir,
                        '--out', uj], check=True, capture_output=True)
        k = json.load(open(pj))['summary']['kernel']
        u = json.load(open(uj))['summary']
        m = re.match(r'kernel/IntelXe(?:FB)?: ([^,(]+)', subj)
        m2 = re.match(r'Add the (\S+)', subj)
        label = ('FB ' if 'IntelXeFB:' in subj else '') + (m.group(1).strip() if m else (m2.group(1) if m2 else subj[:24]))
        hist.append({'date': date[:16], 'commit': h, 'dirty': False, 'label': label[:28],
                     'kernel_commit': None, 'fb_commit': None, 'linux_rev': json.load(open(pj))['meta']['linux']['rev'],
                     'functions_matched': k['functions_matched'], 'functions_total': k['functions_total'],
                     'functions_pct': k['pct_functions_matched'], 'uapi_implemented': u['implemented'],
                     'uapi_total': u['cells'], 'uapi_pct': u['pct_implemented'], 'cts_run': None, 'cts_cases': None,
                     'cts_pass': None, 'cts_pass_pct': None, 'video_decode_exact': None, 'video_decode_clips': None,
                     'source': 'backfill: re-measured from commit %s' % h})
        print(h, date[:16], label, k['pct_functions_matched'], u['pct_implemented'])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(hist, open(a.out, 'w'), indent=1)


if __name__ == '__main__':
    main()
