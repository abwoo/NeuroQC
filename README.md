# NeuroQC 0.7

<p>
  <img src="https://img.shields.io/badge/version-0.7.0-2f6fed?style=flat-square" alt="version"/>
  <img src="https://img.shields.io/badge/MATLAB-R2026a-orange?style=flat-square" alt="MATLAB"/>
  <img src="https://img.shields.io/badge/EEGLAB-2026.0.0-blueviolet?style=flat-square" alt="EEGLAB"/>
</p>

NeuroQC is an optimization and orchestration layer around EEGLAB. EEGLAB remains the execution
engine and the GUI. NeuroQC reads the dataset that is current in EEGLAB together with its real
`EEG.history`. You describe the processing you want from that point on and fix whatever you choose.
NeuroQC then runs every legal combination of the parts you left open and reports:

- which result measures your component most precisely,
- which results these data cannot tell apart from it,
- why each of the others was excluded.

Every candidate is checked against a known signal before it can be recommended, so stronger
processing does not win merely by removing noise.

> What is and is not covered: [docs/COVERAGE.md](docs/COVERAGE.md).

## Install

```matlab
addpath('/path/to/NeuroQC');        % or copy the folder into eeglab/plugins/
neuroqc_setup                       % adds EEGLAB > Tools > NeuroQC
```

Requirements:

- MATLAB R2021b or later.
- EEGLAB with firfilt (included by default).
- The ICLabel plugin for `icremove`, and clean_rawdata for `asr`.
- Optional: the Parallel Computing Toolbox, for `parallel`.

## Use it

Load or select a dataset in EEGLAB as usual. NeuroQC has no load step: it always works on the current
dataset and never modifies it during a search. Each candidate runs on its own copy.

**Panel**: open EEGLAB > Tools > NeuroQC > *Optimize from current dataset…*

- **History and state.** The left side shows the live `EEG.history`, parsed line by line, with a
  provenance label on every item: recorded in the history, executed by NeuroQC, session-only command,
  inferred from the data, or cannot be verified. The top shows the dataset's state and any warnings.
- **Analysis contract, from EEGLAB's own dialogs.** Conditions are picked from the dataset's event
  list (*Add from events…*); the trials that count from markers, an EEGLAB data selection
  (`pop_select`) or event selection (`pop_selectevent`); the epoch from `pop_epoch`; the baseline from
  `pop_rmbase` (ms converted to s); the ROI from EEGLAB's channel selection. *View ERP* opens
  `pop_timtopo`, *Chan. locations…* opens `pop_chanedit`. The text fields stay editable and show
  the trials per condition under the rule.
- **Nothing is prefilled for a particular study.** Conditions, epoch and components start empty.
  Defaults that are used are stated and come from conventions or from the data: an empty baseline
  is the pre-stimulus interval [epoch start, 0]; an empty epoch on epoched data is the data's own
  epochs; the line-noise frequency (50/60 Hz) and the data unit (uV/V) are judged from the
  recording; resampling has no default rate. Constraint limits and the catalog's search lists are
  general starting values, shown in the panel and editable.
- **Plan.** Add steps in the order they should run. The *effective* column shows every parameter as
  it will run, including the defaults that will be searched. Values come from the step's EEGLAB
  dialog: *Values from EEGLAB dialog…* adds each dialog's values to the step's search; *Fix via
  EEGLAB dialog* keeps the dialog's whole command (also mark→reject and ICLabel→flag→remove
  workflows); *Add config (EEGLAB)…* configures it again, and the arguments that differ are
  searched one by one (*Parameters…* shows them). *Skipping allowed*, *Must come before…* and the
  *pin* column control alternatives and order.
- **Apply now in EEGLAB.** Runs the step on the current dataset through EEGLAB's own menu code path
  (`EEG.history`, `ALLCOM`, new dataset), so the plan starts after it.
- **Run search / Options… / Resume…** Every command and score is printed in the Command Window and
  the result is stored in `neuroqc_result`. Options: data unit, checkpoint folder, sampled search,
  parallel, external QC table.
- **Results.** Selecting a row shows its full pipeline, reason, measures and commands below the
  table. *Inspect selected* opens a rebuilt candidate (not adopted) or the source in EEGLAB's
  viewers; *Adopt* stores a candidate as a new EEGLAB dataset whose `EEG.history` reproduces it.

