#!/usr/bin/env python3
"""One work list from every parity source, ordered by the target (docs/devices/b580.md): docs/parity/NEXT.md.

Sources, each item keeps its evidence:
  docs/devices/b580.md (Turkish tables)   rows marked 🟥 (tested, below the target); ⬜ rows are listed as "not tested yet"
  data/video.json (video.py)        cells graded 'fail' (decode slower than Windows / not bit-exact, encode BD-rate or
                                    overshoot against Intel QSV)
  data/cts/runs.json + <run>.tsv.gz the newest CTS run: Fail / Crash / Timeout cases, and NotSupported counts per group
  data/uapi.json (consumers.py)     needed_now items (red); needed_future items (orange) only as counts per feature
Nothing is estimated: an item appears only because one of these files says so.

  python3 tools/parity/next.py
"""
import collections, gzip, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGETS = {1: 'Ekran / Display', 2: '3B / 3D', 3: 'Video', 4: 'Kararlılık / Stability'}


def parity_rows():
    """(target, section, item, status, vs_target, source) for the 🟥 and ⬜ rows of the Turkish tables of docs/devices/b580.md."""
    text = open(os.path.join(ROOT, 'docs/devices/b580.md')).read().split('\n## English')[0]
    rows, section, target = [], '', None
    for line in text.split('\n'):
        m = re.match(r'### (\d+)\. (.+)', line)
        if m:
            section = m.group(2)
            t = re.search(r'hedef (\d)', section)
            target = int(t.group(1)) if t else None
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')] if line.startswith('|') else []
        # the 4-column evidence tables: item | macOS | vs target | source (the video codec matrix is read from video.json)
        if len(cells) == 4 and cells[1] in ('🟥', '⬜') and target:
            rows.append((target, section, cells[0], cells[1], cells[2], cells[3]))
    return rows


def video_fails():
    v = json.load(open(os.path.join(ROOT, 'data/video.json')))
    return [c for c in v['cells'] if c['grade'] == 'fail']


def cts_newest():
    runs = json.load(open(os.path.join(ROOT, 'data/cts/runs.json')))
    run = runs[-1]
    bad, ns = [], collections.Counter()
    p = os.path.join(ROOT, 'data/cts/%s.tsv.gz' % run['id'])
    if os.path.exists(p):
        for line in gzip.open(p, 'rt'):
            f = line.rstrip('\n').split('\t')
            if len(f) < 2:
                continue
            case, st = f[0], f[1]
            if st in ('Fail', 'Crash', 'Timeout', 'InternalError', 'ResourceError'):
                bad.append((case, st))
            elif st == 'NotSupported':
                ns['.'.join(case.split('.')[:2])] += 1
    return run, bad, ns


def main():
    u = json.load(open(os.path.join(ROOT, 'data/uapi.json')))
    red = [c for c in u['cells'] if c.get('need') == 'needed_now']
    orange = collections.Counter()
    for c in u['cells']:
        if c.get('need') == 'needed_future':
            for f in sorted({x['feature'] for x in c['consumers'] if x['kind'] == 'future'}):
                orange[f] += 1
    rows = parity_rows()
    vf = video_fails()
    run, bad, ns = cts_newest()

    L = ['# Sıradaki işler / Next work', '',
         'Üretildi / generated: `tools/parity/next.py` (`tools/parity/build.sh`). Kaynaklar / sources: `docs/devices/b580.md`, '
         '`data/video.json`, `data/cts/runs.json` (newest run), `data/uapi.json`. Her satır kanıtını taşır; tahmin yok. '
         'Sıra hedefe göre (docs/devices/b580.md): 1 ekran, 2 3B, 3 video, 4 kararlılık; sonra çekirdek arayüzü ve gelecek hedefler.', '',
         'Every line carries its evidence; nothing is estimated. Ordered by the target in docs/devices/b580.md.', '']
    n = 0
    for t in sorted(TARGETS):
        items = [r for r in rows if r[0] == t and r[3] == '🟥']
        untested = [r for r in rows if r[0] == t and r[3] == '⬜']
        vids = vf if t == 3 else []
        ctsb = bad if t == 2 else []
        if not (items or untested or vids or ctsb):
            continue
        L += ['## %d. %s' % (t, TARGETS[t]), '']
        if items or vids or ctsb:
            L += ['| # | İş / item | Durum / status | Kanıt / evidence |', '|---|---|---|---|']
            for r in items:
                n += 1
                L.append('| %d | %s | %s | %s |' % (n, r[2], r[4], r[5]))
            for c in vids:
                n += 1
                name = '%s %s %d-bit %s' % ({'h264': 'H.264', 'hevc': 'HEVC', 'av1': 'AV1', 'vp9': 'VP9'}[c['codec']],
                                           {'decode': 'çözme / decode', 'encode': 'kodlama / encode'}[c['dir']], c['bits'], c['res'])
                L.append('| %d | %s | hedefin altında / below target | %s (`data/video.json`) |' % (n, name, c['note'].replace('|', '/')))
            for case, st in ctsb:
                n += 1
                L.append('| %d | CTS `%s` | %s | koşu / run %s |' % (n, case, st, run['id']))
            L.append('')
        if untested:
            L += ['Test edilmedi / not tested yet: ' + '; '.join(r[2] for r in untested) + '.', '']
    L += ['## 5. Çekirdek arayüzü / Kernel interface (xe uAPI)', '',
          'Bugün çalışan yazılımın kullandığı, çekirdeğimizde olmayan ögeler (ayrıntı ve tüketici satırları: [TODO.md](TODO.md)):', '']
    if red:
        L += ['| # | Öge / item | Neden / why |', '|---|---|---|']
        for c in red:
            n += 1
            L.append('| %d | `%s` | %s |' % (n, c['token'], c.get('need_why', '').replace('|', '/')))
    else:
        L.append('Yok / none.')
    L += ['', '## 6. Desteklenmeyen Vulkan özellikleri / Vulkan features reported as not supported', '',
          'CTS koşusu / run %s: grup başına NotSupported sayısı (bir özelliğin eksik olduğunu gösterir, hata değildir).' % run['id'], '',
          '| Grup / group | NotSupported |', '|---|---|']
    for g, k in ns.most_common(15):
        L.append('| `%s` | %d |' % (g, k))
    L += ['', '## 7. Gelecek hedefler / Future targets (xe uAPI, turuncu / orange)', '',
          '| Özellik / feature | Öge sayısı / items |', '|---|---|']
    for f, k in orange.most_common():
        L.append('| %s | %d |' % (f, k))
    open(os.path.join(ROOT, 'docs/parity/NEXT.md'), 'w').write('\n'.join(L) + '\n')
    print('next: %d items by target, CTS run %s (%d bad), uAPI red %d' % (n, run['id'], len(bad), len(red)))


if __name__ == '__main__':
    main()
