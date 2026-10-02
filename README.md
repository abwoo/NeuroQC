# NeuroQC 0.7

An optimization and orchestration layer around EEGLAB. EEGLAB stays the execution engine and the
GUI. NeuroQC reads the dataset that is current in EEGLAB together with its real `EEG.history`. You
describe the processing you want from that point on, fixing whatever you choose, and NeuroQC runs
every legal combination of the parts you left open. It then tells you which result is best, which
results are statistically indistinguishable from it, and why the others were excluded.

> What changed from 0.6 and why: see [REVIEW.md](REVIEW.md).

## Install

```matlab
addpath('/path/to/NeuroQC-gh');     % or copy the folder into eeglab/plugins/
neuroqc_setup                       % adds EEGLAB > Tools > NeuroQC
```

Requires MATLAB R2021b or later and EEGLAB with firfilt (default). The ICLabel plugin is needed for
`icremove` and clean_rawdata for `asr`.

## Use it

Load or select a dataset in EEGLAB as usual. NeuroQC has no load step; it always works on the
current dataset.

**Panel**: EEGLAB > Tools > NeuroQC > *Optimize from current dataset…*

- The left side shows the live `EEG.history`, parsed line by line. The top shows the dataset's
  current state, plus warnings where the data and the history disagree. It updates by itself when
  you change the dataset in EEGLAB.
- **Plan**: add steps in the order they should run. In *settings*, a single value is fixed and
  `{a, b, c}` is searched. Parameters you don't mention are searched over the catalog suggestions
  (*Catalog help* prints them).
- **Fix via EEGLAB dialog** opens the native EEGLAB dialog. The command it returns becomes a fixed
  step that is replayed verbatim.
- **Apply now in EEGLAB** runs the step on the current dataset through EEGLAB's own menu code path,
  so it is recorded in `EEG.history` and the plan then starts after it.
- **Run search** prints every command, step and score in the Command Window and stores the result in
  `neuroqc_result`. **Adopt** stores a candidate as a new EEGLAB dataset whose `EEG.history`
  reproduces it.

**Script**

```matlab
neuroqc.NeuroQC.state();                         % current dataset, parsed history, warnings

c = neuroqc.eval.Contract( ...
    'conditions', {'target', {'11','21'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.30 0.60], {'Pz','CPz','POz'}});

p = neuroqc.plan.Plan();
p = p.add('resample', 'fs', 250);                 % fixed
p = p.add('highpass');                            % searched: 0.1 0.3 0.5 1 Hz
p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average');            % must be fixed (defines the measure)
p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', {0.8, 0.9});
p = p.add('epoch'); p = p.add('baseline');        % windows come from the contract
p = p.add('reject_threshold', 'uv', {100, 150}, 'exclude', {'HEOG','VEOG'});
p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',48,''hicutoff'',52,''revfilt'',1);');

r = neuroqc.NeuroQC.optimize(p, c);               % opts: see neuroqc.eval.Rank.defaults
neuroqc.NeuroQC.adopt(r);                         % recommended candidate -> new EEGLAB dataset
neuroqc.NeuroQC.script(r, 3);                     % EEGLAB commands of candidate 3
```

Ordering:

- By default the order you add steps is the order they run.
- `p.OrderMode = 'search'` tries every legal order.
- `p.pin('epoch')` keeps a step at its position, and `p.before('highpass','lowpass')` constrains
  two steps.
- `p.addChoice('reject', {'reject_threshold','uv',100}, {'reject_jointprob'}, 'none')` tries
  alternative methods, or no step at all, at one position.

## How the search works

1. **Starting point.**
   - The current state is read from the EEG structure itself: epoched or not, sampling rate,
     channels, ICA matrices, IC flags and reference.
   - `EEG.history` is parsed in order, without deduplication, into load / process / mark / view /
     save entries.
   - Where the history cannot describe the data, NeuroQC says so instead of guessing. Examples are
     ICs removed after interactive flagging, commands that reference `ALLEEG(n)`, and two ICA runs.
2. **Legal pipelines.** The plan expands into all combinations of the searched values, alternatives
   and orders. Each one is checked against the simulated data state: no filtering of epoched data,
   no IC removal without a valid ICA, no baseline before epoching, no upsampling, and so on.
   Excluded combinations are counted with their reason. Nothing is silently truncated: above
   `maxLeaves` the run refuses to start.
3. **Execution.**
   - Pipelines are run as a prefix tree, so a shared prefix is computed once. For example,
     `ica → icremove{0.8,0.9}` runs ICA once.
   - Every step is a native EEGLAB call.
   - Its command is printed and appended to that candidate's `EEG.history`.
   - ICA uses `rndreset no`, so replays are identical. Adopt re-checks this.
4. **Evaluation.** No experimental effect is used anywhere, so choosing a pipeline cannot inflate the
   effect you will test later.
   - **Noise in what you will measure:** the standardized measurement error (SME, µV) of each
     component's mean amplitude, per condition. SME falls when noise is removed and rises when
     trials are lost, so it prices the trial-rejection trade-off.
   - **Signal distortion:** a noise-free synthetic waveform with one bump per component goes through
     the candidate's exact filter calls. Amplitude change, peak shift and artifactual
     opposite-polarity deflections are measured. Without this, noise metrics always prefer stronger
     filtering.
   - **Constraints:** trials per condition, retention per condition, the fraction of interpolated
     channels, and the filter-probe limits. Every exclusion is reported with its reason.
5. **Ranking.**
   - Feasible candidates are ordered by composite SME.
   - A paired bootstrap over trials gives each candidate an interval for its SME difference from the
     best. It is paired because trials are identified by `urevent`, so the same trials are
     resampled for every candidate.
   - Candidates whose interval reaches zero are *tied* with the best.
   - Among tied candidates, the recommendation is the least aggressive one: most trials kept, then
     least filter distortion.
   - A per-parameter summary shows which choices matter for this dataset.

## Limitations (read before trusting a result)

- The reference, the epoch and baseline windows, and the ROI/time windows define the measured
  quantity. They must be fixed; a data-quality score cannot compare them.
- Scores use mean amplitude. Peak or latency measures are not supported yet.
- The distortion probe covers linear filtering steps: high-pass, low-pass, notch, resample and
  native filter commands. ICA/ASR effects on the signal are not probed; IC counts and retention are
  reported instead.
- The SME intervals are per comparison, not adjusted for the number of candidates.
- Depth-first execution keeps one copy of the dataset per plan depth in memory.
- Thresholds such as 100 µV assume data in microvolts. NeuroQC warns when the data look like volts.

## Tests

```matlab
addpath(fullfile(pwd, 'tests')); results = runtests('tests/test_neuroqc.m')
```

The tests use synthetic data with a known ERP and known artifacts. They also cover the history
parser, plan legality, the bootstrap, the filter probe, an end-to-end run with adopt/replay, ICA
prefix sharing, native steps and the panel. Set `NEUROQC_REAL_SET` to also parse one of your own
datasets. `site/` and `docs/assets/` still show the 0.6 interface.

## References

- Luck, S. J., Stewart, A. X., Simmons, A. M., & Rhemtulla, M. (2021). Standardized measurement error:
  A universal metric of data quality for averaged event-related potentials. *Psychophysiology*, 58.
- Zhang, G., Garrett, D. R., & Luck, S. J. (2024). Optimal filters for ERP research I: A general
  approach for selecting filter settings; II: Recommended settings for seven common ERP components.
  *Psychophysiology*, 61.

MIT License.
