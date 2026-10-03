# Coverage inventory

What NeuroQC 0.7 covers, and how far each part has been checked. This inventory is incomplete by
nature: EEGLAB has hundreds of functions and plugins, and NeuroQC covers a deliberately small set of
them. Anything not listed here is either reachable as a **native step** (any `pop_*` command, run and
replayed verbatim, see below) or not supported.

Each item has four status columns:

- **Impl.** — implemented.
- **Auto** — covered by an automated test in `tests/` (synthetic data with known truth).
- **Real** — run in real MATLAB R2026a + EEGLAB 2026.0.0. The automated tests run there too.
  "real data" means a run on a real recording, using a working copy.
- **Indep.** — validated independently, by someone other than the author or against an external
  reference. Nothing is marked here yet.

## Search steps (`neuroqc.plan.Catalog`)

| Step | EEGLAB call | Impl. | Auto | Real | Signal check | Notes |
|---|---|---|---|---|---|---|
| `resample` | `pop_resample` | ✓ | ✓ | ✓ real data | probe | downsampling only |
| `linenoise` | `pop_eegfiltnew` (revfilt) | ✓ | ✓ | ✓ | probe | FIR band-stop; CleanLine/Zapline only as native steps |
| `highpass` | `pop_eegfiltnew` | ✓ | ✓ | ✓ real data | probe | |
| `lowpass` | `pop_eegfiltnew` | ✓ | ✓ | ✓ real data | probe | |
| `asr` | `pop_clean_rawdata` | ✓ | ✓ | ✓ | injection, re-run (flagged) | needs clean_rawdata; not decision-matched |
| `badchannels` | `pop_rejchan` (+ `pop_interp`) | ✓ | ✓ | ✓ | injection, matched | |
| `channels` | `pop_select` / `pop_interp` | ✓ | ✓ | ✓ real data | injection, matched | interpolation needs channel locations |
| `restore` | `pop_interp` | ✓ | ✓ | ✓ | injection, matched | |
| `reref` | `pop_reref` (incl. `exclude`) | ✓ | ✓ | ✓ real data | injection, expected field re-referenced | measure-defining → strata |
| `ica` | `pop_runica` (extended, `rndreset no`) | ✓ | ✓ | ✓ | injection, matched (same matrices) | optional fit on a high-passed copy |
| `icremove` | `pop_iclabel` + `pop_icflag` + `pop_subcomp` | ✓ | ✓ (identity-ICA check) | ✓ | injection, matched (same components) | needs ICLabel; integer srate enforced |
| `epoch` | `pop_epoch` | ✓ | ✓ | ✓ real data (time-locking checked) | — | windows from the contract |
| `baseline` | `pop_rmbase` | ✓ | ✓ | ✓ real data | — | window from the contract |
| `reject_threshold` | `pop_eegthresh` + `pop_rejepoch` | ✓ | ✓ | ✓ real data | injection, matched | rejecting every epoch = retention 0 |
| `reject_jointprob` | `pop_jointprob` + `pop_rejepoch` | ✓ | ✓ | ✓ | injection, matched | |
| `reject_kurtosis` | `pop_rejkurt` + `pop_rejepoch` | ✓ | ✓ | ✓ | injection, matched | |
| `native` | any `pop_*` command, or a captured EEGLAB workflow (one statement per line) | ✓ | ✓ | ✓ | probe for `pop_eegfiltnew`/`pop_resample`; workflows of marks + removals (`pop_eegthresh`/`pop_jointprob`/`pop_rejkurt` → `pop_rejepoch`, `pop_iclabel` → `pop_icflag` → `pop_subcomp`): injection, decision-matched (the removed epochs/components are replayed); otherwise injection, re-run (flagged) | each configuration is fixed; several configurations of one step (and skipping it) can be searched as alternatives |

## History parsing (`neuroqc.live.History`)

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Order kept, no deduplication, repeated steps distinct | ✓ | ✓ | ✓ real history |
| Char-matrix and cell histories, `;`-separated statements, `...` continuations | ✓ | ✓ | ✓ |
| Classification: load / save / view / channel edit / select / events / resample / filters / line noise / ASR / channel rejection / continuous rejection / reref / ICA / IC removal / IC flagging / interpolation / epoch / baseline / epoch rejection | ✓ | partly | ✓ real history |
| Provenance labels: recorded in the history / executed by NeuroQC / session (ALLCOM) only / inferred from data / cannot be verified | ✓ | ✓ | ✓ |
| Filter parameters parsed: `pop_eegfiltnew` only | ✓ | ✓ | ✓ |
| Other filter functions (`pop_firws`, `pop_basicfilter`, `pop_iirfilt`, …) | recognised, parameters not parsed | — | — |

## Measures and ranking

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Mean amplitude, analytic SME | ✓ | ✓ (vs. empirical SD) | ✓ real data |
| Peak amplitude / latency, bootstrapped SME | ✓ | ✓ (vs. replications) | ✓ synthetic |
| Log band power (continuous segments or event-related) | ✓ | ✓ | ✓ synthetic |
| Composite / priority / Pareto objectives; unit safety | ✓ | ✓ | ✓ |
| Paired bootstrap, not-distinguished set, α = 0.02 calibration | ✓ | ✓ (simulation) | ✓ |
| Equivalence with a margin (TOST, 90% interval) | ✓ | ✓ (simulation) | ✓ |
| probBest, Bonferroni option, strata | ✓ | ✓ | ✓ |
| Constraints with reasons; "no feasible pipeline" with reason summary | ✓ | ✓ | ✓ real data |
| External QC columns and limits | ✓ | ✓ | ✓ |
| Trial rules (time ranges, marker ranges, urevents) | ✓ | ✓ (time ranges) | ✓ |

## Execution and integration

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Live dataset detection, unstored-change warning, dataset switch/removal | ✓ | ✓ | ✓ |
| Source dataset and file never modified | ✓ | ✓ | ✓ real data |
| Prefix sharing equals independent runs | ✓ | ✓ (with ICA) | ✓ |
| Exhaustive enumeration equals brute force; illegal orders explained | ✓ | ✓ | ✓ |
| Seeded sampling, labelled approximate | ✓ | ✓ | ✓ |
| Checkpoint and resume equal an uninterrupted run | ✓ | ✓ | ✓ |
| Parallel equals serial | ✓ | ✓ | ✓ (local pool) |
| V → µV conversion, srate residue rounding (recorded) | ✓ | ✓ | ✓ real data (srate) |
| Adopt: new dataset, history replays to identical scores; stale-start guard | ✓ | ✓ | ✓ |
| `writeScript` reproduces a candidate | ✓ | ✓ | ✓ |
| *Apply now* through EEGLAB's own code path (history, ALLCOM) | ✓ | ✓ | ✓ |
| *Fix via EEGLAB dialog* (capture of the dialog's command) | ✓ | ✓ (command capture) | opening the dialog itself: manual check pending |
| Panel: live history, plan editing, run, results, latency objective | ✓ | ✓ | ✓ |
| Command Window: commands shown, EEGLAB progress chatter filtered | ✓ | ✓ | ✓ |

## Not covered

- STUDY-level processing, and commands that reference `ALLEEG(n)` or `STUDY`. Native steps that use
  them are refused.
- AMICA, other ICA algorithms, and IC classifiers other than ICLabel. These are possible as native
  steps, but their decisions are not replayed on the injected copy.
- Time-frequency measures, connectivity, source localization.
- Searching the analysis contract (events, windows, ROIs). This is deliberate: the contract defines
  the measured quantity.
- Independent validation by a second party.