**Script**

```matlab
neuroqc.NeuroQC.state();                          % current dataset, parsed history, provenance

c = neuroqc.eval.Contract( ...
    'conditions', {'target', {'11','21'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.30 0.60], {'Pz','CPz','POz'}, 'mean'; ...
                   'P3lat', [0.30 0.60], {'Pz'}, {'peakLatency','positive'}});

p = neuroqc.plan.Plan();
p = p.add('resample', 'fs', 250);                 % fixed
p = p.add('highpass');                            % searched: catalog suggestions
p = p.add('lowpass', 'cutoff', 30);
p = p.addChoice('o1o2', {'channels','labels',{'O1','O2'},'action','interpolate'}, ...
                        {'channels','labels',{'O1','O2'},'action','remove'}, 'none');
p = p.add('reref', 'mode', {'average', 'channels'}, 'channels', {{'TP9','TP10'}}, ...
          'exclude', {'HEOG','VEOG'});            % searched; ranked in separate strata
p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', {0.8, 0.9});
p = p.add('epoch'); p = p.add('baseline');        % windows come from the contract
p = p.add('reject_threshold', 'uv', {100, 150}, 'exclude', {'HEOG','VEOG'});

opts = struct('objective', {{'P3.mean', 'P3lat.peakLatency'}}, 'checkpoint', 'nqc_run1');
r = neuroqc.NeuroQC.optimize(p, c, opts);
neuroqc.NeuroQC.adopt(r);                         % recommended candidate -> new EEGLAB dataset
neuroqc.NeuroQC.writeScript(r, 3, 'pipeline3.m'); % runnable EEGLAB function for candidate 3
r = neuroqc.NeuroQC.resume('nqc_run1');           % continue an interrupted search
```

Options are listed in `help neuroqc.run.Executor` (search) and `help neuroqc.eval.Rank`
(constraints and ranking). Ordering:

- By default the order you add steps is the order they run. If that order is illegal, NeuroQC lists
  the conflicts and does not rearrange anything.
- `p.OrderMode = 'search'` tries every legal order.
- `p.pin('epoch')` keeps a step at its position, and `p.before('highpass','lowpass')` constrains
  two steps.

## How the search works

1. **Starting point.**
   - The current state is read from the EEG structure: epoched or not, sampling rate, channels, ICA
     matrices, IC flags and reference.
   - `EEG.history` is parsed in order, without deduplication; continuation lines (`...`) are joined.
   - Where the history cannot describe the data, NeuroQC says so instead of guessing.
   - Data in volts can be declared with `dataUnit = 'V'` and are converted on NeuroQC's copy.
   - A floating-point sampling-rate residue (common after EDF import) is rounded on the copy, and
     the change is recorded.
2. **Legal pipelines.**
   - The plan expands into all combinations of searched values, alternatives and orders. Each is
     checked against the simulated data state; excluded combinations are counted with their reason.
   - Exhaustive mode refuses to start above `maxLeaves`.
   - `searchMode = 'sample'` draws a seeded random sample of legal pipelines. Its result is labelled
     *approximate*, not a proven optimum.
3. **Execution.**
   - Pipelines run as a prefix tree, so a shared prefix (e.g. one ICA before several IC thresholds)
     is computed once.
   - Every step is a native EEGLAB call. Its command is printed and appended to that candidate's
     `EEG.history`.
   - Each candidate is checkpointed. `resume` continues and gives the same result as an
     uninterrupted run.
   - `parallel = true` distributes independent subtrees over a pool.
4. **What is measured.**
   - The contract defines the measures: mean amplitude, peak amplitude or peak latency per
     component.
   - No experimental effect is used, so choosing a pipeline cannot inflate the effect you test later.
   - The data quality of each measure is its standardized measurement error (SME): analytic for
     means, bootstrapped for peaks and latencies (Luck et al., 2021). SME falls when noise is removed
     and rises when trials are lost, so it prices the rejection trade-off.
5. **Signal preservation.** A known signal is used to catch processing that removes the effect along
   with the noise.
   - **Filter probe.** For plans with only fixed linear steps (filters, resampling), the known
     waveform passes through the same EEGLAB filter calls.
   - **Matched-decision injection.** For plans with data-driven steps (bad channels, ICA, IC removal,
     rejection), a copy containing only a known signal is carried through every candidate. That copy
     receives the same channel, ICA, component and epoch decisions as the real data. ASR and native
     non-filter commands are re-run on the copy and flagged.
   - Both report amplitude error, peak shift, artifactual deflection, and waveform and topography
     correlation, each against a limit.
