#!/usr/bin/env bash
# Render every JSON result under `bench/results/` into a single
# self-contained HTML report at `bench/results/index.html`. The
# report is intentionally dependency-free — no CDN, no JS framework,
# no build step. Open the file in any browser.

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$BENCH_ROOT/results"
HTML_PATH="$RESULTS_DIR/index.html"

if ! command -v python3 >/dev/null 2>&1; then
  echo "render.sh requires python3" >&2
  exit 1
fi

python3 - "$RESULTS_DIR" "$HTML_PATH" <<'PY'
import json
import os
import sys
from pathlib import Path

results_dir = Path(sys.argv[1])
out = Path(sys.argv[2])

reports = []
for path in sorted(results_dir.glob("*.json")):
    with path.open() as f:
        reports.append(json.load(f))

if not reports:
    print("no JSON results found", file=sys.stderr)
    sys.exit(1)


def fmt_ms(ns):
    return f"{ns / 1_000_000:.1f}"


def fmt_relative(ns, baseline_ns):
    if baseline_ns == 0:
        return "—"
    return f"{ns / baseline_ns:.2f}x"


sections = []
for report in reports:
    benchmark = report["benchmark"]
    depth = report["depth"]
    runs = report["runs"]
    results = sorted(report["results"], key=lambda r: r["best_ns"])
    fastest_ns = results[0]["best_ns"]
    max_ns = max(r["best_ns"] for r in results)

    rows = []
    for r in results:
        bar_pct = 100 * r["best_ns"] / max_ns if max_ns else 0
        rows.append(
            f"<tr><td class='lang lang-{r['lang']}'>{r['lang']}</td>"
            f"<td class='ms'>{fmt_ms(r['best_ns'])}</td>"
            f"<td class='rel'>{fmt_relative(r['best_ns'], fastest_ns)}</td>"
            f"<td class='bar'><div class='bar-fill bar-{r['lang']}' style='width:{bar_pct:.1f}%'></div></td></tr>"
        )

    sections.append(
        f"""
        <section class='bench'>
          <header>
            <h2>{benchmark}</h2>
            <div class='meta'>depth={depth} · best of {runs} runs · lower is better</div>
          </header>
          <table>
            <thead><tr><th>language</th><th>time (ms)</th><th>vs fastest</th><th></th></tr></thead>
            <tbody>{''.join(rows)}</tbody>
          </table>
        </section>
        """.strip()
    )

html = f"""<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<title>Zap benchmarks</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #f6f7fb;
    --fg: #1a1c20;
    --muted: #5b6168;
    --row: #ffffff;
    --border: #d8dade;
    --bar-c: #2563eb;
    --bar-rust: #ea580c;
    --bar-zig: #ca8a04;
    --bar-zap: #16a34a;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0d1117;
      --fg: #e6edf3;
      --muted: #8b949e;
      --row: #161b22;
      --border: #30363d;
      --bar-c: #58a6ff;
      --bar-rust: #f59e0b;
      --bar-zig: #facc15;
      --bar-zap: #34d399;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--fg);
    margin: 0; padding: 32px;
  }}
  h1 {{ font-size: 22px; margin: 0 0 4px 0; }}
  .subtitle {{ color: var(--muted); margin-bottom: 32px; }}
  .bench {{
    background: var(--row);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px 24px 24px;
    margin-bottom: 24px;
    max-width: 800px;
  }}
  .bench header h2 {{ font-size: 18px; margin: 0; text-transform: lowercase; }}
  .bench header .meta {{ color: var(--muted); font-size: 12px; margin-top: 4px; }}
  table {{ width: 100%; border-collapse: collapse; margin-top: 16px; }}
  th, td {{ padding: 8px 4px; text-align: left; border-bottom: 1px solid var(--border); }}
  th {{ font-weight: 600; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }}
  td.lang {{ font-weight: 600; }}
  td.ms {{ font-variant-numeric: tabular-nums; width: 90px; }}
  td.rel {{ font-variant-numeric: tabular-nums; width: 80px; color: var(--muted); }}
  td.bar {{ width: auto; }}
  .bar-fill {{ height: 10px; border-radius: 4px; }}
  .lang-c, .bar-c {{ color: var(--bar-c); background: var(--bar-c); }}
  td.lang.lang-c {{ background: transparent; }}
  .lang-rust, .bar-rust {{ color: var(--bar-rust); background: var(--bar-rust); }}
  td.lang.lang-rust {{ background: transparent; }}
  .lang-zig, .bar-zig {{ color: var(--bar-zig); background: var(--bar-zig); }}
  td.lang.lang-zig {{ background: transparent; }}
  .lang-zap, .bar-zap {{ color: var(--bar-zap); background: var(--bar-zap); }}
  td.lang.lang-zap {{ background: transparent; }}
</style>
</head>
<body>
<h1>Zap benchmarks</h1>
<p class='subtitle'>Single-thread, best-of-N wall-clock time. All implementations validated against the C reference output before timing.</p>
{''.join(sections)}
</body>
</html>
"""

out.write_text(html)
print(f"wrote {out}", file=sys.stderr)
PY
