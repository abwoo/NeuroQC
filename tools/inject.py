#!/usr/bin/env python3
"""Showcase sync injector / consistency checker for the NeuroQC public repo.

Subcommands (default: sync):

  sync      Compose showcase-metrics.json from the source repo (code version,
            test log, capture metrics, asset sizes) and rewrite every tracked
            spot: version badges/citations/tutorial headers, test counts, and
            the marked numbers blocks (tables + manual paragraphs).
  --check   Read ONLY docs/assets/showcase-metrics.json (no source repo
            needed — runs in GitHub Actions) and verify:
              1. version spots (badges, bibtex) == metrics.version
              2. test-count spots (trust bars, og, stat) == metrics.test_count
              3. marked numbers blocks == template rendered from metrics
              4. fact scan: pipeline ids / GoalScore decimals / ratios seen in
                 prose belong to the metrics fact set
              5. referenced assets exist, are non-empty, match metrics sizes
            Exit 0 = consistent, 1 = drift found (nothing is written).

Templates for the numbers blocks live below. If you change a block's wording
in a README, change the matching template here too — the block is regenerated
wholesale and will be overwritten otherwise.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SOURCE_ROOT = SCRIPT_DIR.parent.parent  # <root>/tools/showcase


# ----------------------------------------------------------------------------
# Composition (sync only)
# ----------------------------------------------------------------------------
def read_source_version(root: Path) -> str:
    vals = {}
    p1 = root / 'eegplugin_neuroqc.m'
    p2 = root / '+neuroqc' / 'NeuroQC.m'
    m = re.search(r"v\s*=\s*'(\d+\.\d+\.\d+)'", p1.read_text(encoding='utf-8'))
    assert m, f'version not found in {p1}'
    vals[str(p1)] = m.group(1)
    m = re.search(r"Version\s*=\s*'(\d+\.\d+\.\d+)'", p2.read_text(encoding='utf-8'))
    assert m, f'version not found in {p2}'
    vals[str(p2)] = m.group(1)
    uniq = set(vals.values())
    assert len(uniq) == 1, f'source version mismatch: {vals}'
    return uniq.pop()


def read_test_count(log: Path) -> int:
    assert log.exists(), f'test log not found: {log} (run run_all_tests first)'
    m = re.search(r'TOTAL=(\d+)\s+PASSED=\d+\s+FAILED=(\d+)', log.read_text(encoding='utf-8'))
    assert m, f'TOTAL/PASSED/FAILED line not found in {log}'
    assert m.group(2) == '0', f'FAILED={m.group(2)} — showcase sync requires a green suite'
    return int(m.group(1))


def scan_assets(staging: Path) -> dict:
    out = {}
    for sub in ('docs/assets', 'site/assets'):
        d = staging / sub
        if not d.is_dir():
            continue
        for f in sorted(d.iterdir()):
            if f.suffix.lower() in ('.gif', '.png', '.svg') and f.is_file():
                out[f'{sub}/{f.name}'] = f.stat().st_size
    return out


# ----------------------------------------------------------------------------
# Rendering
# ----------------------------------------------------------------------------
def fmt_range3(r):
    return f'{r[0]:.3f}–{r[1]:.3f}'


def fmt_ret(r):
    if abs(r[0] - r[1]) < 1e-9:
        return f'{r[0]:.2f}'
    return f'{r[0]:.2f}–{r[1]:.2f}'


def render_context(metrics: dict) -> dict:
    cap = metrics['capture']
    n = int(cap['nPipelines'])
    total = int(re.search(r'\d+', cap['grid']).group())
    legal = n
    rejected = total - n
    n_eval = int(cap['nEvaluated'])
    fails = int(cap['trialFailures'])
    n_front = int(cap['nFront'])
    pct = round(100 * n_eval / n) if n else 0
    ctx = {
        'version': metrics['version'],
        'tests': int(metrics['test_count']),
        'grid': cap['grid'],
        'n': n,
        'total': total,
        'legal': legal,
        'rejected': rejected,
        'n_eval': n_eval,
        'fails': fails,
        'status': cap['status'],
        'n_front': n_front,
        'dom': n - n_front,
        'pct': pct,
        'rel': fmt_range3(cap['relRange']),
        'dist': fmt_range3(cap['distRange']),
        'ret': fmt_ret(cap['retRange']) if cap.get('retRange') else '1.00',
        'best_app': cap['bestBalancedId'],
        'qc_best': cap['balancedQcBestId'],
        'qc_score': f"{cap['balancedQcBestScore']:.4f}",
        'md_best': cap['minDistBestId'],
        'md_score': f"{cap['minDistBestScore']:.4f}",
        'w_bal': cap['balancedWeights'],
        'w_md': cap['minDistWeights'],
    }
    return ctx


TEMPLATE_EN = """\
| Stage | What happened |
|---|---|
| **Preview** | 4 highpass × 2 lowpass → **{n} combinations; {legal} legal; {rejected} rejected** |
| **Log** | `filter > epoch` enumerated for every combination — `valid={legal}; invalid={fails}; duplicate=0` |
| **Generate** | **{n} standalone recipe scripts** written, zero signal processing |
| **Compare all** | **{n_eval} / {n} evaluated ({pct}%)**, {fails} failures → status `{status}` |
| **Pareto front** | **{n_front} of {n}** survive the 5-objective front; {dom} dominated candidates dropped |
| **Goal ranking** | `bestEvaluated` on the recommended row (best **{best_app}**), plus per-objective labels (`reliability`, `retention`, `topoStability`, `waveformDistortion`, `interpRatio`) |
| **Metrics** | Rel {rel} · Reten {ret} · Dist {dist} (hard gate ≤ 0.50) |
| **QC import** | One click fills Rel / Reten / Dist / labels, Pareto front and `bestEvaluated` from your measured metrics — status `REVIEW` |
| **Goal switch** | Balanced (`{w_bal}`) → best **{qc_best}** (GoalScore {qc_score}); Lower filter distortion (`{w_md}`) → best **flips to {md_best}** ({md_score}) — same QC data, no re-measurement |
| **Drift gate** | One edit after generation → red `Required: Settings changed…`, Compare/Retry disabled |

