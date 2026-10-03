#!/usr/bin/env python3
"""Showcase sync injector / consistency checker for the NeuroQC public repo.

Subcommands (default: sync):

  sync      Compose showcase-metrics.json from the source repo (code version,
            test log of tests/run_all.m, tools/showcase_capture.m output, asset
            sizes) and rewrite every tracked spot: version badges/citations,
            test counts, and the marked numbers blocks.
  --check   Read ONLY docs/assets/showcase-metrics.json (no source repo
            needed — runs in GitHub Actions) and verify:
              1. version spots (badges, bibtex) == metrics.version
              2. test-count spots (trust bars, og, stat) == metrics.test_count
              3. marked numbers blocks == template rendered from metrics
              4. fact scan: candidate numbers and "x of n" ratios seen in
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
SOURCE_ROOT = SCRIPT_DIR.parent  # <repo>/tools/inject.py


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
    assert log.exists(), f'test log not found: {log} (run tests/run_all.m with a diary first)'
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
def render_context(metrics: dict) -> dict:
    cap = metrics['capture']
    n = int(cap['nPipelines'])
    return {
        'version': metrics['version'],
        'tests': int(metrics['test_count']),
        'dataset': cap['dataset'],
        'grid': cap['grid'],
        'n': n,
        'illegal': int(cap['nIllegal']),
        'nodes': int(cap['nNodes']),
        'unshared': int(cap['nStepsUnshared']),
        'signal': cap['signalCheck'],
        'feasible': int(cap['nFeasible']),
        'rejected': int(cap['nRejected']),
        'rej_dist': int(cap['nRejectedDistortion']),
        'failed': int(cap['nFailed']),
        'best': int(cap['bestId']),
        'rec': int(cap['recommendedId']),
        'nd': int(cap['nNotDistinguished']),
        'rec_label': cap['recommendedLabel'],
    }


SIGNAL_TEXT = {
    'probe': 'filter probe (a known waveform through the same EEGLAB filter calls)',
    'injection': 'matched-decision injection (a known signal carried through every candidate)',
}

TEMPLATE_EN = """\
| Stage | Result |
|---|---|
| **Plan** | {grid} → **{n} pipelines**, {illegal} illegal combinations excluded |
| **Execution** | prefix tree: **{nodes} EEGLAB step runs** instead of {unshared} |
| **Signal check** | {signal_text}: **{rej_dist} of {n}** rejected for distorting the known signal |
| **Constraints** | **{feasible} of {n} feasible**, {rejected} rejected, {failed} failed — every exclusion listed with its reason |
| **Ranking** | best SME: candidate **#{best}**; **{nd} of {n}** not distinguished from it by these data |
| **Recommendation** | candidate **#{rec}** (most trials kept among those): `{rec_label}` |"""

TEMPLATE_SITE = """\
    <div class="tblbox">
      <table>
        <tr><th>Stage</th><th>Result</th></tr>
        <tr><td><b>Plan</b></td><td>{grid} → <b>{n} pipelines</b>, {illegal} illegal combinations excluded</td></tr>
        <tr><td><b>Execution</b></td><td>prefix tree: <b>{nodes} EEGLAB step runs</b> instead of {unshared}</td></tr>
        <tr><td><b>Signal check</b></td><td>{signal_text}: <b>{rej_dist} of {n}</b> rejected for distorting the known signal</td></tr>
        <tr><td><b>Constraints</b></td><td><b>{feasible} of {n} feasible</b>, {rejected} rejected, {failed} failed — every exclusion listed with its reason</td></tr>
        <tr><td><b>Ranking</b></td><td>best SME: candidate <b>#{best}</b>; <b>{nd} of {n}</b> not distinguished from it by these data</td></tr>
        <tr><td><b>Recommendation</b></td><td>candidate <b>#{rec}</b> (most trials kept among those): <code>{rec_label}</code></td></tr>
      </table>
    </div>"""

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
    ('tests-count-en', r'(?P<pre>)(?P<val>\d+)(?P<post> automated tests)', 3),
    ('tests-count-site-stat',
     r'(?P<pre>data-count=")(?P<val>\d+)(?P<post>">0</b><span>automated tests)', 1),
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
        rendered = template.format(signal_text=SIGNAL_TEXT.get(ctx['signal'], ctx['signal']), **ctx)
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
    allowed_ids = {ctx['best'], ctx['rec']}
    ratio_nums = {n, ctx['feasible'], ctx['rejected'], ctx['failed'], ctx['rej_dist'], ctx['nd']}
    id_pat = re.compile(r'(?:candidate\s+(?:<b>)?\*{0,2}#|candidate\s+)(\d+)')
    of_pat = re.compile(r'(\d+)\s+of\s+(\d+)')
    showcase = [f for f in files if f.name in ('README.md', 'index.html')]
    for f in showcase:
        text = f.read_text(encoding='utf-8')
        for m in re.finditer(r'<!-- sync:numbers:\w+ -->(.*?)<!-- /sync:numbers:\w+ -->', text, re.DOTALL):
            block = m.group(1)
            for i in id_pat.finditer(block):
                if int(i.group(1)) not in allowed_ids:
                    problems.append(f'[fact {f.name}] candidate {i.group(1)} not in metrics {sorted(allowed_ids)}')
        for m in of_pat.finditer(text):
            num, den = int(m.group(1)), int(m.group(2))
            if den == n and num not in ratio_nums:
                problems.append(f'[fact {f.name}] "{m.group(0)}": numerator {num} not in {sorted(ratio_nums)}')


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
    ap.add_argument('--capture', type=Path, default=None,
                    help='metrics_capture.json written by tools/showcase_capture.m')
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
        capture_path = args.capture
        assert capture_path and capture_path.exists(), \
            f'{capture_path} not found — run tools/showcase_capture.m first'
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
          f'tests={ctx["tests"]}, block n={ctx["n"]} feasible={ctx["feasible"]})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