6. **Ranking.**
   - Failures are reported, never ranked. Constraint violations are listed with their reasons.
     If nothing is feasible, NeuroQC says so and relaxes nothing.
   - Objectives: `'composite'` (only when every measure has the same unit), a priority list, or
     `'pareto'`.
   - A paired bootstrap over trials, matched by `urevent`, gives each candidate an interval for its
     difference from the best. The intervals are simultaneous over all candidate pairs, so the
     chance that any candidate is wrongly called worse stays bounded however many candidates are
     searched (simulated: <= 5% for 2-24 candidates and 20-100 trials per condition at the default
     `alpha = 0.02`; with per-comparison intervals it was 88% for 24 candidates).
     - *Not distinguished* means the interval reaches zero. This is absence of evidence, not
       equivalence.
     - Equivalence is claimed only when you give `equivalenceMargin`.
     - `probBest` shows the ranking uncertainty. `adjust = 'none'` or `'bonferroni'` gives the
       older per-comparison intervals.
   - A signal-preservation metric that applies but could not be computed (NaN) rejects the
     candidate; it is never treated as a pass.
   - Candidates that differ in measure-defining choices (the reference) are ranked in separate
     strata, never against each other.
   - The recommendation is the least aggressive candidate among those not distinguished from the
     best: most trials kept, then least distortion.
   - External QC values (CSV or table with a `key` column) can be imported as columns and limits.

## Limitations (read before trusting a result)

- The contract (events, epoch and baseline windows, ROIs and time windows) defines what is measured.
  NeuroQC never searches it.
- The injection check uses a known signal with an assumed topography: a Gaussian around the ROI when
  channel locations exist, otherwise the ROI channels only. Real components can be affected
  differently, so passing the check is necessary but not sufficient.
- ASR and native non-filter commands are re-run on the injected copy rather than decision-matched.
  Their check is therefore less specific; the result says so.
- Spherical interpolation needs channel locations. Without them, interpolation candidates fail with
  that reason.
- Peak-measure bootstraps are slower (nested resampling). Use mean measures for large searches.
- Depth-first execution keeps one copy of the dataset per plan depth in memory (one per worker in
  parallel mode).
- Thresholds such as 100 µV assume microvolts. NeuroQC warns when the data look like volts.

## Tests

```matlab
addpath(fullfile(pwd, 'tests')); results = run_all();
```

The suite has 76 automated tests on synthetic data with known ground truth:

- the history parser,
- plan legality and enumeration (checked against brute force),
- the statistics, validated by simulation: SME vs empirical SD, false "worse" rate and power,
  equivalence, bootstrapped latency SME,
- signal preservation for filters, re-referencing, ICA removal, interpolation and rejection,
- end-to-end searches, including resume and parallel execution,
- EEGLAB and panel integration.

All 76 automated tests pass in MATLAB R2026a with EEGLAB 2026.0.0. Two optional runs use your own
data and are never committed:

- `NEUROQC_REAL_SET` parses one of your datasets.
- `tests/realdata_validation.m` runs a technical search on a working copy of a real recording.

## Cite

```bibtex
@software{neuroqc2026,
  author  = {abwoo},
  title   = {NeuroQC: an optimization layer for EEGLAB preprocessing pipelines},
  year    = {2026},
  version = {0.7.0},
  url     = {https://github.com/abwoo/NeuroQC}
}
```

## References

- Luck, S. J., Stewart, A. X., Simmons, A. M., & Rhemtulla, M. (2021). Standardized measurement error:
  A universal metric of data quality for averaged event-related potentials. *Psychophysiology*, 58.
- Zhang, G., Garrett, D. R., & Luck, S. J. (2024). Optimal filters for ERP research I: A general
  approach for selecting filter settings; II: Recommended settings for seven common ERP components.
  *Psychophysiology*, 61.
- Schuirmann, D. J. (1987). A comparison of the two one-sided tests procedure and the power approach
  for assessing the equivalence of average bioavailability. *J. Pharmacokinetics and
  Biopharmaceutics*, 15.

MIT License.
