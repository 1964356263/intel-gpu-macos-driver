#!/usr/bin/env python3
"""Render the status images (SVG) from data/*.json: badges, treemaps, video matrix, progress history.

Inputs : data/parity.json (scan.py), data/uapi.json (uapi.py), data/cts/runs.json + data/cts/<run>.tsv.gz
         (cts_import.py), data/video.json (video.py), data/history.json.
Outputs: docs/parity/svg/*.svg, docs/parity/HISTORY.md; with --history-append one entry is added to data/history.json
         (date, repository commit, numbers) unless the newest entry already has the same commit and numbers.
Every cell is one item: an upstream function, a uAPI token, a CTS case or a video combination. No estimates.
Python stdlib only. The SVGs follow prefers-color-scheme (light/dark).
"""
import argparse, collections, datetime, gzip, json, os, subprocess
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'docs/parity/svg')
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

# Turkish SVGs (docs/parity/svg/*.tr.svg, used by README.tr.md): render.py draws every view twice, LANG 'en' then 'tr'.
LANG = 'en'
TR = {'%d functions': '%d fonksiyon', 'not needed': 'gerekmiyor', 'Linux %s @ %s · ours %s @ %s · matched %d of %d applicable functions (%.1f%%) · one cell = one function': 'Linux %s @ %s · bizim kod %s @ %s · gereken fonksiyonların %d / %d tanesi bizde de var (%%%.1f) · her kare bir fonksiyon', 'future targets (functions): ': 'Sonraki hedefler (fonksiyon sayısı): ', 'same name in our code': 'bizde aynı adla var', 'named in our comments': 'bizde yorumlarda adı geçiyor', 'no match': 'bizde yok', 'future target: other Intel GPUs (group = platform)': 'sonraki hedef: diğer Intel kartları (grup = platform)', 'not needed: Linux-only interface or pre-Gen12 platform': "gerekmiyor: yalnızca Linux'a özgü ya da Gen12 öncesi", 'Linux xe + i915/display functions in our kernel': 'Linux xe ve i915 ekran fonksiyonlarının çekirdeğimizdeki karşılıkları', 'Future: ': 'Sonraki hedef: ', 'include/uapi/drm/xe_drm.h @ Linux %s · one cell = one ioctl/query/property/flag · ours %s @ %s': 'include/uapi/drm/xe_drm.h @ Linux %s · her kare bir ioctl, sorgu, özellik ya da bayrak · bizim kod %s @ %s', 'implemented %d of %d (%.1f%%), accepted without effect %d, rejected %d, not reported %d, unverified %d · ioctls %d/%d': '%d / %d tanesi çalışıyor (%%%.1f); %d tanesi kabul edilip yok sayılıyor, %d tanesi reddediliyor, %d tanesi hiç bildirilmiyor, %d tanesi doğrulanmadı · ioctl: %d/%d', 'implemented %d of %d (%.1f%%), accepted without effect %d · not implemented: needed now %d, needed for a future target %d, not needed on macOS %d · ioctls %d/%d': "%d / %d tanesi çalışıyor (%%%.1f); %d tanesi kabul edilip yok sayılıyor · eksikler: hemen gereken %d, sonraki bir hedef için gereken %d, macOS'ta hiç gerekmeyen %d · ioctl: %d/%d", 'need = who uses the item: Mesa ANV/intel common (now); iris, Mesa intel/perf, Intel compute-runtime (future) · evidence: data/uapi.json, docs/parity/TODO.md': 'Gereklilik, öğeyi kimin kullandığına göre: Mesa ANV ve intel common (şimdi); iris, Mesa intel/perf, Intel compute-runtime (ileride) · kanıt: data/uapi.json, docs/parity/TODO.md', 'implemented': 'çalışıyor', 'accepted, no effect': 'kabul ediliyor ama etkisi yok', 'rejected (error)': 'reddediliyor (hata)', 'not reported (proven)': 'bildirilmiyor (bilerek)', 'unverified': 'doğrulanmadı', 'needed now, missing': 'hemen gerekli, eksik', 'needed for a future target': 'sonraki bir hedef için gerekli', 'not needed on macOS': "macOS'ta gerekmiyor", 'xe uAPI coverage of our kernel': 'xe arayüzünün (uAPI) çekirdeğimizdeki karşılığı', '%d/%d pass': '%d/%d geçti', 'run %s (%s)': 'Koşu %s (%s)', '%d cases ran: %d pass, %d not supported, %d crash, %d timeout, %d fail · shard groups stopped early (partial): %s': '%d vaka çalıştı: %d geçti, %d desteklenmiyor, %d çöktü, %d zaman aşımına uğradı, %d başarısız · erken durdurulan gruplar (yarım kalan): %s', 'none': 'yok', 'one cell = %d cases (per sub-group and result); every fail, timeout and warning keeps at least one cell': 'Her kare %d vakayı temsil ediyor (alt grup ve sonuç başına); hiçbir hata, zaman aşımı ya da uyarı kaybolmasın diye her biri en az bir kare alıyor', 'pass': 'geçti', 'not supported': 'desteklenmiyor', 'fail / crash': 'başarısız / çöktü', 'timeout (hang)': 'zaman aşımı (takıldı)', 'Vulkan CTS (deqp-vk) — only the cases that ran': 'Vulkan uyumluluk testi (deqp-vk): yalnızca çalışan vakalar', 'Video: decode / encode on the B580 (VideoToolbox, mediakit)': "Video: B580'de çözme ve kodlama (VideoToolbox, mediakit)", 'source mediakit %s, macOS run %s · Windows reference: %s': 'Kaynak: mediakit %s, macOS ölçümü %s · Windows referansı: %s', 'yes': 'var', 'not measured yet': 'henüz ölçülmedi', 'target: decode bit-exact and >= Windows speed; encode BD-rate <= 0 vs Intel QSV at the same bitrate, overshoot <= 5%': "Hedef: çözmede bit bit doğru sonuç ve en az Windows kadar hız; kodlamada aynı bit hızında Intel QSV'den kötü olmayan kalite (BD-rate <= 0) ve en fazla %5 aşım", 'decode': 'çözme', 'encode': 'kodlama', 'not tested': 'denenmedi', 'by the hardware': 'donanımda yok', 'bit-exact': 'bit bit doğru', 'FAILED (%s)': 'BAŞARISIZ (%s)', 'max overshoot %+.1f%%': 'en fazla aşım %%%+.1f', 'no bitrate data': 'bit hızı verisi yok', 'FAILED (%d streams)': 'BAŞARISIZ (%d akış)', 'BD %+.1f%% · over %+.1f%%': 'BD %%%+.1f · aşım %%%+.1f', 'BD %+.1f%% vs QSV': "QSV'ye göre BD %%%+.1f", 'meets the target': 'hedefe ulaşıyor', 'works on macOS; Windows/QSV reference pending': "macOS'ta çalışıyor; Windows/QSV ölçümü bekleniyor", 'fails the target': 'hedefe ulaşmıyor', 'not supported by the hardware (Intel media-driver Xe2 caps)': 'donanım desteklemiyor (Intel media-driver Xe2 yetenekleri)', 'decode fps: per clip (30p / 60p clip at 1080p), graded against the fastest Windows path (D3D11VA); overshoot = bytes*8/duration/target - 1, max over all VBR streams': "Çözme fps'i klip başına (1080p'de 30p ve 60p klip), Windows'un en hızlı yoluna (D3D11VA) göre değerlendirildi; aşım = bayt*8/süre/hedef - 1, bütün VBR akışlarının en kötüsü", 'BD = worst BD-rate (PSNR-Y) of our VideoToolbox encoder vs Intel QSV at the same settings over the test contents; > 0 means more bits for the same quality': "BD: VideoToolbox kodlayıcımızın, aynı ayarlarda Intel QSV'ye göre test içeriklerindeki en kötü BD-rate'i (PSNR-Y); 0'dan büyükse aynı kalite için daha çok bit harcıyoruz demek", 'Video matrix': 'Video tablosu', 'Progress history (one point per recorded commit)': 'İlerlemenin geçmişi (kaydedilen her commit bir nokta)', 'xe uAPI implemented': 'xe arayüzünde çalışan', 'Linux functions matched': "Linux'la eşleşen fonksiyonlar", 'CTS pass (of cases run)': "CTS'de geçen (çalışan vakalardan)", 'Progress history': 'İlerlemenin geçmişi', 'xe uAPI': 'xe uAPI', '%.1f%% implemented': '%%%.1f çalışıyor', 'Linux functions': 'Linux fonksiyonları', '%.1f%% matched': '%%%.1f eşleşti', 'Vulkan CTS %s': 'Vulkan CTS %s', '%d/%d pass (%d shard groups%s)': '%d/%d geçti (%d grup%s)', ', partial': ', yarım', 'xe uAPI needed now': 'hemen gereken xe uAPI', '%d missing': '%d eksik', 'video decode': 'video çözme', '%d/%d clips bit-exact': '%d/%d klip bit bit doğru'}


