#!/usr/bin/env python3
"""Classify every xe uAPI item by NEED, with evidence from the user-space that consumes it.

Reads data/uapi.json (uapi.py) and searches the consumers' real sources for each token name:
  now     Mesa as we run it on macOS: src/intel/vulkan (ANV), src/intel/common, src/intel/dev (not src/intel/perf);
          our Metal plugin and VideoToolbox code in this repository. xemac (user/xemac) is NOT a consumer: it is the
          transport that forwards ioctls to IntelXe.kext (and its software "fake" device answers some itself), so a token
          in xemac says nothing about what user space needs
  future  iris (src/gallium/drivers/iris: native OpenGL), Mesa src/intel/perf (GPU profiler: OA metrics,
          VK_KHR_performance_query), Intel compute-runtime/NEO shared/source/os_interface/linux (OpenCL / oneAPI)
Overlay ("need") per item, only where our kernel does not implement it (implemented / accepted stay as they are):
  needed_now      a "now" consumer uses it                                   -> red
  needed_future   only "future" consumers use it (feature named)             -> orange
  not_needed      Linux-only concept (PXP content protection, RAS netlink), or no consumer found anywhere -> black
Every item stores consumer file:line hits (first 3 per consumer), or the list of trees searched with their commits.
Also writes docs/parity/TODO.md (red items first, then orange grouped by feature).

  python3 tools/parity/consumers.py --mesa <mesa tree> --neo <compute-runtime tree> --linux <linux tree>
"""
import argparse, json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXT = ('.c', '.h', '.cpp', '.hpp', '.m', '.mm', '.inl')
LINUX_ONLY = [(r'PXP', 'PXP protected content (Linux/Windows DRM content protection; no macOS path)'),
              (r'_RAS_', 'RAS error reporting over Linux netlink (drm_ras), not an ioctl a macOS client calls')]
# Items Linux itself never reports on this hardware (Xe2, graphics 20), with the Linux source that decides it.
NOT_ON_XE2 = [(r'^DRM_XE_TOPO_EU_PER_DSS$', 'not reported on Xe2 by Linux either: load_eu_mask() picks XE_GT_EU_TYPE_SIMD16 '
               'for graphics >= 20 (xe_gt_topology.c) and xe_query.c then reports DRM_XE_TOPO_SIMD16_EU_PER_DSS, which we '
               'report; Mesa (intel/dev/xe/intel_device_info.c) handles both')]


