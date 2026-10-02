# Review of NeuroQC 0.6 and what 0.7 changes

This file records the problems found in 0.6 and how 0.7 resolves each one. The 0.6 code is still in
git history (branch `main`).

## 1. Evaluation metrics

| 0.6 problem | Consequence | 0.7 |
|---|---|---|
| `waveformDistortion` = relative L2 distance between candidate and **unprocessed** handoff averages | Removing drift or blinks, or re-referencing, counted as "distortion". Average-reference candidates could fail the 0.5 hard gate. The ranking favoured pipelines that do little. | Removed. Distortion is measured where it has a ground truth: a noise-free synthetic waveform passed through the candidate's exact filter calls (`eval.FilterProbe`). |
| Split-half `reliability` / `topoStability` computed **without baseline correction** | With a multi-channel ROI, per-channel DC offsets are shared by both halves. Pure noise then scored reliability 0.999 and topoStability 1.000, against 0.055 and 0.001 without offsets. A single-channel ROI is unaffected. | Replaced by SME of the scored measure (`eval.Measure`), computed after the contract baseline. |
| `filterGuard` gate in `HardConstraints` never computed by any code | Nothing stopped over-filtering, which every noise metric rewards | Filter probe limits are enforced constraints (amplitude error, peak shift, artifactual deflection). |
| Reference was searchable and ranked by the same metrics | Changing the reference changes the measured signal, so scores aren't comparable | Must be fixed (`NeuroQC:MustFix`). Epoch, baseline and ROI windows come from the contract. |

## 2. Ranking

| 0.6 problem | 0.7 |
|---|---|
| Min-max normalisation within the current front stretched trivial differences (e.g. retention 0.995 vs 0.996) to the full range. The best candidate could change when an unrelated candidate was added. | No normalisation: a single physical criterion (composite SME, µV) after explicit constraints. |
| Measurement noise was ignored, so "#1" was often a statistical tie | Paired bootstrap over trials (`urevent` identity). Candidates are reported as *tied with best* or *worse*, with intervals. |
| 5-objective Pareto front kept almost everything (6 of 8 in the demo) | Constraints with stated reasons; the tie set is followed by a parsimony rule (most trials kept, then least distortion). |
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
  the data-unit declaration, CheckpointDialog and the recipe-file machinery.
- **Dead or test-only modules were deleted:**
  - `+qc`, `+preserve`, `+erp`
  - `PreprocessingMVP`, `ResumeOptimizer`, `Sensitivity`, `extractHP`
  - external QC import
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

### Validation of 0.7 (`tests/test_neuroqc.m`, 27 tests, all pass in MATLAB R2026a + EEGLAB 2026.0.0)

- **SME is what it claims.** Over 4000 simulated replications it matches the empirical SD of the
  trial mean within 5%.
- **Tie criterion calibration.** Two candidates with truly equal noise, 400 simulations, false
  "worse" rate:

  | trials | α = 0.05 | α = 0.02 |
  |---|---|---|
  | 20 | 8.0% | 5.2% |
  | 40 | 7.7% | 3.0% |
  | 100 | 5.2% | 2.5% |

  The default is therefore α = 0.02. Power to detect 1.4× noise at 100 trials is 92%.
- **Ranking does not depend on other candidates.** Adding a third candidate changes neither the
  scores nor the A/B decision.
- **Channel offsets do not change the scores.**
- **The filter probe behaves monotonically.** High-pass amplitude error by cutoff:

  | cutoff | 0.05 Hz | 0.1 Hz | 0.3 Hz | 0.5 Hz | 1 Hz | 2 Hz |
  |---|---|---|---|---|---|---|
  | amplitude error | 0.00003 | 0.0002 | 0.006 | 0.027 | 0.166 | 0.56 |

  The error falls as the low-pass edge rises, and resampling alone changes nothing.
- **Enumeration is exhaustive.** It equals an independent brute force (all permutations × all
  values).
- **Prefix sharing does not change results.** Every candidate's SME and command history equal those
  of running that pipeline alone.
- **The synthetic end-to-end run picks the right pipeline.**
  - The 2 Hz high-pass is rejected by the probe, although its SME is the lowest.
  - The 75 µV rejection is recommended over none when 15% of trials carry movement artifacts.
  - Adopt creates a new EEGLAB dataset whose history replays to an identical SME.
- **EEGLAB integration.**
  - Live detection follows base `EEG` and warns when it is not stored.
  - "Apply now" goes through EEGLAB's try/catch + `eeglab_new`, so the command lands in
    `EEG.history` and ALLCOM.
  - Captured dialog commands become fixed native steps.
  - The panel follows a change made to the dataset outside it.

### Real dataset (66 ch, 1000 Hz, 69 min, continuous)

- A 12-pipeline search without ICA takes 18 s. With ICA (two ICAs, shared across 6 pipelines each)
  it takes 18 min.
- Two real-data defects were found and fixed:
  - The EDF import left `srate = 1000 + 1e-13`, which ICLabel rejects. NeuroQC now rounds it on its
    own copy and records this in the history.
  - The epoch end at 1000 Hz failed a one-sample tolerance.
- No candidate met the constraints: even at 200 µV, at most 40–70% of trials survived. The new
  diagnostic names the channels driving rejection: O1/O2 in most epochs, then T7/T8. These are the
  channels the existing manual pipeline for this recording removed by hand.

## 8. 0.6 features not carried over

| 0.6 feature | Status in 0.7 |
|---|---|
| Resume an interrupted comparison (receipts, checkpoints) | **Not available.** An interrupted search has to be re-run. |
| Parallel evaluation (`parfor`) | **Not available.** Execution is sequential (depth-first prefix sharing). |
| Random subset when the grid is too large (`maxPipelines`) | **Removed on purpose.** The search refuses above `maxLeaves` instead of silently sampling. |
| GoalProfile weights / Pareto front | Replaced by constraints + SME + tie set (section 2). |
| External QC import (CSV/JSON) | Removed: rankings come only from candidates NeuroQC evaluated itself. |
| Formal trial rules (`TrialSelector`: practice blocks, marker ranges) | Do this in EEGLAB first (e.g. `pop_selectevent`), or as a native step. |
| V/µV declaration and conversion | Data are assumed to be in µV (EEGLAB convention). Volt-scale data is warned about, not converted. |
| Recipe `.m` files | `neuroqc.NeuroQC.script(r, id)` prints the exact commands; adopted datasets carry them in `EEG.history`. |
