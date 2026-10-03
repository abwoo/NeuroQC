# Review of NeuroQC 0.6 and what 0.7 changes

This file records the problems found in 0.6 and how 0.7 resolves each one. The 0.6 code is still in
git history (branch `main`).

## 1. Evaluation metrics

| 0.6 problem | Consequence | 0.7 |
|---|---|---|
| `waveformDistortion` = relative L2 distance between candidate and **unprocessed** handoff averages | Removing drift or blinks, or re-referencing, counted as "distortion". Average-reference candidates could fail the 0.5 hard gate. The ranking favoured pipelines that do little. | Removed. Distortion is measured where it has a ground truth: a noise-free synthetic waveform passed through the candidate's exact filter calls (`eval.FilterProbe`). |
| Split-half `reliability` / `topoStability` computed **without baseline correction** | With a multi-channel ROI, per-channel DC offsets are shared by both halves. Pure noise then scored reliability 0.999 and topoStability 1.000, against 0.055 and 0.001 without offsets. A single-channel ROI is unaffected. | Replaced by SME of the scored measure (`eval.Measure`), computed after the contract baseline. |
| `filterGuard` gate in `HardConstraints` never computed by any code | Nothing stopped over-filtering, which every noise metric rewards | Filter probe limits are enforced constraints (amplitude error, peak shift, artifactual deflection). |
| Reference was searchable and ranked by the same metrics | Changing the reference changes the measured signal, so scores aren't comparable | Searchable, but candidates that differ in it are ranked in separate strata and never compared with each other. Epoch, baseline and ROI windows come from the contract. |
| Distortion of data-driven steps (ICA removal, interpolation, rejection) was not measured | A step could remove the effect along with the noise and still rank first | Matched-decision injection (`eval.Injection`): a copy holding only a known signal gets the same channel/ICA/component/epoch decisions; amplitude, latency, waveform and topography are compared with the truth. |

## 2. Ranking

| 0.6 problem | 0.7 |
|---|---|
| Min-max normalisation within the current front stretched trivial differences (e.g. retention 0.995 vs 0.996) to the full range. The best candidate could change when an unrelated candidate was added. | No normalisation: a single physical criterion (composite SME, µV) after explicit constraints. |
| Measurement noise was ignored, so "#1" was often a statistical tie | Paired bootstrap over trials (`urevent` identity). Candidates are reported as *tied with best* or *worse*, with intervals. |
| 5-objective Pareto front kept almost everything (6 of 8 in the demo) | Constraints with stated reasons; the not-distinguished set is followed by a parsimony rule (most trials kept, then least distortion). A Pareto set is still available (`objective = 'pareto'`) for objectives in different units, and then names no single winner unless it is unique. |
| "Tied" was easy to read as "equivalent" | Renamed *not distinguished*. Equivalence is claimed only with an explicit margin (two one-sided tests on the 90% interval). |
| Per-objective weights (GoalProfile) let a weighting choice silently decide the result | Removed. The trade-off between noise and trial count is carried by SME itself. |

## 3. Search and execution

| 0.6 problem | 0.7 |
|---|---|
| Every candidate ran from scratch (ICA recomputed per combination) | Prefix-tree execution: shared prefixes run once. The report shows step counts with and without sharing. |
| ICA fitted on 0.1 Hz data when that was searched | `ica.fitHighpass` (default 1 Hz): fit on a high-passed copy, weights applied to the data as they are. |
| Recipes called `pop_*` without `eegh`, so adopted datasets had no history of their steps | Every command is appended to the candidate's `EEG.history`. Adopt replays through `eegh` (ALLCOM too) and checks the replay gives the identical SME. |
| `pop_eegthresh(...,reject=1)` records `reject=0` in its own command | Marking and `pop_rejepoch` with explicit indices are recorded separately, so the history reproduces the rejection. |
| Full SHA-256 of the data computed on every generate/compare and inside every recipe (measured 0.18 s per 77 MB, so about 2–3 s per 1 GB dataset per call: minor) | Removed; a cheap fingerprint detects live changes. |

## 4. History

0.6 parsed `EEG.history` into a deduplicated **set**. A real dataset run through this pipeline shows
why that is wrong:

- **Repeated steps are lost.** That history contains `pop_reref` twice and `pop_runica` twice (the
  second after `pop_subcomp`). The set said "ICA done, ICs removed", but the actual state was an
  unpruned second decomposition.
- **Some removals aren't in the history at all.** `pop_subcomp(EEG, [], 0)` removes components that
  were flagged interactively. Their indices live only in `EEG.reject.gcompreject`.
- **Commands were mislabelled.**
  - `pop_select rmchannel` is channel removal, not "select data".
  - `pop_interp(EEG, ALLEEG(5).chanlocs, …)` restores a montage from another dataset, so it can't be
    reproduced from the history alone.

0.7 (`live.History`, `live.DataState`):

- It keeps every statement in order, splits `figure; pop_spectopo(...)`, and handles char-matrix
  and cell histories.