def git_head(path):
    try:
        top = subprocess.run(['git', '-C', path, 'rev-parse', '--show-toplevel'], capture_output=True, text=True, check=True).stdout.strip()
        h = subprocess.run(['git', '-C', top, 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
        return h
    except Exception:
        return 'no git'


def files_under(base, exclude=()):
    for root, dirs, fs in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in ('build', '.git', '__pycache__'))
        for f in sorted(fs):
            p = os.path.join(root, f)
            if f.endswith(EXT) and f != 'xe_drm.h' and not any(x in p for x in exclude):
                yield p


class Consumer:
    def __init__(self, name, kind, feature, roots, exclude=()):
        """roots: [(directory, base the file:line labels are relative to)]"""
        self.name, self.kind, self.feature = name, kind, feature
        self.roots = [(r, b) for r, b in roots if os.path.isdir(r)]
        self.commit = git_head(self.roots[0][0]) if self.roots else 'missing'
        self.text = {}
        for r, b in self.roots:
            for p in files_under(r, exclude):
                try:
                    self.text[os.path.relpath(p, b)] = open(p, errors='ignore').read()
                except OSError:
                    pass

    def hits(self, tok, limit=3):
        out, rx = [], re.compile(r'\b%s\b' % re.escape(tok))
        for f, s in self.text.items():
            m = rx.search(s)
            if m:
                out.append('%s:%d' % (f, s.count('\n', 0, m.start()) + 1))
                if len(out) >= limit:
                    break
        return out


def doc_of(tok, header_text):
    """Kernel-doc text for a token in xe_drm.h ("%TOKEN - text"), else the struct its #define sits in, else ''."""
    m = re.search(r'%%%s\s+-\s+(.+)' % re.escape(tok), header_text)
    if m:
        text = [m.group(1).strip()]
        for line in header_text[m.end():].split('\n')[1:6]:
            t = line.strip()
            if not t.startswith('*') or t.startswith('*/') or re.match(r'\*\s*(-\s*%|@|$)', t):
                break
            text.append(t.lstrip('*').strip())
        return ' '.join(text).rstrip('*/ ').strip()
    d = re.search(r'#define\s+%s\b' % re.escape(tok), header_text)
    if not d:
        return ''
    before = header_text[:d.start()]
    st = list(re.finditer(r'^struct\s+(drm_xe_\w+)\s*\{', before, re.M))
    if st and before.count('{', st[-1].start()) > before.count('}', st[-1].start()):
        return 'value of a field in struct %s' % st[-1].group(1)
    return ''


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mesa', required=True)
    ap.add_argument('--neo', required=True)
    ap.add_argument('--linux', required=True, help='Linux tree (for the xe_drm.h doc comments)')
    ap.add_argument('--data', default=os.path.join(ROOT, 'data'))
    a = ap.parse_args()
    mesa = lambda *p: (os.path.join(a.mesa, *p), a.mesa)
    repo = lambda *p: (os.path.join(ROOT, *p), ROOT)
    consumers = [
        Consumer('Mesa ANV / intel common (as run on macOS)', 'now', None,
                 [mesa('src/intel/vulkan'), mesa('src/intel/common'), mesa('src/intel/dev')], exclude=('/tests/',)),
        Consumer('Metal plugin / VideoToolbox (this repository)', 'now', None, [repo('nullmoth/plugin'), repo('videotoolbox')]),
        Consumer('iris (Mesa)', 'future', 'native OpenGL via iris', [mesa('src/gallium/drivers/iris')]),
        Consumer('Mesa intel/perf', 'future', 'GPU profiler (OA metrics, VK_KHR_performance_query)', [mesa('src/intel/perf')]),
        Consumer('Intel compute-runtime (NEO)', 'future', 'OpenCL / oneAPI (Intel compute-runtime)',
                 [(os.path.join(a.neo, 'shared/source/os_interface/linux'), a.neo)]),
    ]
    searched = ['%s @ %s (%d files)' % (c.name, c.commit, len(c.text)) for c in consumers]
    header = open(os.path.join(a.linux, 'include/uapi/drm/xe_drm.h')).read()
    up = os.path.join(a.data, 'uapi.json')
    u = json.load(open(up))
    for c in u['cells']:
        tok = c['token']
        cons = []
        for k in consumers:
            h = k.hits(tok)
            if h:
                cons.append({'consumer': k.name, 'kind': k.kind, 'feature': k.feature, 'commit': k.commit, 'at': h})
        c['consumers'] = cons
        c['doc'] = doc_of(tok, header)[:200]
        now = [x for x in cons if x['kind'] == 'now']
        fut = [x for x in cons if x['kind'] == 'future']
        lo = next((r for rx, r in LINUX_ONLY if re.search(rx, tok)), None)
        hw = next((r for rx, r in NOT_ON_XE2 if re.search(rx, tok)), None)
        if c['status'] in ('implemented', 'noop'):
            c['need'], c['need_why'] = None, ''
        elif hw:
            c['need'], c['need_why'] = 'not_needed', hw
        elif lo:
            c['need'], c['need_why'] = 'not_needed', 'Linux-only concept: ' + lo
        elif now:
            c['need'] = 'needed_now'
            c['need_why'] = 'used by %s; our kernel: %s' % (', '.join(x['consumer'] for x in now), c['status'])
        elif fut:
            c['need'] = 'needed_future'
            c['need_why'] = 'only for: ' + '; '.join(sorted({x['feature'] for x in fut}))
        else:
            c['need'], c['need_why'] = 'not_needed', 'no consumer found in: ' + '; '.join(searched)
    cnt = {}
    for c in u['cells']:
        key = c['need'] or c['status']
        cnt[key] = cnt.get(key, 0) + 1
    u['need'] = {'searched': searched, 'counts': cnt,
                 'method': 'token names searched in the consumer trees (xe_drm.h copies excluded); tools/parity/consumers.py'}
    json.dump(u, open(up, 'w'), indent=1)
    print('need classes:', json.dumps(cnt))
    write_todo(u, searched)


def write_todo(u, searched):
    red = [c for c in u['cells'] if c.get('need') == 'needed_now']
    orange = [c for c in u['cells'] if c.get('need') == 'needed_future']
    black = [c for c in u['cells'] if c.get('need') == 'not_needed']
    st_tr = {'rejected': 'reddediliyor', 'absent': 'rapor edilmiyor', 'unverified': 'doğrulanmadı'}
    L = ['# Taşınacaklar / What we must port', '',
         'Üretildi / generated: `tools/parity/consumers.py` (`tools/parity/build.sh`). Kaynak: `data/uapi.json`.', '',
         '**TR:** Sıra: önce bugün çalıştırdığımız yazılımın (Mesa ANV ve ortak Intel kodu; eklenti ve VideoToolbox kodunda xe uAPI kullanımı yok) kullandığı ama '
         'çekirdeğimizin uygulamadığı xe uAPI ögeleri (kırmızı), sonra yalnızca gelecekteki bir hedefin (OpenCL/oneAPI, '
         'profiler, iris) kullandığı ögeler (turuncu), özelliğe göre gruplu. Her satır tüketicinin `dosya:satır` kanıtını '
         'taşır; "bizde" sütunu çekirdeğimizdeki durumdur (`uapi.py`). xemac tüketici sayılmaz: ioctl\'ları çekirdeğe ileten katmandır.', '',
         '**EN:** Order: first the xe uAPI items the user space we run today uses but our kernel does not implement (red), '
         'then items only a future target uses (orange), grouped by feature. Each row cites the consumer file:line.', '',
         'Aranan ağaçlar / trees searched:', ''] + ['- ' + s for s in searched] + ['',
         '## 1. Şimdi gerekli, eksik / Needed now, missing (%d)' % len(red), '',
         '| # | Öge / item | Bizde / ours | Ne işe yarar / what it is (xe_drm.h) | Tüketici / consumer (file:line) |', '|---|---|---|---|---|']
    for i, c in enumerate(red, 1):
        ev = '; '.join('%s: %s' % (x['consumer'], ', '.join(x['at'])) for x in c['consumers'] if x['kind'] == 'now')
        ours = st_tr.get(c['status'], c['status']) + (' — ' + c['uses'][0]['at'] if c.get('uses') else '')
        if c.get('comments'):
            ours += '; yalnızca yorumda anılıyor / named only in comments: ' + ', '.join(c['comments'])
        L.append('| %d | `%s` | %s | %s | %s |' % (i, c['token'], ours, c.get('doc', '').replace('|', '/'), ev))
    L += ['', '## 2. Gelecek hedefler için / Needed for a future target (%d)' % len(orange), '']
    groups = {}
    for c in orange:
        for f in sorted({x['feature'] for x in c['consumers'] if x['kind'] == 'future'}):
            groups.setdefault(f, []).append(c)
    for f, cs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        L += ['### %s (%d)' % (f, len(cs)), '', '| Öge / item | Bizde / ours | Tüketici / consumer (file:line) |', '|---|---|---|']
        for c in cs:
            ev = '; '.join('%s: %s' % (x['consumer'], ', '.join(x['at'])) for x in c['consumers'] if x['feature'] == f)
            L.append('| `%s` | %s | %s |' % (c['token'], st_tr.get(c['status'], c['status']), ev))
        L.append('')
    par_p = os.path.join(ROOT, 'data/parity.json')
    if os.path.exists(par_p):
        par = json.load(open(par_p))
        plat = {}
        for f in par['files']:
            if f.get('section') == 'kernel' and f.get('future'):
                plat.setdefault(f['future'], []).append(f)
        tot_fn = sum(f.get('total', 0) for fs in plat.values() for f in fs if f.get('kind') == 'functions')
        L += ['## 3. Diğer Intel GPU\'ları (gelecek donanım hedefleri) / Other Intel GPUs (future hardware targets)', '',
              'Linux xe / i915 display dosyaları; B580\'de olmayan ama başka bir Intel ailesinde bulunan donanım için. Platform ve '
              'gerekçe `tools/parity/map.json`\'dan (Linux kaynağındaki koşula dayanarak). / Files for hardware another Intel family '
              'has; platform and reason from map.json, based on the condition in the Linux source.', '',
              '| Platform | Dosya / files | Fonksiyon / functions | Satır / lines | Gerekçe / reason |', '|---|---|---|---|---|']
        for k, fs in sorted(plat.items(), key=lambda kv: -sum(f['lines'] for f in kv[1])):
            nfn = sum(f['total'] for f in fs if f.get('kind') == 'functions')
            L.append('| %s | %d | %d | %d | %s |' % (k, len(fs), nfn, sum(f['lines'] for f in fs), fs[0]['reason']))
        L.append('')
        for k, fs in sorted(plat.items(), key=lambda kv: -sum(f['lines'] for f in kv[1])):
            L += ['### %s' % k, '', ', '.join('`%s` (%d)' % (f['path'], f['lines']) for f in sorted(fs, key=lambda f: -f['lines'])), '']
        old = [f for f in par['files'] if f.get('section') == 'kernel' and f.get('na') == 'old']
        L += ['Gerekmeyen eski platformlar / pre-Gen12 platforms, not needed: %d dosya, %d satır (%s).' % (
            len(old), sum(f['lines'] for f in old), old[0]['reason'] if old else ''), '']
    L += ['## 4. macOS\'ta gerekmiyor / Not needed on macOS (%d)' % len(black), '',
          'Linux\'a özgü kavramlar (PXP, RAS) ya da hiçbir tüketicide geçmeyen ögeler. / Linux-only concepts or no consumer found.', '',
          ', '.join('`%s`' % c['token'] for c in black), '']
    open(os.path.join(ROOT, 'docs/parity/TODO.md'), 'w').write('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
