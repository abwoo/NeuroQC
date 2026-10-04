# NeuroQC

<p>
  <img src="https://img.shields.io/badge/version-0.7.1-2f6fed?style=flat-square" alt="version"/>
  <img src="https://img.shields.io/badge/MATLAB-R2026a-orange?style=flat-square" alt="MATLAB"/>
  <img src="https://img.shields.io/badge/EEGLAB-2026.0.0-blueviolet?style=flat-square" alt="EEGLAB"/>
</p>

NeuroQC compares EEGLAB preprocessing pipelines by the standardized measurement error (SME) of
your measures, after checking constraints and that a known signal survives the processing: ERP
measures on event-related data, and band power on continuous data such as resting state.

It starts from the dataset as it is in EEGLAB now, takes the steps, order and fixed values you
choose, runs every allowed combination of what you left open through EEGLAB itself, evaluates and
compares the results, and hands the candidate pipelines back to you.

![The NeuroQC panel on synthetic data](docs/assets/panel.png)

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

Copy the NeuroQC folder into `eeglab/plugins/` and start (or restart) EEGLAB: it adds
EEGLAB > Tools > NeuroQC by itself, every time EEGLAB starts. Name the folder `NeuroQC` (or
`NeuroQC0.7.1`): EEGLAB takes the plugin's name and version from the folder name, so a folder
called e.g. `111` would show up as a plugin named `111`.

`neuroqc_setup` is for development from another folder: it puts NeuroQC on the path and adds the
menu to the running EEGLAB. Each later `eeglab` call rebuilds the menus, so call `neuroqc_setup`
again after it.

Requirements:

- Tested on MATLAB R2026a with EEGLAB 2026.0.0 (no other versions have been tested).
- MATLAB only; GNU Octave is not supported (the panel is a MATLAB `uifigure`).
- EEGLAB's main window and its base-workspace variables `EEG`, `ALLEEG` and `CURRENTSET`: NeuroQC
  reads the current dataset from there (the script interface too) and stores adopted candidates
  there. It does not work with `eeglab nogui` or with EEGLAB called inside a function, where these
  variables are not in the base workspace.
- EEGLAB with firfilt (included by default).
- The ICLabel plugin for `icremove`, and clean_rawdata for `asr`.
- Optional: the Parallel Computing Toolbox, for `parallel`.
## Quick start

1. Load or select a dataset in EEGLAB as usual.
2. EEGLAB > Tools > NeuroQC > *Optimize from current dataset…*. Define the conditions (*Add from
   events…*), the epoch, and a component (time window, ROI, measure), add the steps to compare,
   and press *Run search*.
3. Select a result to see why it was recommended or excluded; *Adopt selected* stores it as a new
   EEGLAB dataset whose `EEG.history` reproduces it.

Every button of the panel is described in [docs/PANEL.md](docs/PANEL.md).

Band power of continuous data (script only for now; the simple-mode dialog will offer it):

```matlab
c = neuroqc.eval.Contract('analysis', 'bandpower', 'segment', 2, ...
    'bands', {'alpha', [8 12], {'O1','Oz','O2'}});              % your band and ROI
```

**The same from a script**

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
- The panel follows the current EEGLAB dataset with a cheap check every second and a full
  fingerprint (every event, the whole history) at least every 5 s, so an edit that changes no
  count (e.g. one event's type) may take up to 5 s to show. A search and Adopt always use the full
  fingerprint.
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
  version = {0.7.1},
  url     = {https://github.com/abwoo/NeuroQC}
}
```
## References

The methods, their derivations and all sources are in [docs/METHODS.md](docs/METHODS.md); the main
ones are Luck et al. (2021) for the SME, Zhang, Garrett & Luck (2024) for comparing pipelines by
signal-to-noise, and White (2000) / Romano & Wolf (2005) for the simultaneous comparison.
