#!/usr/bin/env python3
"""Video matrix from the mediakit macOS results (exact numbers only).

Reads <mediakit>/out_mac/results_mac.txt (written by mediakit's mac/run_mac.sh) and, when present,
<mediakit>/out_win/results_win.txt, and writes data/video.json: one cell per codec x direction x bit depth x resolution.

Decode cell: every clip of that combination decoded through VideoToolbox ("vt" rows) with per-frame md5 against the
software reference; fps per clip. Encode cell: VideoToolbox encode speed (encspeed rows, preset veryfast/medium/veryslow)
and the bitrate deviation of every VBR quality encode = bytes*8 / (frames/60) / target - 1, with frames as run_mac.sh
uses them (1080p60: 600, 2160p60: 300).
Grade against the B580 target (docs/devices/b580.md): decode must be bit-exact and >= Windows speed; encode BD-rate <= 0 vs QSV and
overshoot <= 5%. Without Windows numbers a cell that passes the macOS-only checks is "pending" (yellow).
Combinations Intel's own driver does not offer on Xe2 (data/caps.json from tools/parity/caps.py, with the media-driver
caps table that says so) are "unsupported" instead of "untested". Each measured item names the stack it was measured with (the run header line).
"""
import argparse, collections, json, math, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CODECS = ['h264', 'hevc', 'av1', 'vp9']
RES = {'1080p': '1080p', '2160p': '2160p', '4320p': '4320p'}
FRAMES = {'1080p60': 600, '2160p60': 300, '4320p60': 120}

# What Intel's own driver does not offer on the B580 comes from data/caps.json (tools/parity/caps.py: media-driver's Xe2
# capability tables for Battlemage): a combination it does not offer (no entrypoint, no such bit depth, or beyond its
# largest picture) is graded "unsupported", with the table that says so.
CAPS_PLATFORM = 'bmg'
DIMS = {'1080p': (1920, 1080), '2160p': (3840, 2160), '4320p': (7680, 4320)}


def unsupported_set(caps_path):
    """{(codec, dir, bits, res): reason} for every matrix cell Intel's driver does not offer on CAPS_PLATFORM."""
    import sys
    sys.dont_write_bytecode = True
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from caps import supports
    caps = json.load(open(caps_path))
    out = {}
    for codec in CODECS:
        for d in ('decode', 'encode'):
            for bits in (8, 10):
                for res, (w, h) in DIMS.items():
                    ok, why = supports(caps, CAPS_PLATFORM, codec, d, bits, w, h)
                    if ok is False:
                        out[(codec, d, bits, res)] = why
    return out, caps['meta']


def kv(p, k):
    return p[p.index(k) + 1] if k in p else None


def load(path, headers=None):
    """Result rows as token lists; with headers=[], also the run header line each row came after."""
    rows = []
    if os.path.exists(path):
        raw = open(path, 'rb').read()   # PowerShell writes UTF-16 with CRLF and "1,132.1" thousands separators
        txt = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8', 'replace')
        hdr = ''
        for line in txt.replace('\r', '').split('\n'):
            if line.startswith('# mediakit'):
                hdr = line.strip()
            p = [w.replace(',', '') if w[:1].isdigit() else w for w in line.split()]
            if p and not p[0].startswith('#'):
                rows.append(p)
                if headers is not None:
                    headers.append(hdr)
    return rows


def stack_of(hdr):
    """The stack a run measured: 'installed <hashes>' plus the environment it put in front (another stack)."""
    m = re.search(r'installed: ([0-9a-f ]+?)\s*(?:env: (.*?))?\s*(?:test: (.*))?$', hdr)
    if not m:
        return 'installed stack'
    if not m.group(2):
        return 'installed stack %s' % m.group(1).strip()
    lib = re.search(r'DYLD_LIBRARY_PATH=(\S+)', m.group(2))
    where = re.sub(r'^/Users/[^/]+', '~', lib.group(1)) if lib else m.group(2)
    return 'test stack %s%s over installed %s' % (where, ' (%s)' % m.group(3) if m.group(3) else '', m.group(1).strip())