- It reads the current state from the EEG structure and uses the history for provenance and
  parameters.
- It reports every place where the two disagree, or where the history cannot describe the data.

## 5. Redundancy removed

- **Six overlapping fixing mechanisms are now one rule:** a single value is fixed, a `{list}` is
  searched, and a parameter you don't mention is searched over its suggestions. The six were:
  - `stepModes`
  - `lockSpec`
  - `frozen`
  - `completedStages` + `prefix`/`set` + `startAfter`
  - `stepOrder` / `fixedPositions`
  - `fullWorkflow`
- **Order** is the order you list steps. `OrderMode='search'` tries every order, refined by
  `pin` and `before`.
- **Snapshot management is gone**, because NeuroQC is bound to the live EEGLAB dataset. This removed
  the Load button, Options JSON, the session save/open, the "confirm input settings" and drift gates,
  CheckpointDialog and the recipe-file machinery. Resume, parallel execution, sampling, external QC,
  trial rules and V/µV conversion were later restored in a simpler form (section 8).
- **Dead or test-only modules were deleted:**
  - `+qc`, `+preserve`, `+erp`
  - `PreprocessingMVP`, `ResumeOptimizer`, `Sensitivity`, `extractHP`
  - the duplicate plugin file
- The 3,239-line GUI was replaced by a ~400-line panel.

## 6. Command Window and EEGLAB integration

- Every step, every EEGLAB command, every score and every exclusion reason is printed in the Command
  Window.
- The plugin keeps EEGLAB's own `try_strings` / `catch_strings`. *Apply now in EEGLAB* therefore goes
  through exactly the code path EEGLAB menus use: history, ALLCOM, new dataset, redraw.
- *Fix via EEGLAB dialog* captures the native dialog's command as a fixed step.

## 7. Evidence

### The 0.6 suite passes, but does not test validity

All 252 tests of the 0.6 suite (`NeuroQC-gh-tests`) pass on `main`. They check the code against its
own definitions. `tests/v06_reproductions.m` checks 0.6 against external criteria instead. Run it with
the 0.6 package on the path. Every check except the informational R7 fails on 0.6, which is the
reproduction:

| # | Criterion | 0.6 result |
|---|---|---|
| R1 | Average reference is not distortion | `waveformDistortion` 0.950 (gate 0.5): rejected |
| R2 | Pure noise has no reliability (4-channel ROI) | reliability 0.055 → 0.999, topoStability 0.001 → 1.000 once channel offsets are added |
| R3 | 0.1 Hz HP acceptable, 2 Hz HP not | both rejected (distortion 0.964 / 0.971 vs raw); reliability 0.491 vs 0.490 cannot separate them; `filterGuard` never computed |
| R4 | A-vs-B decision independent of a third candidate | best = A with C present, B with D present |
| R5 | History keeps repeated steps | `reref > run_ica > auto_ic_remove` (second reref and second ICA lost) |
| R6 | Candidate history contains its steps | nothing added |
| R7 | (informational) hash cost | 0.18 s per 77 MB |

### Validation of 0.7 (`tests/run_all.m`: history, plan, statistics, signal, engine, eeglab)

All tests pass in MATLAB R2026a Update 5 + EEGLAB 2026.0.0 (the README states the current count).

- **SME is what it claims.** Over 4000 simulated replications it matches the empirical SD of the
  trial mean within 5%. The bootstrapped SME of a peak latency matches the SD of that latency across
  300 independent replications (25.4 vs 22.1 ms; tolerance 20%).
- **Not-distinguished criterion calibration.** Two candidates with truly equal noise, 400
  simulations, post-selection false "worse" rate:

  | trials | α = 0.05 | α = 0.02 |
  |---|---|---|
  | 20 | 8.0% | 5.2% |
  | 40 | 7.7% | 3.0% |
  | 100 | 5.2% | 2.5% |

  The default is therefore α = 0.02. In the test run (100 trials, 150 simulations): false "worse"
  rate 4.7%, power to detect 1.4× noise 85%.
- **Equivalence needs a margin and evidence.** With a margin of 0.25 SME and 200 trials, equivalence
  was claimed in 100% of equal-noise simulations and 0% when one candidate had 1.6× the noise.
  Without a margin it is never claimed.
- **Ranking does not depend on other candidates**, identical candidates share `probBest`, strata are
  never compared, priority objectives are lexicographic, and composites of different units are
  refused.
- **The filter probe behaves monotonically.** High-pass amplitude error by cutoff:

  | cutoff | 0.05 Hz | 0.1 Hz | 0.3 Hz | 0.5 Hz | 1 Hz | 2 Hz |
  |---|---|---|---|---|---|---|
  | amplitude error | 0.00003 | 0.0002 | 0.006 | 0.027 | 0.166 | 0.56 |

  The error falls as the low-pass edge rises, and resampling alone changes nothing. A 9 Hz low-pass
  is rejected for an alpha (8–12 Hz) objective; 30 Hz is not.