def T(s):
    return TR.get(s, s) if LANG == 'tr' else s

# colour classes: light, dark
PAL = {
    'ok': ('#0ca30c', '#1fb51f'), 'okc': ('#86cf86', '#3f7f3f'), 'bad': ('#d03b3b', '#d93636'),
    'hang': ('#f5891f', '#f5891f'), 'warn': ('#fab219', '#fab219'), 'empty': ('#e3e2dc', '#2a2a27'),
    'na': ('#b3b2a9', '#6a6963'), 'nah': ('#cfcec6', '#55544e'), 'blue': ('#2a78d6', '#4d94e8'), 'ns': ('#a7b2c3', '#56627a'),
    'unv': ('#7d8ca3', '#6f7f99'), 'nn': ('#3a3a37', '#050505'),
}


def style():
    light = ''.join('.%s{fill:%s}' % (k, v[0]) for k, v in PAL.items())
    dark = ''.join('.%s{fill:%s}' % (k, v[1]) for k, v in PAL.items())
    return ('<style>.bg{fill:#fcfcfb}.fr{fill:none;stroke:#c3c2b7;stroke-width:1}.t{fill:#0b0b0b;font:600 13px %s}'
            '.l{fill:#0b0b0b;font:600 11px %s}.s{fill:#5f5e58;font:11px %s}%s'
            '@media (prefers-color-scheme:dark){.bg{fill:#1a1a19}.fr{stroke:#383835}.t,.l{fill:#f1f0ea}.s{fill:#a9a89f}%s}'
            '</style>') % (FONT, FONT, FONT, light, dark)


