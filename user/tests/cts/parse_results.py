#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Parse deqp-vk results copied from the host: results/<group>/*.qpa + events.txt + run.log."""
import os, re, sys, glob, json, collections

RES = sys.argv[1]
STATS = ["Pass", "Fail", "NotSupported", "QualityWarning", "CompatibilityWarning", "Crash", "Timeout", "Other"]

def parse_qpa(path):
    out = {}
    cur, buf = None, []
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("#beginTestCaseResult"):
                cur = line.split()[1]; buf = []
            elif line.startswith("#endTestCaseResult") and cur:
                txt = "".join(buf)
                m = re.search(r'<Result StatusCode="([A-Za-z]+)">(.*?)</Result>', txt, re.S)
                st, msg = (m.group(1), m.group(2).strip()) if m else ("Other", "")
                if not m:
                    m2 = re.search(r'StatusCode="([A-Za-z]+)"', txt)
                    if m2: st = m2.group(1)
                # pull the most useful extra text for failures
                extra = ""
                if st not in ("Pass", "NotSupported"):
                    texts = re.findall(r"<Text>(.*?)</Text>", txt, re.S)
                    extra = " | ".join(t.strip() for t in texts[-3:])[:600]
                out[cur] = (st, msg[:400], extra)
                cur = None
            elif line.startswith("#terminateTestCaseResult") and cur:
                out[cur] = ("Timeout" if "Timeout" in line else "Crash", line.strip(), "")
                cur = None
            elif cur:
                buf.append(line)
    if cur:
        out[cur] = ("Crash", "process died", "")
    return out

groups = {}
times = {}
log = os.path.join(RES, "run.log")
if os.path.exists(log):
    for l in open(log):
        m = re.search(r"GROUP (\S+) end in (\d+)s", l)
        if m: times[m.group(1)] = int(m.group(2))
for gdir in sorted(glob.glob(os.path.join(RES, "g*"))):
    g = os.path.basename(gdir)
    res = {}
    for q in sorted(glob.glob(os.path.join(gdir, "*.qpa")), key=lambda p: (p.split("/")[-1].split(".")[0], int(re.search(r"\.a(\d+)\.qpa", p).group(1)))):
        res.update(parse_qpa(q))
    ev = os.path.join(gdir, "events.txt")
    if os.path.exists(ev):
        for l in open(ev):
            p = l.split()
            if p and p[0] == "TIMEOUT" and len(p) > 1 and p[1] in res:
                res[p[1]] = ("Timeout", "runner: no progress 60 s, killed", "")
            if p and p[0] == "CRASH" and len(p) > 2:
                res[p[2]] = ("Crash", "runner: " + " ".join(p[:2]), "")
    groups[g] = res

summary = {}
for g, res in groups.items():
    c = collections.Counter(v[0] if v[0] in STATS else "Other" for v in res.values())
    summary[g] = {"total": len(res), **{s: c.get(s, 0) for s in STATS}, "wall_s": times.get(g)}
json.dump({"summary": summary,
           "bad": {g: {k: v for k, v in r.items() if v[0] not in ("Pass", "NotSupported")} for g, r in groups.items()}},
          open(os.path.join(RES, "parsed.json"), "w"), indent=1)
print("%-18s %6s %6s %5s %6s %4s %4s %5s %5s %5s %6s" % ("group", "total", "Pass", "Fail", "NotSup", "QW", "CW", "Crash", "Tout", "Other", "wall"))
for g, s in summary.items():
    print("%-18s %6d %6d %5d %6d %4d %4d %5d %5d %5d %6s" % (g, s["total"], s["Pass"], s["Fail"], s["NotSupported"], s["QualityWarning"], s["CompatibilityWarning"], s["Crash"], s["Timeout"], s["Other"], s["wall_s"]))
