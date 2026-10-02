# Review of NeuroQC 0.6 and what 0.7 changes

This file records the problems found in 0.6 and how 0.7 resolves each one. The 0.6 code is still in
git history (branch `main`).

## 1. Evaluation metrics

| 0.6 problem | Consequence | 0.7 |
|---|---|---|
| `waveformDistortion` = relative L2 distance between candidate and **unprocessed** handoff averages | Removing drift or blinks, or re-referencing, counted as "distortion". Average-reference candidates could fail the 0.5 hard gate. The ranking favoured pipelines that do little. | Removed. Distortion is measured where it has a ground truth: a noise-free synthetic waveform passed through the candidate's exact filter calls (`eval.FilterProbe`). |
| Split-half `reliability` / `topoStability` computed **without baseline correction** | Per-channel DC offsets are shared by both halves, so r ≈ 1 regardless of ERP quality | Replaced by SME of the scored measure (`eval.Measure`), computed after the contract baseline. |
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
| Full SHA-256 of the data and full-matrix rank computed many times, including inside every recipe | Removed; a cheap fingerprint detects live changes. |

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
