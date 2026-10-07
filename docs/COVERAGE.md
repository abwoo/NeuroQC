# Coverage inventory

What PipeCompare covers, and how far each part has been checked. This inventory is incomplete by
nature: EEGLAB has hundreds of functions and plugins, and PipeCompare covers a deliberately small set of
them. Anything not listed here is either reachable as a **native step** (any `pop_*` command, run and
replayed verbatim, see below; in the panel through *Add EEGLAB menu step…*, which lists every
operation of EEGLAB's menus that takes and returns the dataset, plugins included) or not supported.

Each item has four status columns:

- **Impl.** — implemented.
- **Auto** — covered by an automated test in `tests/` (synthetic data with known truth).
- **Real** — run in real MATLAB R2026a + EEGLAB 2026.0.0. The automated tests run there too.
  "real data" means a run on a real recording, using a working copy.
- **Indep.** — validated independently, by someone other than the author or against an external
  reference. Nothing is marked here yet.

## Search steps (`pipecompare.plan.Catalog`)

| Step | EEGLAB call | Impl. | Auto | Real | Signal check | Notes |
|---|---|---|---|---|---|---|
| `resample` | `pop_resample` | ✓ | ✓ | ✓ real data | injection | downsampling only |
| `linenoise` | `pop_eegfiltnew` (revfilt) | ✓ | ✓ | ✓ | injection | FIR band-stop at the mains frequency detected in the recording (50/60 Hz) unless set; CleanLine/Zapline only as native steps |
| `highpass` | `pop_eegfiltnew` | ✓ | ✓ | ✓ real data | injection | |
| `lowpass` | `pop_eegfiltnew` | ✓ | ✓ | ✓ real data | injection | |
| `asr` | `pop_clean_rawdata` | ✓ | ✓ | ✓ | injection, decision-matched: the window-by-window reconstructions ASR chose on the real data are recorded and applied (`pipecompare.run.AsrRecord`, checked to reproduce EEGLAB's output exactly; otherwise re-run and flagged) | needs clean_rawdata (and the Signal Processing Toolbox at rates without a precomputed ASR filter); Euclidean ASR, burst correction only |
| `badchannels` | `pop_rejchan` (+ `pop_interp`) | ✓ | ✓ | ✓ | injection, matched | |
| `channels` | `pop_select` / `pop_interp` | ✓ | ✓ | ✓ real data | injection, matched | interpolation needs channel locations |
| `restore` | `pop_interp` | ✓ | ✓ | ✓ | injection, matched | |
| `reref` | `pop_reref` (incl. `exclude`) | ✓ | ✓ | ✓ real data | injection, expected field re-referenced | measure-defining → strata |
| `ica` | `pop_runica` (extended, `rndreset no`) | ✓ | ✓ | ✓ | injection, matched (same matrices) | optional fit on a high-passed copy |
| `icremove` | `pop_iclabel` + `pop_icflag` + `pop_subcomp` | ✓ | ✓ (identity-ICA check) | ✓ | injection, matched (same components) | needs ICLabel; integer srate enforced |
| `epoch` | `pop_epoch` | ✓ | ✓ | ✓ real data (time-locking checked) | — | windows from the contract |
| `baseline` | `pop_rmbase` | ✓ | ✓ | ✓ real data | — | window from the contract |
| `reject_threshold` | `pop_eegthresh` + `pop_rejepoch` | ✓ | ✓ | ✓ real data | injection, matched | rejecting every epoch = retention 0; `interpolate` = n repairs epochs with at most n flagged channels (spherical interpolation within the epoch, replayed on the signal copy) |
| `reject_jointprob` | `pop_jointprob` + `pop_rejepoch` | ✓ | ✓ | ✓ | injection, matched | `interpolate` as for `reject_threshold` (channels over the per-channel limit) |
| `reject_kurtosis` | `pop_rejkurt` + `pop_rejepoch` | ✓ | ✓ | ✓ | injection, matched | `interpolate` as for `reject_threshold` |
| `native` | any `pop_*` command, or a captured EEGLAB workflow (one statement per line) | ✓ | ✓ | ✓ | fixed transforms (filters, resampling, reference, baseline, epoching, channel lists): injection, same operation; workflows of marks + removals (`pop_eegthresh`/`pop_jointprob`/`pop_rejkurt` → `pop_rejepoch`, `pop_iclabel` → `pop_icflag` → `pop_subcomp`): injection, decision-matched (the removed epochs/components are replayed); otherwise injection, re-run (flagged) | each configuration is fixed; several configurations of one step (and skipping it) can be searched as alternatives |

## History parsing (`pipecompare.live.History`)

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Order kept, no deduplication, repeated steps distinct | ✓ | ✓ | ✓ real history |
| Char-matrix and cell histories, `;`-separated statements, `...` continuations | ✓ | ✓ | ✓ |
| Classification: load / save / view / channel edit / select / events / resample / filters / line noise / ASR / channel rejection / continuous rejection / reref / ICA / IC removal / IC flagging / interpolation / epoch / baseline / epoch rejection | ✓ | partly | ✓ real history |
| Provenance labels: recorded in the history / executed by PipeCompare / session (ALLCOM) only / inferred from data / cannot be verified | ✓ | ✓ | ✓ |
| Filter parameters parsed: `pop_eegfiltnew` only | ✓ | ✓ | ✓ |
| Other filter functions (`pop_firws`, `pop_basicfilter`, `pop_iirfilt`, …) | recognised, parameters not parsed | — | — |

## Measures and ranking

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Mean amplitude, analytic SME | ✓ | ✓ (vs. empirical SD) | ✓ real data |
| Gain-corrected objective (SME / signal gain) | ✓ | ✓ (invariance to scaling) | ✓ real data |
| Simple mode `pop_pipecompare`: ERP CORE presets, recipes adapted to the data, live count, result window | ✓ | ✓ (presets against the paper's tables; dialog; script call; window) | manual (MANUAL_GUI_CHECK 19–23) |
| Band power of continuous data: segments (eeg_regepochs), log band power SME, sinusoid signal check, moving-block bootstrap | ✓ | ✓ (end to end; error rate with AR(1) segments) | — |
| Peak amplitude / latency, bootstrapped SME | ✓ | ✓ (vs. replications) | ✓ synthetic |
| Composite objective or one chosen measure; unit safety | ✓ | ✓ | ✓ |
| Paired bootstrap, simultaneous not-distinguished set, α = 0.02 calibration (2-24 candidates) | ✓ | ✓ (simulation) | ✓ |
| Strata (reference) | ✓ | ✓ | ✓ |
| Constraints with reasons; "no feasible pipeline" with reason summary | ✓ | ✓ | ✓ real data |
| Trial rules (time ranges, marker ranges, urevents) | ✓ | ✓ (time ranges) | ✓ |

## Execution and integration

| Item | Impl. | Auto | Real |
|---|---|---|---|
| Live dataset detection, unstored-change warning, dataset switch/removal | ✓ | ✓ | ✓ |
| Source dataset and file never modified | ✓ | ✓ | ✓ real data |
| Prefix sharing equals independent runs | ✓ | ✓ (with ICA) | ✓ |
| Exhaustive enumeration equals brute force; illegal orders explained | ✓ | ✓ | ✓ |
| Checkpoint and resume equal an uninterrupted run | ✓ | ✓ | ✓ |
| Parallel equals serial | ✓ | ✓ | ✓ (local pool) |
| V → µV conversion, srate residue rounding (recorded) | ✓ | ✓ | ✓ real data (srate) |
| Adopt: new dataset, history replays to identical scores; stale-start guard | ✓ | ✓ | ✓ |
| `writeScript` reproduces a candidate | ✓ | ✓ | ✓ |
| *Apply now* through EEGLAB's own code path (history, ALLCOM) | ✓ | ✓ | ✓ |
| *Configure in EEGLAB* (capture of the dialog's command) | ✓ | ✓ (command capture) | opening the dialog itself: manual check pending |
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