def _polyfit(x, y, deg):   # least squares, as mediakit score/score.py
    n = deg + 1
    A = [[sum(xi ** (i + j) for xi in x) for j in range(n)] for i in range(n)]
    b = [sum((xi ** i) * yi for xi, yi in zip(x, y)) for i in range(n)]
    for c in range(n):
        q = max(range(c, n), key=lambda r: abs(A[r][c])); A[c], A[q] = A[q], A[c]; b[c], b[q] = b[q], b[c]
        for r in range(n):
            if r != c and A[c][c]:
                f = A[r][c] / A[c][c]; A[r] = [x1 - f * x2 for x1, x2 in zip(A[r], A[c])]; b[r] -= f * b[c]
    return [b[i] / A[i][i] for i in range(n)]


def bd_rate(r1, q1, r2, q2):
    """Bjontegaard rate difference of (r2, q2) against (r1, q1) in %, cubic (or quadratic) fit of log rate over quality."""
    if len(r1) < 3 or len(r2) < 3:
        return None
    deg = 3 if len(r1) > 3 and len(r2) > 3 else 2
    p1 = _polyfit(q1, [math.log(r) for r in r1], deg); p2 = _polyfit(q2, [math.log(r) for r in r2], deg)
    lo, hi = max(min(q1), min(q2)), min(max(q1), max(q2))
    if hi <= lo:
        return None
    integ = lambda p: sum(c / (i + 1) * (hi ** (i + 1) - lo ** (i + 1)) for i, c in enumerate(p))
    return (math.exp((integ(p2) - integ(p1)) / (hi - lo)) - 1) * 100