**Manual workflow vs. NeuroQC on this exact run:** by hand you would normally settle on one
filter pair, run it, eyeball the ERP, maybe try one more — 1–2 pipelines at most, with no
record of what was skipped. NeuroQC enumerated **all {n}**, executed **all {n} on copies**,
enforced the hard constraints, kept the Pareto-optimal **{n_front}**, and returned a ranked shortlist
in which every row is a reproducible script."""

TEMPLATE_SITE = """\
    <div class="tblbox">
      <table>
        <tr><th>Stage</th><th>What happened</th></tr>
        <tr><td><b>Preview</b></td><td>4 highpass × 2 lowpass → <b>{n} combinations; {legal} legal; {rejected} rejected</b></td></tr>
        <tr><td><b>Generate</b></td><td><b>{n} standalone recipe scripts</b> written, zero signal processing</td></tr>
        <tr><td><b>Compare all</b></td><td><b>{n_eval} / {n} evaluated ({pct}%)</b>, {fails} failures → status <code>{status}</code></td></tr>
        <tr><td><b>Pareto front</b></td><td><b>{n_front} of {n}</b> survive the 5-objective front</td></tr>
        <tr><td><b>Goal ranking</b></td><td>best <b>{best_app}</b> under app metrics; QC import ranks best <b>{qc_best}</b> ({qc_score})</td></tr>
        <tr><td><b>Metrics</b></td><td>Rel {rel} · Reten {ret} · Dist {dist} (hard gate ≤ 0.50)</td></tr>
        <tr><td><b>Goal switch</b></td><td>Balanced → <b>{qc_best}</b>; Lower filter distortion → best flips to <b>{md_best}</b> ({md_score}) — same QC data</td></tr>
        <tr><td><b>Drift gate</b></td><td>One edit after generation → red <code>Required: Settings changed…</code>, Compare/Retry disabled</td></tr>
      </table>
    </div>
    <p class="lead" style="margin-top:26px"><b>Manual vs NeuroQC on this exact run:</b> by hand you would
      settle on one filter pair, maybe try a second — 1–2 pipelines with no record of what was skipped.
      NeuroQC enumerated <b>all {n}</b>, executed <b>all {n} on copies</b>, kept the Pareto-optimal <b>{n_front}</b>,
      and returned a ranked shortlist where every row is a reproducible script.</p>"""

BLOCKS = [
    ('README.md', 'en', TEMPLATE_EN),
    ('site/index.html', 'site', TEMPLATE_SITE),
]


# ----------------------------------------------------------------------------
# Scalar rules (version / test count)
# ----------------------------------------------------------------------------
# Each rule: (name, pattern with named groups pre/val/post, min_total_matches)
RULES = [
    ('version-badge', r'(?P<pre>badge/version-)(?P<val>\d+\.\d+\.\d+)(?P<post>-)', 2),
    ('version-bibtex', r'(?P<pre>version = \{)(?P<val>\d+\.\d+\.\d+)(?P<post>\})', 2),
    ('tests-count-en', r'(?P<pre>)(?P<val>\d+)(?P<post> regression tests)', 3),
    ('tests-count-site-stat',
     r'(?P<pre>data-count=")(?P<val>\d+)(?P<post>">0</b><span>regression tests)', 1),
]


def expected_for(rule_name: str, metrics: dict) -> str:
    if rule_name.startswith('version-'):
        return metrics['version']
    if rule_name.startswith('tests-'):
        return str(metrics['test_count'])
    raise AssertionError(rule_name)


def tracked_files(staging: Path):
    out = []
    for pat in ('*.md', 'docs/**/*.md', 'site/*.html'):
        out.extend(staging.glob(pat))
    seen, uniq = set(), []
    for p in out:
        rp = p.resolve()
        if rp not in seen:
            seen.add(rp)
            uniq.append(p)
    return sorted(uniq)


# ----------------------------------------------------------------------------
# Operations
# ----------------------------------------------------------------------------
def apply_rules(files, metrics, mode, problems, fixed):
    """mode='inject' rewrites values (recorded in `fixed`); mode='check' verifies."""
    for name, pattern, min_total in RULES:
        expect = expected_for(name, metrics)
        total = 0
        for f in files:
            text = f.read_text(encoding='utf-8')
            matches = list(re.finditer(pattern, text))
            if not matches:
                continue
            bad = [m.group('val') for m in matches if m.group('val') != expect]
            if bad:
                if mode == 'inject':
                    new_text = re.sub(
                        pattern,
                        lambda m: m.group('pre') + expect + m.group('post')
                        if m.group('val') != expect else m.group(0),
                        text)
                    if new_text != text:
                        f.write_text(new_text, encoding='utf-8')
                    fixed.append(f'[rule {name}] {f.name}: {sorted(set(bad))} -> {expect}')
                else:
                    problems.append(
                        f'[rule {name}] {f.name}: value {sorted(set(bad))} != {expect}')
            total += len(matches)
        if total < min_total:
            problems.append(f'[rule {name}] expected >= {min_total} matches, found {total}')


def block_pattern(tag: str):
    return re.compile(
        rf'(<!-- sync:numbers:{tag} -->\n)(.*?)(\n[ \t]*<!-- /sync:numbers:{tag} -->)',
        re.DOTALL)


def apply_blocks(staging: Path, ctx: dict, mode, problems, fixed):
    for rel, tag, template in BLOCKS:
        f = staging / rel
        pat = block_pattern(tag)
        m = pat.search(f.read_text(encoding='utf-8'))
        if not m:
            problems.append(f'[block {tag}] markers not found in {rel}')
            continue
        rendered = template.format(**ctx)
        current = m.group(2)
        if current.strip() == rendered.strip():
            continue
        if mode == 'inject':
            text = f.read_text(encoding='utf-8')
            text = pat.sub(lambda _m: _m.group(1) + rendered + _m.group(3), text, count=1)
            f.write_text(text, encoding='utf-8')
            fixed.append(f'[block {tag}] {rel} regenerated from metrics')
        else:
            cur_lines, ren_lines = current.splitlines(), rendered.splitlines()
            for i in range(max(len(cur_lines), len(ren_lines))):
                c = cur_lines[i] if i < len(cur_lines) else '<missing>'
                r = ren_lines[i] if i < len(ren_lines) else '<missing>'
                if c != r:
                    problems.append(
                        f'[block {tag}] {rel} line {i + 1} differs:\n'
                        f'    file: {c}\n    want: {r}')
                    break


def fact_scan(files, ctx, metrics, problems):
    n = ctx['n']
    allowed_ids = {f'E{i:06d}' for i in range(1, n + 1)} | {
        ctx['best_app'], ctx['qc_best'], ctx['md_best']}
    cap = metrics['capture']
    allowed_scores = {f"{s:.4f}" for s in cap.get('goalScoresBalanced', [])}
    allowed_scores |= {f"{s:.4f}" for s in cap.get('goalScoresMinDist', [])}
    allowed_scores |= {ctx['qc_score'], ctx['md_score']}
    ratio_nums = {n, ctx['legal'], ctx['n_eval'], ctx['n_front'], ctx['fails'], 3, 0}

    id_pat = re.compile(r'\bE\d{6}\b')
    score_pat = re.compile(r'(?<![\d.])0\.\d{4}(?![\d])')
    ratio_pat = re.compile(r'(\d+)\s*/\s*(\d+)')
    of_pat = re.compile(r'(\d+)\s+of\s+(\d+)')

    showcase = [f for f in files
                if f.name in ('README.md', 'index.html')]
    for f in showcase:
        text = f.read_text(encoding='utf-8')
        rel = f.name
        for m in id_pat.finditer(text):
            if m.group(0) not in allowed_ids:
                problems.append(f'[fact {rel}] unknown pipeline id {m.group(0)}')
        for m in score_pat.finditer(text):
            if m.group(0) not in allowed_scores:
                problems.append(
                    f'[fact {rel}] GoalScore-like {m.group(0)} not in metrics set '
                    f'{sorted(allowed_scores)}')
        for pat, label in ((ratio_pat, 'ratio'), (of_pat, 'of')):
            for m in pat.finditer(text):
                num, den = int(m.group(1)), int(m.group(2))
                if den == n and num not in ratio_nums:
                    problems.append(
                        f'[fact {rel}] {label} {m.group(0)}: numerator {num} '
                        f'not in {sorted(ratio_nums)}')


def asset_check(staging: Path, metrics, problems):
    recorded = metrics.get('assets', {})
    # 1) every referenced asset exists and is non-empty
    ref_pat_md = re.compile(r'docs/assets/([\w.-]+\.(?:gif|png|svg))')
    ref_pat_site = re.compile(r'(?:src|href)="assets/([\w.-]+\.(?:gif|png|svg))"')
    for f in tracked_files(staging):
        text = f.read_text(encoding='utf-8')
        names = set(ref_pat_md.findall(text))
        if f.suffix == '.html':
            names |= set(ref_pat_site.findall(text))
            sub = 'site/assets'
        else:
            sub = 'docs/assets'
        for nm in sorted(names):
            p = staging / sub / nm
            if not p.exists():
                problems.append(f'[asset] {f.name} references missing {sub}/{nm}')
            elif p.stat().st_size == 0:
                problems.append(f'[asset] {sub}/{nm} is empty')
    # 2) sizes recorded in metrics match the files (catches rebuilt-but-not-synced)
    for rel, size in recorded.items():
        p = staging / rel
        if not p.exists():
            problems.append(f'[asset] metrics lists missing {rel}')
        elif p.stat().st_size != size:
            problems.append(
                f'[asset] size drift {rel}: file {p.stat().st_size} != metrics {size} '
                f'(run sync.sh to refresh metrics)')


def verify_metrics_consistency(staging: Path, metrics, problems):
    """In --check mode the composed vs recorded values are the same source;
    nothing extra to verify here beyond schema."""
    for key in ('version', 'test_count', 'capture', 'assets'):
        if key not in metrics:
            problems.append(f'[metrics] showcase-metrics.json missing key {key}')


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def load_config_staging():
    cfg_path = SCRIPT_DIR / 'config.local.json'
    if cfg_path.exists():
        return Path(json.loads(cfg_path.read_text(encoding='utf-8'))['staging'])
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--check', action='store_true',
                    help='verify consistency from showcase-metrics.json only')
    ap.add_argument('--staging', type=Path, default=None)
    ap.add_argument('--root', type=Path, default=SOURCE_ROOT)
    ap.add_argument('--frames', type=Path, default=None)
    ap.add_argument('--test-log', type=Path, default='/tmp/neuroqc_test_latest.log')
    args = ap.parse_args(argv)

    staging = args.staging or load_config_staging()
    assert staging and staging.is_dir(), f'staging repo not found: {staging}'
    problems = []

    if args.check:
        mpath = staging / 'docs' / 'assets' / 'showcase-metrics.json'
        assert mpath.exists(), f'{mpath} not found — run sync first'
        metrics = json.loads(mpath.read_text(encoding='utf-8'))
        mode = 'check'
    else:
        frames = args.frames
        if frames is None:
            frames = Path(json.loads(
                (SCRIPT_DIR / 'config.local.json').read_text(encoding='utf-8'))['frames'])
        capture_path = frames / 'metrics_capture.json'
        assert capture_path.exists(), f'{capture_path} not found — run make_shots first'
        version = read_source_version(args.root)
        tests = read_test_count(Path(args.test_log))
        capture = json.loads(capture_path.read_text(encoding='utf-8'))
        # sanitize: drop free-text date is fine; no local paths are present
        metrics = {
            'version': version,
            'test_count': tests,
            'capture': capture,
            'assets': scan_assets(staging),
            'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        }
        mpath = staging / 'docs' / 'assets' / 'showcase-metrics.json'
        mpath.write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + '\n',
                         encoding='utf-8')
        print(f'metrics written: {mpath.relative_to(staging)} '
              f'(version={version}, tests={tests}, assets={len(metrics["assets"])})')
        mode = 'inject'

    ctx = render_context(metrics)
    files = tracked_files(staging)
    fixed = []
    verify_metrics_consistency(staging, metrics, problems)
    apply_rules(files, metrics, mode, problems, fixed)
    apply_blocks(staging, ctx, mode, problems, fixed)
    fact_scan(files, ctx, metrics, problems)
    asset_check(staging, metrics, problems)

    for item in fixed:
        print('  fixed:', item)
    if problems:
        print(f'\n{"INJECT PROBLEMS" if mode == "inject" else "DRIFT FOUND"} '
              f'({len(problems)}):')
        for p in problems:
            print('  -', p)
        return 1
    print(f'CONSISTENCY_OK ({len(files)} files, version={ctx["version"]}, '
          f'tests={ctx["tests"]}, block n={ctx["n"]} n_front={ctx["n_front"]})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
