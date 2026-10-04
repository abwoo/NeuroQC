# NeuroQC 0.7

<p>
  <img src="https://img.shields.io/badge/version-0.7.0-2f6fed?style=flat-square" alt="version"/>
  <img src="https://img.shields.io/badge/MATLAB-R2026a-orange?style=flat-square" alt="MATLAB"/>
  <img src="https://img.shields.io/badge/EEGLAB-2026.0.0-blueviolet?style=flat-square" alt="EEGLAB"/>
</p>

NeuroQC is a semi-automatic preprocessing optimizer attached to EEGLAB. It starts from the dataset as
it is in EEGLAB now, takes the steps, order and fixed values you choose, runs every allowed
combination of what you left open through EEGLAB itself, evaluates and compares the results, and
hands the candidate pipelines back to you.

What it does, and nothing more:

1. **Reads the current EEGLAB state**: continuous or epoched, channels and locations, ICA, filters,
   reference and the processing in `EEG.history`; what the data say (epochs, time-locking events,
   baseline already removed, mains frequency, unit) fills the fields for you.
2. **Lets you define the search**: which steps, in which order, which values are fixed and which
   may vary, which steps may be skipped.
3. **Uses EEGLAB's own dialogs** to configure steps, conditions, trials, epoch, baseline and ROI;
   NeuroQC's own window manages candidates, order, locks and the comparison.
4. **Runs every allowed combination** in EEGLAB (shared first steps computed once); it never
   samples or truncates and then claims a full search.
5. **Evaluates and compares**: constraints first (trials kept, interpolation, preservation of a known
   signal), then measurement precision (SME) with intervals valid across all candidates. No
   experimental effect (peak size, significance) is ever used.
6. **Returns the results reproducibly**: why each candidate was recommended or excluded, its full
   EEGLAB commands, a runnable script, and adoption as a new EEGLAB dataset whose history
   reproduces it.

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

- **History and state.** The left side shows the live `EEG.history`, parsed line by line. The top
  shows the dataset's state (including channel locations) and any inconsistency between data and
  history.
- **Analysis contract, from EEGLAB's own dialogs.** Conditions are picked from the dataset's event
  list (*Add from events…*); the trials that count from markers, an EEGLAB data selection
  (`pop_select`) or event selection (`pop_selectevent`); the epoch from `pop_epoch`; the baseline from
  `pop_rmbase` (ms converted to s); the ROI from EEGLAB's channel selection. When a dialog sets
  something the contract cannot hold as is (epoch events that differ from the conditions, epoch
  options, a baseline on a channel subset), the panel asks which to keep. A trial rule belongs to
  the recording it was set on and is reset (or flagged) when another recording becomes current. *View ERP* opens
  `pop_timtopo`, *Chan. locations…* opens `pop_chanedit`. The text fields stay editable and show
  the trials per condition under the rule.
- **Nothing is prefilled for a particular study.** Conditions, epoch and components start empty.
  Defaults that are used are stated and come from conventions or from the data: an empty baseline
  is the pre-stimulus interval [epoch start, 0]; an empty epoch on epoched data is the data's own
  epochs; the line-noise frequency (50/60 Hz) and the data unit (uV/V) are judged from the
  recording; resampling has no default rate. Constraint limits and the catalog's search lists are
  general starting values, shown in the panel and editable.