- **Injection detects real damage and ignores non-damage.**
  - Average re-referencing, with or without excluded channels: amplitude error < 2%.
  - Removing the component that carries the signal: error > 90%; removing an unrelated one: < 1%.
  - Interpolating the ROI's peak channel: 28% (spherical splines underestimate a focal peak), with
    the topography still recovered (r = 0.98).
  - Epoch rejection: no distortion.
  - A 2 Hz high-pass: agrees with the probe within 0.03.
  - Overlapping epochs are expected, not read as distortion.
- **Enumeration is exhaustive** (equals an independent brute force); sampling is seeded,
  reproducible, without duplicates and labelled approximate.
- **Execution invariants.** Prefix sharing equals independent runs (with ICA). Resume after an
  interruption equals an uninterrupted run. Parallel equals serial. The source dataset is never
  modified. Every catalog step runs through EEGLAB and is recorded; ASR is flagged as re-run.
- **The synthetic end-to-end run picks the right pipeline.** The 2 Hz high-pass is rejected although
  its SME is the lowest. The 75 µV rejection is recommended over none when 15% of trials carry
  movement artifacts. Adopt creates a new EEGLAB dataset whose history replays to identical scores;
  adopt refuses when the starting dataset is gone unless forced.
- **EEGLAB integration.** Live detection follows base `EEG`, warns when it is not stored, and follows
  dataset switches and deletion. "Apply now" goes through EEGLAB's try/catch + `eeglab_new`, so the
  command lands in `EEG.history` and ALLCOM. Captured dialog commands become fixed native steps. The
  panel follows changes made outside it and runs searches, including a latency objective.

### Real dataset (66 ch, 1000 Hz, 69 min, continuous; working copy only)

`tests/realdata_validation.m`, with a *technical* contract (the two most frequent event codes, a
300–500 ms window at Pz/P3/P4/POz). This exercises the machinery; it is not a scientific analysis.

- The original file is unchanged after the run (timestamp and size checked).
- The `srate = 1000 + 1e-13` EDF residue is detected, rounded on NeuroQC's copy and recorded.
- 12 pipelines (2 high-pass × O1/O2 keep/remove/interpolate × 2 thresholds, average reference with
  EOG excluded) run in 23–28 s. Every epoch of the replayed candidate is time-locked at 0 ms to the
  right event.
- **Defect found and fixed.** All candidates were first rejected for "20% amplitude change". The
  cause: 179 of 618 event gaps are shorter than the epoch, so neighbouring injected responses fall
  inside each epoch. The expected average now includes every injected onset in the epoch, and the
  errors drop to 0–3%.
- **Data findings.**
  - The file has no channel locations, so interpolation candidates fail with that reason.
  - Codes 80 and 222 sometimes occur 3 ms apart (double-coded triggers).
  - Keeping O1/O2 lowers retention to 15–44%.
  - Removing them gives 3 feasible candidates; the recommendation is 0.5 Hz high-pass with O1/O2
    removed and the 100 µV threshold. 0.5 Hz with 150 µV is distinguishable from it (98% interval of
    the SME difference: +0.004 to +0.112).
- **Profile** (12 candidates, 27.7 s): EEGLAB `firfilt` 23 s (on data and the injected copy) and
  `pop_resample` 9 s, out of 45 s including the replay check; NeuroQC's own bookkeeping is
  negligible.
- An earlier run with ICA (two ICAs shared across 6 pipelines each) took 18 min, dominated by
  `runica`.

## 8. 0.6 features: removed, then restored in 0.7

| 0.6 feature | Status in 0.7 |
|---|---|
| Resume an interrupted comparison | **Restored.** `opts.checkpoint` saves every candidate atomically; `NeuroQC.resume(dir)` continues and is tested to equal an uninterrupted run. |
| Parallel evaluation (`parfor`) | **Restored.** `opts.parallel`: shared trunk serially, independent subtrees on the pool; tested to equal serial. |
| Random subset when the grid is too large | **Restored, labelled.** `searchMode = 'sample'` draws a seeded sample of legal pipelines, reports the estimated legal total, and prints that the result is not a proven optimum. Exhaustive mode still refuses above `maxLeaves`. |
| GoalProfile weights / Pareto front | Weights stay removed (section 2). Priority objectives and `objective = 'pareto'` replace them. |
| External QC import (CSV/JSON) | **Restored as columns and limits.** `opts.externalQC` (table or CSV with `key`) is joined to candidates, and `externalLimits` can exclude them; it never invents scores for unevaluated candidates. |
| Formal trial rules (`TrialSelector`) | **Restored.** `Contract.trials`: time ranges, marker ranges or urevent lists. |
| V/µV declaration and conversion | **Restored.** `opts.dataUnit = 'V'` converts NeuroQC's copy (and ICA weights) and records it. |
| Recipe `.m` files | **Restored.** `NeuroQC.writeScript(r, id, file)` writes a runnable function; tested to reproduce the candidate's scores. |