def load_metrics(mediakit):
    """score/metrics_{mac,win}.txt -> {(row, content, codec, res, bits): [(kbps, psnr_y, vmaf)]}"""
    m = {}
    for f in ('score/metrics_mac.txt', 'score/metrics_win.txt'):
        path = os.path.join(mediakit, f)
        if not os.path.exists(path):
            continue
        for line in open(path):
            p = line.split()
            mm = re.match(r'(\w+)-(\w+)_(\w+)_(\d+p\d+)_(\d+)_vbr\d+$', p[0]) if len(p) >= 8 and p[4] != '-' else None
            if mm:
                m.setdefault(mm.groups(), []).append((float(p[2]), float(p[4]), float(p[7])))
    return {k: sorted(v) for k, v in m.items()}

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mediakit', required=True)
    ap.add_argument('--out', default=os.path.join(ROOT, 'data/video.json'))
    ap.add_argument('--caps', default=os.path.join(ROOT, 'data/caps.json'))
    a = ap.parse_args()
    UNSUPPORTED, caps_meta = unsupported_set(a.caps)
    mac_p = os.path.join(a.mediakit, 'out_mac/results_mac.txt')
    mac_hdr = []
    win_hdr = []
    mac, win = load(mac_p, mac_hdr), load(os.path.join(a.mediakit, 'out_win/results_win.txt'), win_hdr)
    # The Windows GPU of each row: run_win.ps1 pins the Arc B580 since 2 Nov and names it in the run header
    # ('adapter=N 8086:e20b "..."'); rows of an older run came from whichever adapter ffmpeg/oneVPL picked (the
    # UHD 770 iGPU is an Intel adapter too), so a comparison with them is marked unpinned.
    win_pinned = [bool(re.search(r'adapter=\d+ 8086:e2[0-2][0-9a-f] ', h)) for h in win_hdr]
    met = load_metrics(a.mediakit)
    runs = [re.sub(r'/Users/[^/\s]+', '~', l.strip()) for l in open(mac_p) if l.startswith('# mediakit')]   # no home paths in the repo
    cells = {}

    def cell(codec, d, bits, res):
        return cells.setdefault((codec, d, bits, res), {'codec': codec, 'dir': d, 'bits': bits, 'res': res, 'items': []})

    for p, hdr in zip(mac, mac_hdr):   # dec <path> <clip> frames N fps F cpu% C md5frames a/b mismatches M
        if p[0] != 'dec' or p[1] != 'vt':
            continue
        m = re.match(r'dec_(h264|hevc|av1|vp9)(8|10)?_?(?:(8|10)_)?(\d+p)(\d+)', p[2])
        if not m:
            continue
        codec = m.group(1)
        bits = int(m.group(2) or m.group(3) or 8)
        c = cell(codec, 'decode', bits, m.group(4))
        ok, tot = kv(p, 'md5frames').split('/')
        c['items'] = [i for i in c['items'] if i['clip'] != p[2]]   # a rerun appends rows: the last one counts
        c['items'].append({'clip': p[2], 'fps': float(kv(p, 'fps')), 'cpu': kv(p, 'cpu%'), 'md5': '%s/%s' % (ok, tot),
                           'exact': ok == tot and int(tot) > 0 and kv(p, 'mismatches') == '0', 'stack': stack_of(hdr)})
    for p in mac:   # encspeed <codec> <res> <preset> frames N fps F
        if p[0] == 'encspeed':
            c = cell(p[1], 'encode', 8, p[2][:-2])
            c.setdefault('speed', {})[p[3]] = float(kv(p, 'fps'))
    for p, hdr in zip(mac, mac_hdr):   # enc vt-<content>_<codec>_<res>_<bits>_vbr<M>.<ext> bytes B fps F
        if p[0] != 'enc' or not p[1].startswith('vt-'):
            continue
        m = re.match(r'vt-(\w+?)_(h264|hevc|av1)_(\d+p\d+)_(8|10)_vbr(\d+)\.', p[1])
        if not m:
            continue
        content, codec, res, bits, mbit = m.group(1), m.group(2), m.group(3), int(m.group(4)), int(m.group(5))
        kbps = int(kv(p, 'bytes')) * 8 / (FRAMES[res] / 60.0) / 1000
        c = cell(codec, 'encode', bits, res[:-2])
        c['items'] = [i for i in c['items'] if i['stream'] != p[1]]   # a rerun appends rows: the last one counts
        if int(kv(p, 'bytes')) > 0:   # a stream at this target supersedes an earlier failure at it (e.g. a renamed set)
            c['items'] = [i for i in c['items'] if not (i.get('failed') and i['target_kbps'] == mbit * 1000)]
        if int(kv(p, 'bytes')) == 0:   # the encoder produced nothing (session refused or failed)
            c['items'].append({'stream': p[1], 'content': content, 'target_kbps': mbit * 1000, 'failed': True,
                               'stack': stack_of(hdr)})
            continue
        c['items'].append({'stream': p[1], 'content': content, 'target_kbps': mbit * 1000, 'kbps': round(kbps),
                           'deviation_pct': round(100 * (kbps / (mbit * 1000) - 1), 1), 'fps': float(kv(p, 'fps')),
                           'stack': stack_of(hdr)})
    out = []
    for codec in CODECS:
        for d in ('decode', 'encode'):
            for bits in (8, 10):
                for res in ('1080p', '2160p', '4320p'):
                    c = cells.get((codec, d, bits, res))
                    if (codec, d, bits, res) in UNSUPPORTED:
                        out.append({'codec': codec, 'dir': d, 'bits': bits, 'res': res, 'grade': 'unsupported',
                                    'note': UNSUPPORTED[(codec, d, bits, res)]})
                        continue
                    if not c or (not c['items'] and not c.get('speed')):
                        out.append({'codec': codec, 'dir': d, 'bits': bits, 'res': res, 'grade': 'untested',
                                    'note': 'not in the mediakit run'})
                        continue
                    if d == 'decode':
                        exact = all(i['exact'] for i in c['items'])
                        # Windows reference: its fastest hardware path per clip (d3d11va or qsv), last row per clip
                        wfps, wpin = {}, {}
                        for q, pin in zip(win, win_pinned):
                            if q[0] == 'dec' and kv(q, 'fps'):
                                wfps[(q[1], q[2])] = float(kv(q, 'fps'))
                                wpin[(q[1], q[2])] = pin
                        ref = {i['clip']: max([v for (path, clip), v in wfps.items() if clip == i['clip']] or [0])
                               for i in c['items']}
                        measured = all(ref[i['clip']] > 0 for i in c['items'])
                        fast = measured and all(i['fps'] >= ref[i['clip']] for i in c['items'])
                        pinned = measured and all(wpin.get((path, clip)) for (path, clip), v in wfps.items()
                                                  if clip in ref and v == ref[clip])
                        if measured:
                            c['windows_gpu_pinned'] = pinned
                        c['grade'] = 'fail' if not exact else ('pass' if fast else ('fail' if measured else 'pending'))
                        stacks = sorted(set(i['stack'] for i in c['items']))
                        c['note'] = ('bit-exact, ' if exact else 'NOT bit-exact / failed, ') + \
                            ', '.join('%s %s fps (md5 %s)' % (i['clip'], i['fps'], i['md5']) +
                                      (' vs Windows %.1f fps' % ref[i['clip']] if ref[i['clip']] else '')
                                      for i in c['items']) + \
                            ('' if not exact else '; Windows speed not measured yet' if not measured else
                             '; >= Windows' if fast else '; slower than Windows') + \
                            ('' if not measured or pinned else ' (Windows run did not pin the adapter: B580 not verified)') + \
                            '; measured with the ' + ' / '.join(stacks)
                    else:
                        failed = [i['stream'] for i in c['items'] if i.get('failed')]
                        devs = [i['deviation_pct'] for i in c['items'] if not i.get('failed')]
                        over = max(devs) if devs else None
                        c['max_overshoot_pct'] = over
                        sp = c.get('speed', {})
                        bits_txt = []
                        if sp:
                            bits_txt.append('speed ' + ' / '.join('%s %s fps' % (k, v) for k, v in sorted(sp.items())))
                        if devs:
                            bits_txt.append('VBR bitrate deviation %+.1f%% .. %+.1f%% over %d streams' % (min(devs), over, len(devs)))
                        # BD-rate (PSNR-Y / VMAF) of our VideoToolbox row against Intel QSV at the same settings (qsvT4)
                        bds = []
                        for (row, content, mc, mres, mbits), pts in sorted(met.items()):
                            if row != 'vt' or mc != codec or int(mbits) != bits or mres[:-2] != res:
                                continue
                            q = met.get(('qsvT4', content, mc, mres, mbits))
                            if q:
                                bp = bd_rate([x[0] for x in q], [x[1] for x in q], [x[0] for x in pts], [x[1] for x in pts])
                                bv = bd_rate([x[0] for x in q], [x[2] for x in q], [x[0] for x in pts], [x[2] for x in pts])
                                if bp is not None:
                                    bds.append((content, bp, bv))
                        if bds:
                            c['bd_rate_vs_qsv'] = [{'content': k, 'psnr_pct': round(bp, 1), 'vmaf_pct': None if bv is None else round(bv, 1)}
                                                   for k, bp, bv in bds]
                            bits_txt.append('BD-rate vs QSV same settings (PSNR-Y/VMAF) ' + ', '.join(
                                '%s %+.1f%%/%s' % (k, bp, '-' if bv is None else '%+.1f%%' % bv) for k, bp, bv in bds))
                        worse = any(bp > 0 for k, bp, bv in bds)
                        if failed:
                            c['grade'] = 'fail'
                            c['failed_streams'] = failed
                            bits_txt.append('encode FAILED (no stream) for %s' % ', '.join(failed))
                        if over is not None and over > 5:
                            c['grade'] = 'fail'
                            bits_txt.append('overshoot > 5%')
                        if bds and worse:
                            c['grade'] = 'fail'
                            bits_txt.append('more bits than QSV for the same PSNR')
                        elif bds and c.get('grade') != 'fail':
                            c['grade'] = 'pass'
                        elif not bds and c.get('grade') != 'fail':
                            c['grade'] = 'pending'
                            bits_txt.append('BD-rate vs QSV not measured yet' + ('' if devs else '; no bitrate data'))
                        stacks = sorted(set(i['stack'] for i in c['items'] if i.get('stack')))
                        if stacks:
                            bits_txt.append('measured with the ' + ' / '.join(stacks))
                        c['note'] = '; '.join(bits_txt)
                    out.append(c)
    data = {'meta': {'source': os.path.relpath(mac_p, a.mediakit), 'mediakit': os.path.basename(os.path.normpath(a.mediakit)), 'runs': runs,
                     'windows': bool(win), 'frames': FRAMES,
                     'windows_runs': sorted({h + ('' if 'adapter=' in h else ' (adapter not pinned: GPU unverified)') for h in win_hdr if h}),
                     'unsupported_from': 'data/caps.json (%s, media-driver %s %s)' % (CAPS_PLATFORM, caps_meta['commit'][:12], caps_meta['date'])},
            'summary': {'decode_clips': sum(len(c['items']) for c in out if c['dir'] == 'decode' and c.get('items')),
                        'decode_exact': sum(1 for c in out if c['dir'] == 'decode' and c.get('items') for i in c['items'] if i['exact']),
                        'grades': dict(collections.Counter(c['grade'] for c in out))},
            'cells': out}
    json.dump(data, open(a.out, 'w'), indent=1)
    print('video: decode %d/%d clips bit-exact; grades %s' % (data['summary']['decode_exact'], data['summary']['decode_clips'],
                                                               data['summary']['grades']))


if __name__ == '__main__':
    main()