- **Plan.** Add steps in the order they should run. The table shows every parameter as it will
  run (one value = fixed, several = searched, defaults marked). *Configure in EEGLAB…* opens the
  step's EEGLAB dialog: its values join the step, and a value that differs from those already there
  becomes a searched candidate; settings the step cannot hold (e.g. asymmetric limits) are kept as
  the whole EEGLAB command if you choose so. Each dialog opens on the data as the plan has them at
  that step (the current dataset's first 120 s run through the steps before it). *Add EEGLAB menu
  step…* adds any operation of EEGLAB's menus, plugins included (e.g. CleanLine, ERPLAB): its own
  dialog opens and the command it returns becomes a step whose arguments can be searched.
  *Edit values…* lists the parameters (channel lists picked in EEGLAB's channel list). *Skipping allowed*, *Must come before…* and the *pin* column
  control alternatives and order.
- **Apply now in EEGLAB.** Runs the step on the current dataset through EEGLAB's own menu code path
  (`EEG.history`, `ALLCOM`, new dataset), so the plan starts after it.
- **Run search / Options… / Resume…** Every command and score is printed in the Command Window and
  the result is stored in `neuroqc_result`. Options: data unit, checkpoint folder, parallel.
- **Results.** Selecting a row shows its full pipeline, reason, measures and commands below the
  table. *Inspect selected* opens a rebuilt candidate (not adopted) or the source in EEGLAB's
  viewers; *Adopt* stores a candidate as a new EEGLAB dataset whose `EEG.history` reproduces it.

**Script**

```matlab
neuroqc.NeuroQC.state();                          % current dataset, parsed history

c = neuroqc.eval.Contract( ...
    'conditions', {'target', {'11','21'}; 'standard', {'31'}}, ...      % your event codes
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.30 0.60], {'Pz','CPz','POz'}, 'mean'});    % your measure

p = neuroqc.plan.Plan();
p = p.add('highpass');                            % searched over its default list
p = p.add('lowpass', 'cutoff', 30);               % fixed
p = p.addEeglab('EEG = pop_reref(EEG, []);', 'reref');   % any EEGLAB call; its arguments are parameters
p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', {0.8, 0.9});   % searched
p = p.add('epoch'); p = p.add('baseline');        % windows come from the contract
p = p.add('reject_threshold', 'uv', {100, 150});

r = neuroqc.NeuroQC.optimize(p, c, struct('checkpoint', 'nqc_run1'));
neuroqc.NeuroQC.adopt(r);                         % recommended candidate -> new EEGLAB dataset
neuroqc.NeuroQC.writeScript(r, 3, 'pipeline3.m'); % runnable EEGLAB function for candidate 3
r = neuroqc.NeuroQC.resume('nqc_run1');           % continue an interrupted search
```

Options are listed in `help neuroqc.run.Executor` (search) and `help neuroqc.eval.Rank`
(constraints and ranking). By default the order you add steps is the order they run; if it is
illegal, NeuroQC lists the conflicts and rearranges nothing. `p.OrderMode = 'search'` tries every
legal order; `p.pin(id)` keeps a step in place and `p.before(a, b)` constrains two steps.

## How the search works

1. **Starting point.**
   - The current state is read from the EEG structure: epoched or not, sampling rate, channels and
     their locations, ICA matrices, IC flags and reference.
   - `EEG.history` is parsed in order, without deduplication; continuation lines (`...`) are joined.
   - Where the history cannot describe the data, NeuroQC says so instead of guessing.
   - The data unit (uV or V) is judged from the amplitude scale (or set with `dataUnit`); volts are
     converted on NeuroQC's copy.
   - A floating-point sampling-rate residue (common after EDF import) is rounded on the copy, and
     the change is recorded.
2. **Legal pipelines.**
   - The plan expands into all combinations of searched values, alternatives and orders. Each is
     checked against the simulated data state; excluded combinations are counted with their reason.
   - Every legal pipeline is run; above `maxLeaves` (500 by default) the search is refused with its
     size, never sampled or truncated. To bring a large search within reach: fix the values you
     are already sure of, pin steps or add `before()` rules instead of searching every order, or
     search in stages (search the early steps, adopt the result, then search the later steps from
     that dataset). Raising `maxLeaves` is possible but every pipeline really runs.
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
   - A copy containing only a known signal is carried through every candidate with the same
     operations and the same decisions as the real data (bad channels, ICA, removed components,
     rejected epochs, ASR reconstructions). Native commands that decide from the data on their own
     are re-run on the copy and flagged.
   - Amplitude error, peak shift, artifactual deflection, and waveform and topography correlation
     are each checked against a limit.
6. **Ranking.**
   - Failures are reported, never ranked. Constraint violations are listed with their reasons.
     If nothing is feasible, NeuroQC says so and relaxes nothing.
   - Objective: the **gain-corrected SME**, SME divided by the factor by which the candidate scales a
     known signal in that measure (read from the signal check). Raw SME would reward a pipeline that
     shrinks signal and noise alike; SME/gain does not, and ranking it is ranking signal-to-noise
     (Zhang, Garrett & Luck, 2024). Composite over measures that share a unit, or the one measure
     you choose; the others are reported. Derivation in [docs/METHODS.md](docs/METHODS.md).
   - Paired bootstrap over trials (matched by `urevent`); intervals of the difference from the best
     are simultaneous over all candidates (bootstrap max statistic; White, 2000; Romano & Wolf,
     2005), so a larger search does not produce more false "worse" verdicts. *Not distinguished* is
     absence of evidence, not equivalence.
   - A candidate that ends with epochs marked for rejection but not removed (e.g. an ERPLAB artifact
     detection step without a removal) carries a note: marks do not remove epochs.
   - Candidates that differ in the reference are ranked in separate strata, never against each other.
     With several strata there is no overall recommendation: each stratum has its own (marked `*`),
     and you choose the one that fits your analysis.
   - The recommendation is the least aggressive candidate among those not distinguished from the
     best: most trials kept, then least distortion.

## Limitations (read before trusting a result)

- The contract (events, epoch and baseline windows, ROIs and time windows) defines what is measured.
  NeuroQC never searches it.
- The signal check uses a known signal with an assumed topography: a Gaussian around the ROI over
  the channels that have locations (channels without one, e.g. EOG, get none outside the ROI), or
  the ROI channels only when no ROI channel has a location. Real components can be affected
  differently, so passing the check is necessary but not sufficient.
- EEGLAB commands that decide from the data on their own (other than the catalog steps, captured
  mark/remove workflows and ASR) are re-run on the signal copy; the result says so.
- Spherical interpolation and ICLabel need channel locations. Without any, those steps are excluded
  before the search runs, with the reason; a channel without a location is never reported as
  interpolated.
- Peak-latency precision is itself hard to estimate with few trials, so peak-latency objectives
  rarely separate candidates; mean-amplitude measures are more informative for choosing a pipeline.
- Every candidate also runs on the signal copy (same operations and decisions), so a search costs
  roughly twice the EEGLAB computation of the pipelines themselves, filter-only plans included.
- Depth-first execution keeps one copy of the dataset and one of the signal copy per plan depth in
  memory (per worker in parallel mode); the expected peak is printed when it exceeds 2 GB. Resample
  early in the plan to reduce it.

## Tests

```matlab
addpath(fullfile(pwd, 'tests')); results = run_all();
```

The automated suite runs on synthetic data with known ground truth:

- the history parser and the data state,
- plan legality and enumeration (checked against brute force),
- the statistics, validated by simulation: SME vs empirical SD, false "worse" rate across 2-24
  candidates and power, bootstrapped peak SME vs replications,
- signal preservation for filters, re-referencing, ICA removal, interpolation, rejection and ASR
  (whose decisions are checked to reproduce EEGLAB's output exactly),
- end-to-end searches, including resume and parallel execution,
- EEGLAB and panel integration.

Two optional runs use your own data and are never committed:

- `NEUROQC_REAL_SET` parses one of your datasets.
- `tests/realdata_validation.m` runs a technical search on a working copy of a real recording.

Clicking inside EEGLAB's dialogs cannot be automated; [tests/MANUAL_GUI_CHECK.md](tests/MANUAL_GUI_CHECK.md)
lists what to click and what to expect.

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
- Kothe, C. A. E., & Makeig, S. (2013). BCILAB: a platform for brain-computer interface
  development. *Journal of Neural Engineering*, 10 (artifact subspace reconstruction).
- White, H. (2000). A reality check for data snooping. *Econometrica*, 68, 1097–1126.
- Romano, J. P., & Wolf, M. (2005). Stepwise multiple testing as formalized data snooping.
  *Econometrica*, 73, 1237–1282.
- Hansen, P. R., Lunde, A., & Nason, J. M. (2011). The model confidence set. *Econometrica*, 79,
  453–497.
- Davison, A. C., & Hinkley, D. V. (1997). *Bootstrap Methods and Their Application*. Cambridge
  University Press.
- Perrin, F., Pernier, J., Bertrand, O., & Echallier, J. F. (1989). Spherical splines for scalp
  potential and current density mapping. *Electroencephalography and Clinical Neurophysiology*, 72,
  184–187.
- Pion-Tonachini, L., Kreutz-Delgado, K., & Makeig, S. (2019). ICLabel: An automated
  electroencephalographic independent component classifier, dataset, and website. *NeuroImage*,
  198, 181–197.

The full derivations, and the remaining sources, are in [docs/METHODS.md](docs/METHODS.md).

MIT License.