def svg(w, h, body, title):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" '
            'aria-label="%s"><title>%s</title>%s<rect class="bg" width="%d" height="%d"/>%s</svg>\n') % (
        w, h, w, h, escape(title), escape(title), style(), w, h, body)


def text(x, y, s, cls='s', anchor='start'):
    return '<text x="%.1f" y="%.1f" class="%s" text-anchor="%s">%s</text>' % (x, y, cls, anchor, escape(s))


class Paths:
    """Cells collected per colour class and written as one <path> each (small files)."""

    def __init__(self):
        self.p = collections.defaultdict(list)

    def rect(self, cls, x, y, w, h):
        self.p[cls].append('M%.1f %.1fh%.1fv%.1fh-%.1fz' % (x, y, w, h, w))

    def render(self):
        return ''.join('<path class="%s" d="%s"/>' % (c, ''.join(v)) for c, v in self.p.items())


def squarify(values, x, y, w, h):
    """Squarified treemap (Bruls et al.). values sorted descending, all > 0. Returns [(x, y, w, h)]."""
    rects, items = [], list(values)
    total = float(sum(items)) or 1.0
    scale = w * h / total
    items = [v * scale for v in items]

    def worst(row, side):
        s = sum(row)
        return max(max(side * side * r / (s * s), (s * s) / (side * side * r)) for r in row)

    while items:
        side = min(w, h)
        row = [items.pop(0)]
        while items and worst(row + [items[0]], side) <= worst(row, side):
            row.append(items.pop(0))
        s = sum(row)
        if w >= h:   # column on the left
            cw = s / h if h else 0
            yy = y
            for r in row:
                rh = r / cw if cw else 0
                rects.append((x, yy, cw, rh))
                yy += rh
            x, w = x + cw, w - cw
        else:        # row on top
            rh = s / w if w else 0
            xx = x
            for r in row:
                rw = r / rh if rh else 0
                rects.append((xx, y, rw, rh))
                xx += rw
            y, h = y + rh, h - rh
    return rects


def grid(paths, cells, x, y, w, h):
    """cells: list of colour classes, drawn as a grid of equal cells filling the rectangle."""
    n = len(cells)
    if n == 0 or w < 1 or h < 1:
        return
    cols = max(1, int(round((n * w / h) ** 0.5)))
    rows = (n + cols - 1) // cols
    cols = (n + rows - 1) // rows
    cw, ch = w / cols, h / rows
    gap = 0.6 if min(cw, ch) > 2.6 else 0.25
    for i, c in enumerate(cells):
        r, k = divmod(i, cols)
        paths.rect(c, x + k * cw + gap / 2, y + r * ch + gap / 2, max(cw - gap, 0.3), max(ch - gap, 0.3))


def treemap(groups, W, cell_px, title, subtitle, legend):
    """groups: [(name, label, [(leaf_name, [cls...]) ...])]. Area of each leaf = number of cells."""
    n_cells = sum(len(c) for _, _, leaves in groups for _, c in leaves)
    subs = subtitle if isinstance(subtitle, list) else [subtitle]
    head = 58 + 15 * (len(subs) - 1)
    body = [text(12, 22, title, 't')] + [text(12, 40 + 15 * i, s_) for i, s_ in enumerate(subs)]
    lx, ly = 12, head - 1
    for cls, name in legend:
        body.append('<rect x="%d" y="%d" width="10" height="10" rx="2" class="%s"/>' % (lx, ly - 9, cls))
        body.append(text(lx + 14, ly, name))
        lx += 22 + int(len(name) * 6.2)
    paths = Paths()
    groups = [g for g in groups if sum(len(c) for _, c in g[2])]
    groups.sort(key=lambda g: -sum(len(c) for _, c in g[2]))
    H = int(n_cells * cell_px * cell_px * 1.35 / W) + head + 70 + 18 * len(groups)
    rects = squarify([sum(len(c) for _, c in g[2]) + 30 for g in groups], 8, head + 14, W - 16, H - head - 22)
    for (name, label, leaves), (gx, gy, gw, gh) in zip(groups, rects):
        body.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" class="fr"/>' % (gx + 1, gy + 1, gw - 2, gh - 2))
        lab = 15 if gh > 40 and gw > 60 else 0
        if lab:
            s = name if len(name) * 6.6 < gw - 8 else name[:max(3, int((gw - 8) / 6.6) - 1)] + '…'
            body.append(text(gx + 5, gy + 13, s, 'l'))
            if label and (len(s) + len(label)) * 6.4 + 12 < gw:
                body.append(text(gx + gw - 5, gy + 13, label, 's', 'end'))
        leaves = sorted([l for l in leaves if l[1]], key=lambda l: -len(l[1]))
        lr = squarify([len(c) for _, c in leaves], gx + 3, gy + 3 + lab, gw - 6, gh - 6 - lab)
        for (lname, cells), (lx_, ly, lw, lh) in zip(leaves, lr):
            grid(paths, cells, lx_ + 0.5, ly + 0.5, lw - 1, lh - 1)
    body.append(paths.render())
    return svg(W, H, ''.join(body), title)


def badge(label, value, color):
    lw, vw = int(len(label) * 6.3) + 12, int(len(value) * 6.6) + 12
    w = lw + vw
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="20" role="img" aria-label="%s: %s"><title>%s: %s</title>'
            '<rect width="%d" height="20" rx="3" fill="#555"/><rect x="%d" width="%d" height="20" rx="3" fill="%s"/>'
            '<rect x="%d" width="4" height="20" fill="%s"/>'
            '<g fill="#fff" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11">'
            '<text x="%d" y="14">%s</text><text x="%d" y="14">%s</text></g></svg>\n') % (
        w, escape(label), escape(value), escape(label), escape(value), w, lw, vw, color, lw, color,
        6, escape(label), lw + 6, escape(value))


def write(name, content):
    if LANG == 'tr' and name.endswith('.svg'):
        name = name[:-4] + '.tr.svg'
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), 'w') as f:
        f.write(content)


def git(*a):
    return subprocess.run(['git', '-C', ROOT] + list(a), capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------------------------------------------- views

def functions_view(par):
    k = par['summary']['kernel']
    groups = collections.OrderedDict()
    for f in par['files']:
        if f['section'] != 'kernel' or f.get('kind') != 'functions':
            continue
        group = f['group']
        if f['status'] == 'not_applicable':
            if f['na'] == 'hw' and f.get('future'):
                cells, group = ['hang'] * f['total'], 'Future: ' + f['future']
            else:
                cells = ['nn'] * f['total']
        else:
            code = [e for e in f['evidence'] if e['in_code']]
            cells = ['ok'] * len(code) + ['okc'] * (f['matched'] - len(code)) + ['empty'] * (f['total'] - f['matched'])
        groups.setdefault(group, []).append((f['path'], cells))
    out = []
    for g, leaves in groups.items():
        cells = [c for _, cs in leaves for c in cs]
        app = [c for c in cells if c not in ('nn', 'hang')]
        m = sum(1 for c in app if c in ('ok', 'okc'))
        lab = '%d/%d' % (m, len(app)) if app else (T('%d functions') % len(cells) if g.startswith('Future') else T('not needed'))
        out.append((g, lab, leaves))
    meta = par['meta']
    sub = T('Linux %s @ %s · ours %s @ %s · matched %d of %d applicable functions (%.1f%%) · one cell = one function') % (
        meta['linux']['version'], meta['linux']['rev'], meta['ours']['kernel']['repo'], meta['ours']['kernel']['repo_head'],
        k['functions_matched'], k['functions_total'], k['pct_functions_matched'])
    fut = sorted(((g[len('Future: '):], sum(len(c) for _, c in leaves)) for g, _, leaves in out if g.startswith('Future: ')), key=lambda x: -x[1])
    if fut:
        line, lines = T('future targets (functions): '), []
        for name, n in fut:
            item = '%s %d · ' % (name, n)
            if len(line) + len(item) > 190:
                lines.append(line.rstrip(' ·'))
                line = '  '
            line += item
        lines.append(line.rstrip(' ·'))
        sub = [sub] + lines
    legend = [('ok', T('same name in our code')), ('okc', T('named in our comments')), ('empty', T('no match')),
              ('hang', T('future target: other Intel GPUs (group = platform)')),
              ('nn', T('not needed: Linux-only interface or pre-Gen12 platform'))]
    out = [((T('Future: ') + g[len('Future: '):]) if g.startswith('Future: ') else g, l, lv) for g, l, lv in out]
    return treemap(out, 1200, 5.2, T('Linux xe + i915/display functions in our kernel'), sub, legend)


def uapi_view(u):
    m = {'implemented': 'ok', 'noop': 'warn', 'rejected': 'bad', 'absent': 'na', 'unverified': 'unv'}
    need = {'needed_now': 'bad', 'needed_future': 'hang', 'not_needed': 'nn'}
    has_need = 'need' in u
    groups = collections.OrderedDict()
    for c in u['cells']:
        groups.setdefault(c['area'], []).append(need[c['need']] if has_need and c.get('need') else m[c['status']])
    out = []
    for a, cells in groups.items():
        order = {'ok': 0, 'warn': 1, 'bad': 2, 'hang': 3, 'na': 4, 'unv': 5, 'nn': 6}
        cells.sort(key=lambda c: order[c])
        out.append((a, '%d/%d' % (cells.count('ok'), len(cells)), [(a, cells)]))
    s = u['summary']
    sub = [T('include/uapi/drm/xe_drm.h @ Linux %s · one cell = one ioctl/query/property/flag · ours %s @ %s') % (
        u['meta']['linux'], u['meta']['ours']['kernel']['repo'], u['meta']['ours']['kernel']['repo_head']),
           T('implemented %d of %d (%.1f%%), accepted without effect %d, rejected %d, not reported %d, unverified %d · ioctls %d/%d')
           % (s['implemented'], s['cells'], s['pct_implemented'], s['noop'], s['rejected'], s['absent'], s['unverified'],
              s['ioctls_implemented'], s['ioctls'])]
    legend = [('ok', T('implemented')), ('warn', T('accepted, no effect')), ('bad', T('rejected (error)')),
              ('na', T('not reported (proven)')), ('unv', T('unverified'))]
    if has_need:
        nc = u['need']['counts']
        sub[1] = T('implemented %d of %d (%.1f%%), accepted without effect %d · not implemented: needed now %d, needed for a future target %d, not needed on macOS %d · ioctls %d/%d') % (
            s['implemented'], s['cells'], s['pct_implemented'], s['noop'], nc.get('needed_now', 0), nc.get('needed_future', 0),
            nc.get('not_needed', 0), s['ioctls_implemented'], s['ioctls'])
        sub.append(T('need = who uses the item: Mesa ANV/intel common (now); iris, Mesa intel/perf, Intel compute-runtime (future) · evidence: data/uapi.json, docs/parity/TODO.md'))
        legend = [('ok', T('implemented')), ('warn', T('accepted, no effect')), ('bad', T('needed now, missing')),
                  ('hang', T('needed for a future target')), ('nn', T('not needed on macOS'))]
    return treemap(out, 1200, 22, T('xe uAPI coverage of our kernel'), sub, legend)


CTS_MAX_CELLS = 40000
CTS_CLS = {'Pass': 'ok', 'Fail': 'bad', 'Crash': 'bad', 'DeviceLost': 'bad', 'Timeout': 'hang', 'NotSupported': 'ns',
           'QualityWarning': 'warn', 'CompatibilityWarning': 'warn'}


def cts_view(run, rows):
    groups = collections.OrderedDict()
    for case, st, _ in rows:
        parts = case.split('.')
        top, sub = parts[1], parts[2] if len(parts) > 3 else parts[1]
        groups.setdefault(top, collections.OrderedDict()).setdefault(sub, []).append(CTS_CLS.get(st, 'bad'))
    order = {'ok': 0, 'warn': 1, 'ns': 2, 'hang': 3, 'bad': 4}
    # A full run (3.2 M cases) cannot be drawn one cell per case: above CTS_MAX_CELLS one cell stands for k cases,
    # per class and sub-group (rounded), and every warn / hang / fail class that occurs keeps at least one cell so
    # no failure disappears from the picture (its area is then exaggerated; the counts are in the labels).
    total = sum(len(c) for subs in groups.values() for c in subs.values())
    k = max(1, -(-total // CTS_MAX_CELLS))
    out = []
    for g, subs in groups.items():
        leaves = []
        for s_, c in subs.items():
            if k == 1:
                cells = sorted(c, key=lambda x: order[x])
            else:
                cnt = collections.Counter(c)
                cells = []
                for cls in sorted(cnt, key=lambda x: order[x]):
                    n = int(round(cnt[cls] / k))
                    if n == 0 and (cls in ('warn', 'hang', 'bad') or not cells):
                        n = 1
                    cells += [cls] * n
            leaves.append((s_, cells))
        allc = [c for c in subs.values() for c in c]
        out.append(('dEQP-VK.' + g, T('%d/%d pass') % (allc.count('ok'), len(allc)), leaves))
    st = run['status']
    sub = [T('run %s (%s)') % (run['id'], run['date']), run['stack'],
           T('%d cases ran: %d pass, %d not supported, %d crash, %d timeout, %d fail · shard groups stopped early (partial): %s') % (
        run['cases'], st.get('Pass', 0), st.get('NotSupported', 0), st.get('Crash', 0),
        st.get('Timeout', 0), st.get('Fail', 0), ', '.join(run['partial_groups']) or T('none'))]
    if run.get('note'):
        sub.append(run['note'])
    if k > 1:
        sub.append(T('one cell = %d cases (per sub-group and result); every fail, timeout and warning keeps at least one cell') % k)
    legend = [('ok', T('pass')), ('ns', T('not supported')), ('bad', T('fail / crash')), ('hang', T('timeout (hang)'))]
    return treemap(out, 1200, 4.2, T('Vulkan CTS (deqp-vk) — only the cases that ran'), sub, legend)


def run_date(runs):
    import re as _re
    ds = [_re.search(r'(\w{3}) (\d+) (\d\d:\d\d):\d\d \S+ (\d{4})', r) for r in runs]
    ds = [d for d in ds if d]
    if not ds:
        return '?'
    mon = {'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, 'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12}
    f = lambda d: '%s-%02d-%02d %s' % (d.group(4), mon[d.group(1)], int(d.group(2)), d.group(3))
    return f(ds[0]) + ('..' + f(ds[-1])[11:] if len(ds) > 1 else '')


def video_view(v):
    cols = [(8, '1080p'), (8, '2160p'), (8, '4320p'), (10, '1080p'), (10, '2160p'), (10, '4320p')]
    rows = [(c, d) for c in ('h264', 'hevc', 'av1', 'vp9') for d in ('decode', 'encode')]
    cells = {(c['codec'], c['dir'], c['bits'], c['res']): c for c in v['cells']}
    cw, ch, x0, y0 = 160, 46, 150, 92
    W, H = x0 + cw * len(cols) + 12, y0 + ch * len(rows) + 80
    body = [text(12, 22, T('Video: decode / encode on the B580 (VideoToolbox, mediakit)'), 't'),
            text(12, 40, T('source mediakit %s, macOS run %s · Windows reference: %s') % (v['meta']['source'], run_date(v['meta']['runs']), T('yes') if v['meta']['windows'] else T('not measured yet'))),
            text(12, 56, T('target: decode bit-exact and >= Windows speed; encode BD-rate <= 0 vs Intel QSV at the same bitrate, overshoot <= 5%'))]
    for i, (b, r) in enumerate(cols):
        body.append(text(x0 + i * cw + cw / 2, y0 - 8, '%d-bit %s' % (b, r), 'l', 'middle'))
    gcls = {'pending': 'warn', 'fail': 'bad', 'untested': 'empty', 'pass': 'ok', 'unsupported': 'ns'}
    for j, (c, d) in enumerate(rows):
        y = y0 + j * ch
        body.append(text(12, y + ch / 2 + 4, '%s %s' % ({'h264': 'H.264', 'hevc': 'HEVC', 'av1': 'AV1', 'vp9': 'VP9'}[c], T(d)), 'l'))
        for i, (b, r) in enumerate(cols):
            cell = cells.get((c, d, b, r), {'grade': 'untested'})
            x = x0 + i * cw
            body.append('<rect x="%d" y="%d" width="%d" height="%d" rx="4" class="%s"/>' % (x + 2, y + 2, cw - 4, ch - 4, gcls[cell['grade']]))
            if cell['grade'] == 'untested':
                line1, line2 = T('not tested'), ''
            elif cell['grade'] == 'unsupported':
                line1, line2 = T('not supported'), T('by the hardware')
            elif d == 'decode':
                its = cell['items']
                line1 = T('bit-exact') if all(i_['exact'] for i_ in its) else T('FAILED (%s)') % its[0]['md5']
                line2 = ' / '.join('%g fps' % i_['fps'] for i_ in its if i_['fps'])
            else:
                o = cell.get('max_overshoot_pct')
                bd = cell.get('bd_rate_vs_qsv')
                line1 = (T('max overshoot %+.1f%%') % o) if o is not None else T('no bitrate data')
                if cell.get('failed_streams'):
                    line1 = T('FAILED (%d streams)') % len(cell['failed_streams'])
                if bd:
                    line1 = T('BD %+.1f%% · over %+.1f%%') % (max(e['psnr_pct'] for e in bd), o) if o is not None else \
                        T('BD %+.1f%% vs QSV') % max(e['psnr_pct'] for e in bd)
                sp = cell.get('speed', {})
                line2 = ('%g fps (medium)' % sp['medium']) if 'medium' in sp else (
                    '%g fps' % max(i_.get('fps', 0) for i_ in cell['items']) if cell.get('items') else '')
            ink = {'warn': '#0b0b0b', 'bad': '#ffffff', 'ok': '#ffffff'}.get(gcls[cell['grade']])
            for yy, s_, w_ in ((y + 19, line1, 600), (y + 34, line2, 400)):
                if not s_:
                    continue
                if ink:
                    body.append('<text x="%.1f" y="%.1f" text-anchor="middle" style="fill:%s;font:%d 11px %s">%s</text>' % (x + cw / 2, yy, ink, w_, FONT.replace("'", ''), escape(s_)))
                else:
                    body.append(text(x + cw / 2, yy, s_, 'l' if w_ == 600 else 's', 'middle'))
    ly = y0 + ch * len(rows) + 22
    lx = 12
    for cls, name in [('ok', T('meets the target')), ('warn', T('works on macOS; Windows/QSV reference pending')), ('bad', T('fails the target')),
                      ('ns', T('not supported by the hardware (Intel media-driver Xe2 caps)')), ('empty', T('not tested'))]:
        x = lx
        lx += 34 + int(len(name) * 6.2)
        body.append('<rect x="%d" y="%d" width="10" height="10" rx="2" class="%s"/>' % (x, ly - 9, cls))
        body.append(text(x + 14, ly, name))
    body.append(text(12, ly + 20, T('decode fps: per clip (30p / 60p clip at 1080p), graded against the fastest Windows path (D3D11VA); overshoot = bytes*8/duration/target - 1, max over all VBR streams')))
    body.append(text(12, ly + 36, T('BD = worst BD-rate (PSNR-Y) of our VideoToolbox encoder vs Intel QSV at the same settings over the test contents; > 0 means more bits for the same quality')))
    return svg(W, H, ''.join(body), T('Video matrix'))


def history_view(hist):
    W, H, x0, y0, pw, ph = 1200, 320, 60, 50, 1100, 200
    body = [text(12, 22, T('Progress history (one point per recorded commit)'), 't')]
    for v in (0, 25, 50, 75, 100):
        y = y0 + ph - ph * v / 100.0
        body.append('<path d="M%d %.1fh%d" class="fr"/>' % (x0, y, pw))
        body.append(text(x0 - 8, y + 4, '%d%%' % v, 's', 'end'))
    series = [('uapi_pct', 'ok', T('xe uAPI implemented')), ('functions_pct', 'blue', T('Linux functions matched')),
              ('cts_pass_pct', 'hang', T('CTS pass (of cases run)'))]
    n = len(hist)
    xs = [x0 + (pw * (i + 0.5) / n) for i in range(n)]
    for key, cls, name in series:
        pts = [(xs[i], y0 + ph - ph * h[key] / 100.0) for i, h in enumerate(hist) if h.get(key) is not None]
        if len(pts) > 1:
            body.append('<path d="M%s" fill="none" stroke-width="2" class="%s" style="fill:none;stroke:currentColor"/>' % (
                'L'.join('%.1f %.1f' % p for p in pts), cls))
        for p in pts:
            body.append('<circle cx="%.1f" cy="%.1f" r="4" class="%s"/>' % (p[0], p[1], cls))
    for i, h in enumerate(hist):
        if n <= 12 or i % max(1, n // 12) == 0:
            body.append(text(xs[i], y0 + ph + 16, h['date'][:10], 's', 'middle'))
            lab = (h.get('label') or '')[:11]
            body.append(text(xs[i], y0 + ph + 30, h['commit'], 's', 'middle'))
            if lab:
                body.append(text(xs[i], y0 + ph + 44, lab, 's', 'middle'))
    for k, (_, cls, name) in enumerate(series):
        body.append('<circle cx="%d" cy="%d" r="5" class="%s"/>' % (x0 + 6 + k * 260, H - 14, cls))
        body.append(text(x0 + 16 + k * 260, H - 10, name))
    out = svg(W, H, ''.join(body), T('Progress history'))
    # line strokes take the fill colour of their class
    for _, cls, _ in series:
        light, dark = PAL[cls]
        out = out.replace('class="%s" style="fill:none;stroke:currentColor"' % cls,
                          'class="%s" style="fill:none;stroke:%s"' % (cls, light))
    return out


# ------------------------------------------------------------------------------------------------------------------ main

def numbers(par, u, run, v):
    k = par['summary']['kernel']
    return {
        'functions_matched': k['functions_matched'], 'functions_total': k['functions_total'],
        'functions_pct': k['pct_functions_matched'],
        'uapi_implemented': u['summary']['implemented'] if u else None, 'uapi_total': u['summary']['cells'] if u else None,
        'uapi_pct': u['summary']['pct_implemented'] if u else None,
        'cts_run': run['id'] if run else None, 'cts_cases': run['cases'] if run else None,
        'cts_pass': run['status'].get('Pass', 0) if run else None,
        'cts_pass_pct': round(100.0 * run['status'].get('Pass', 0) / run['cases'], 1) if run else None,
        'video_decode_exact': v['summary']['decode_exact'] if v else None, 'video_decode_clips': v['summary']['decode_clips'] if v else None,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--data', default=os.path.join(ROOT, 'data'))
    ap.add_argument('--history-append', action='store_true')
    ap.add_argument('--label', default='', help='short label for the history entry (e.g. kernel rb7i)')
    a = ap.parse_args()
    D = lambda n: json.load(open(os.path.join(a.data, n))) if os.path.exists(os.path.join(a.data, n)) else None
    par, u, v = D('parity.json'), D('uapi.json'), D('video.json')
    runs = D('cts/runs.json') or []
    run = runs[-1] if runs else None
    rows = []
    if run:
        with gzip.open(os.path.join(a.data, 'cts', run['id'] + '.tsv.gz'), 'rt') as f:
            next(f)
            rows = [l.rstrip('\n').split('\t') for l in f]

    global LANG
    for LANG in ('en', 'tr'):   # every SVG twice: name.svg (README.md) and name.tr.svg (README.tr.md)
        write('functions.svg', functions_view(par))
        if u:
            write('uapi.svg', uapi_view(u))
        if run:
            write('cts.svg', cts_view(run, rows))
            for r in runs:
                with gzip.open(os.path.join(a.data, 'cts', r['id'] + '.tsv.gz'), 'rt') as f:
                    next(f)
                    write('cts-%s.svg' % r['id'], cts_view(r, [l.rstrip('\n').split('\t') for l in f]))
        if v:
            write('video.svg', video_view(v))

        nums = numbers(par, u, run, v)
        write('badge-uapi.svg', badge(T('xe uAPI'), T('%.1f%% implemented') % nums['uapi_pct'], '#0ca30c' if nums['uapi_pct'] >= 50 else '#d6a106'))
        write('badge-functions.svg', badge(T('Linux functions'), T('%.1f%% matched') % nums['functions_pct'], '#d6a106'))
        if run:
            write('badge-cts.svg', badge(T('Vulkan CTS %s') % run['date'][:10], T('%d/%d pass (%d shard groups%s)') % (
                nums['cts_pass'], nums['cts_cases'], len(run['shard_groups']), T(', partial') if run['partial_groups'] else ''), '#2a78d6'))
        if u and 'need' in u:
            nn = u['need']['counts'].get('needed_now', 0)
            write('badge-todo.svg', badge(T('xe uAPI needed now'), T('%d missing') % nn, '#d03b3b' if nn else '#0ca30c'))
        if v:
            write('badge-video.svg', badge(T('video decode'), T('%d/%d clips bit-exact') % (nums['video_decode_exact'], nums['video_decode_clips']),
                                           '#0ca30c' if nums['video_decode_exact'] == nums['video_decode_clips'] else '#d6a106'))
    LANG = 'en'

    hp = os.path.join(a.data, 'history.json')
    hist = json.load(open(hp)) if os.path.exists(hp) else []
    if a.history_append:
        entry = {'date': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'), 'commit': git('rev-parse', '--short', 'HEAD'),
                 'dirty': bool(git('status', '--porcelain', '--', 'kernel')), 'label': a.label,
                 'kernel_commit': par['meta']['ours']['kernel']['last_commit'], 'fb_commit': par['meta']['ours']['fb']['last_commit'],
                 'linux_rev': par['meta']['linux']['rev'], **nums}
        same = hist and all(hist[-1].get(x) == entry.get(x) for x in ['commit', 'dirty'] + list(nums))
        if not same:
            hist.append(entry)
            json.dump(hist, open(hp, 'w'), indent=1)
    if hist:
        for LANG in ('en', 'tr'):
            write('history.svg', history_view(hist))
        LANG = 'en'
        md = ['# İlerleme geçmişi / Progress history', '',
              '`tools/parity/build.sh` her çalıştığında `data/history.json`\'a bir satır ekler (aynı commit ve aynı sayılar tekrar yazılmaz).',
              'Geçmiş satırlar `tools/parity/history_backfill.py` ile geliştirme deposundaki çekirdek commit\'lerinden yeniden ölçüldü (commit kimlikleri o deponun, bu depoda yoklar).', '',
              'Each run of `tools/parity/build.sh` appends one row; earlier rows were re-measured from the development repository\'s kernel commits (the commit ids are from that repository, not this one).', '',
              '![history](svg/history.svg)', '',
              '| Tarih / date | Commit | Etiket / label | xe uAPI | Linux fonksiyonları / functions | CTS (koşu / run) | Video çözme / decode |',
              '|---|---|---|---|---|---|---|']
        for h in reversed(hist):
            md.append('| %s | %s%s | %s | %s/%s (%s%%) | %s/%s (%s%%) | %s | %s |' % (
                h['date'], h['commit'], ' (+değişiklik)' if h.get('dirty') else '', h.get('label', ''),
                h['uapi_implemented'], h['uapi_total'], h['uapi_pct'], h['functions_matched'], h['functions_total'], h['functions_pct'],
                ('%s/%s pass, %s' % (h['cts_pass'], h['cts_cases'], h['cts_run'])) if h.get('cts_run') else '—',
                ('%s/%s bit-exact' % (h['video_decode_exact'], h['video_decode_clips'])) if h.get('video_decode_clips') else '—'))
        open(os.path.join(ROOT, 'docs/parity/HISTORY.md'), 'w').write('\n'.join(md) + '\n')
    print('rendered:', ', '.join(sorted(os.listdir(OUT))))
    print('numbers:', json.dumps(nums))


if __name__ == '__main__':
    main()
