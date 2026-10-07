# Changelog

All notable changes. Versions follow `PipeCompare.Version` (`NeuroQC.Version` up to 0.7.1); each
release has a git tag `vX.Y.Z`.

## Unreleased

Small fixes. Scores and recommendations are unchanged, except on data cleaned with clean_rawdata
from a script whose high-pass PipeCompare now sees (see below).

- Simple mode: instead of choosing between *Standard* and *Filters only*, tick the steps to
  compare in a list shown in the order they run (bad channels, reference, ICA, high-pass,
  low-pass, epochs, epoch rejection); the order stays fixed. *Standard (all)* and *Filters only*
  are buttons that tick their steps. Steps the data cannot take are greyed out with the reason.
  `pop_pipecompare` takes `'steps'`, e.g. `{'highpass', 'lowpass', 'reject'}`; `'recipe'` works
  as before.
- Simple mode: the electrodes of a preset (an ERP component, or a band) can be changed with
  *Electrodes…*; they start from the component's ERP CORE site(s) and several are averaged.
  N2pc and LRP keep their pair. `pop_pipecompare(..., 'channels', {...})` does the same.

- While a comparison runs, the Command Window prints each step and each finished pipeline as it
  happens (in the simple mode it used to stay silent until the end); the same text is still kept
  in `pipecompare_last_run.log`.
- The progress window shows the step running now (e.g. *fitting ICA*) and the time so far,
  updated every second. Before the first pipeline is done the bar moves back and forth, since
  that first pipeline also runs the shared steps such as ICA, which can take minutes. The same
  window is used by the simple mode and the panel, also when the search runs in parallel.
- *Save script…* for ERPs now writes the components (name, window, electrodes, measure) into the
  script's analysis contract, so that contract can be used to score data again. The script's steps
  were already complete.
- The EEGLAB history command of `pop_pipecompare` keeps `'show', 'off'`, so repeating it does not
  open windows.
- When the signal-check copy fails at a step, only the signal check of the pipelines below is
  missing (they are excluded with "signal check missing" and still scored); the pipelines are no
  longer marked as failed although their data ran.
- *Advanced…* from the simple dialog: the plan table shows the epoch and baseline taken over from
  the dialog instead of "not set yet".
- The progress window's time reads "2 h 0 min" instead of "1 h 60 min" (and "1 h 0 min" instead of
  "60 min").
- Event-related band power: a baseline outside the epoch is reported before the run. A band-power
  contract given both `segment` and `conditions`/`epoch`/`baseline` is an error, since one of them
  would be ignored.
- Filters applied before PipeCompare: clean_rawdata's own high-pass is now recognised in every form
  a history can hold: option names in any case or as `highpass_band`, the option left out (it then
  uses its default, a high-pass at 0.75 Hz), and switched off. Before, only the form the EEGLAB
  dialog writes was read, so a high-pass done this way was not taken into account (the choice of
  high-pass values and the warning about filters applied before PipeCompare use it).
- Results window: a step that only some pipelines have (e.g. the high-pass when the data were
  already filtered) is now named in every pipeline: "high-pass 0.5 Hz" or "high-pass as in the
  data". Before, two such pipelines could have the same name.
- Data re-referenced with `pop_averef` (EEG.ref = 'averef') are recognised as average-referenced,
  so the results no longer suggest trying the average reference.
- *Save script…* of a pipeline that did not pass the checks asks first, as *Use this pipeline*
  does, in the simple mode and in the panel.
- Parallel search: the progress window counts the pipelines finished on the pool, and *Stop* stops
  the pool's work too (it used to take effect only after the parallel part).

## 0.9.2 (2026-10-06)

In short: PipeCompare is now tested on older MATLAB and EEGLAB releases, and parallel execution
works on MATLAB R2021b. Results are unchanged.

- The full test suite runs automatically on MATLAB R2021b, R2023b, R2024b and the latest release,
  and on EEGLAB 2024.2.1, 2025.1.0 and 2026.0.0. The README lists the tested versions.
- Parallel execution on MATLAB releases before R2022b: the pool profile there is called `local`
  (from R2022b on, `Processes`). The search used to fall back to running one pipeline at a time
  without saying so.
- A test compared volt-converted ICA weights exactly; EEGLAB 2024 and 2025 scale each component to
  RMS microvolts (EEGLAB's own option), which changes the weights but not the cleaned data. The
  test now checks the volt-to-microvolt conversion it was written for.

## 0.9.1 (2026-10-06)

In short: PipeCompare now takes into account what was done to the data before it (filters,
re-reference, removed channels, ICA) and fixes the order of steps around the average reference
in the cases 0.9.0 still got wrong. *Standard* catches noisy bad channels it used to miss. The advanced
panel can now do everything the simple dialog does (band power, N2pc/LRP, progress window with
*Stop*, *Save script…*). Results can differ from 0.9.0 on data that were already filtered or
re-referenced, or that have noisy channels.

- Simple mode, step order with the average reference: *Filters only* with *Average reference*
  averaged before any bad-channel check, so a bad channel spread into every channel (the order
  fixed for *Standard* in 0.9.0). Both recipes now interpolate bad channels before the average.
  Data that are already average-referenced (re-referenced before PipeCompare) are averaged again
  after the interpolation, which removes the bad channels' share of the earlier average; before,
  that share stayed in every channel.
- Simple mode, data already filtered: the filter edges the data have were left out, and only
  stricter ones compared, so every pipeline added a filter (data already low-passed at 30 Hz got
  low-pass 20 Hz in every pipeline). Keeping the data's own filter is now one of the choices,
  shown as e.g. *low-pass as in the data (30 Hz)*.
- Simple mode: filters applied before PipeCompare (read from the history) are outside the
  pipelines' signal check, which starts from the data as they are. The same known signal is now
  filtered at those edges; when that alone changes it beyond a pipeline's limit (e.g. a 1 Hz
  high-pass on a P3), the result window and the Command Window say so and suggest starting from
  the unfiltered data. Continuous data only (epoched data no longer hold what was filtered).
- Simple mode: with the average reference, EEG channels removed before PipeCompare (with a
  location) are interpolated back first, so the average covers the whole montage. Non-EEG channels
  (EOG, ECG, ...) are no longer offered for restoring anywhere: the scalp cannot predict them.
- The history gives the edges of filters other than `pop_eegfiltnew` (ERPLAB's `pop_basicfilter`,
  `pop_firws`, `pop_firpm`, `pop_eegfilt`, `pop_iirfilt`) and of clean_rawdata's own high-pass
  (the end of its transition band). Before, such data counted as unfiltered, so the simple mode
  compared filters they already had and could not check them.
- The dialog says where PipeCompare starts (the raw continuous data with channel locations), which
  steps were already done to the data (they are not compared), that *Standard* fits an ICA in the
  data again (and does not use the components marked in it), and the inconsistencies between the
  data and their history that only the panel showed before. The Command Window gets the same
  lines. After *Use this pipeline*, the message says the data are ready to average and should not
  be filtered, re-referenced or rejected again.
- The panel defines band power too (*Measure: Band power*): bands with their electrodes and the
  segment length, as the simple mode does; before, it defined ERP components only, and *Advanced…*
  was off for band power. *Advanced…* now takes a band choice over to the panel.
- Plans (panel and scripts): channels interpolated or removed after an average reference, with no
  average reference after them, leave the bad channels' share of that average in every channel.
  Such a pipeline is no longer legal: an order search never tries it (before, it compared it), and
  a fixed order is refused with the reason. This includes data already average-referenced before
  PipeCompare.
- Panel, as in the simple mode: an added bad-channel, re-reference or epoch-rejection step leaves
  the non-EEG channels (EOG, ECG, ...) out (before, an EOG channel was part of the average, could be
  interpolated as a bad channel, and its blinks rejected epochs), and an added bad-channel step uses
  kurtosis or joint probability (z = 5) on a 1 Hz high-passed copy (before: the catalog's search
  lists on the data as they are). Both are shown and can be changed.
- Panel: *Add component…* offers the ERP CORE components; N2pc and LRP are scored contralateral
  minus ipsilateral (`# contra`), and *Advanced…* now takes them over too. A condition with fewer
  trials than *min trials* is flagged before *Run search*, which then does not search. After a
  search the panel says what the dialog's result window says (settings that make no difference,
  what to try when no pipeline passed, filters applied before PipeCompare), and *Adopt* says the
  data are to be averaged and measured as they are.
- The panel's *Run search* shows the same progress window as the dialog, with *Stop* (the
  pipelines already finished are ranked); before, a panel search could only be interrupted from the
  Command Window. The panel also has *Save script…*, which writes the selected pipeline as a
  function for any recording (*Print script* prints this dataset's exact commands).
- In the dialog's result window, *Use this pipeline* on a pipeline that did not pass the checks
  asks for confirmation and says why it did not pass, instead of an error that named a command.
- A high-pass with a long FIR (above order 2000, e.g. 0.1 or 0.3 Hz at 250 Hz) runs in the frequency
  domain (`pop_eegfiltnew` option `usefftfilt`) when the Signal Processing Toolbox is installed:
  the same filter, much faster. This also applies to the 1 Hz copies used for bad-channel detection
  and ICA when their FIR is that long.
- *Standard* finds bad channels by kurtosis or joint probability (either above z = 5), not by
  kurtosis alone. On a raw recording kurtosis missed two noisy channels, which then made the
  epoch threshold reject most epochs in every pipeline. The
  `badchannels` step takes several measures joined by `+` (e.g. `'kurt+prob'`).
- When most pipelines were excluded for losing too many epochs, the result names the channels most
  often over the rejection limit (summed over the pipelines), as likely bad channels to remove or
  interpolate before running again.
- Datasets imported with `pop_biosig` (e.g. EDF files) keep their channels as a column, and the
  simple mode stopped at once with an index error; channel lists are now read in either shape.
- Eye channels named EYEL/EYER (also with the *POL* prefix of some EDF exports) are recognised as
  non-EEG channels, so they are not tested as bad channels or counted by the epoch threshold.
- When every pipeline that passed the checks has exactly the same noise, the result says that the
  settings compared make no difference on these data, instead of recommending the first one as if
  it were better.
- *Standard* no longer fits ICA again when the dataset's history shows that ICA was run and
  components were removed; this is named under *Left out*.
- `pop_pipecompare` says why before any search when band power is asked of epoched data (it
  needs continuous recordings) and when a recipe gives only one pipeline (e.g. *Filters only* on
  epoched data). When every pipeline was excluded because a condition has fewer than 10 trials,
  the summary suggests `'pool', true` if the event types together have enough. When most pipelines
  were excluded for losing too many epochs and the data keep their recorded reference, the result
  suggests the average reference.
- The ICA step's line in `EEG.history` lacked the `pop_runica` call (EEGLAB returns that command
  only from its dialog), so the history of an adopted dataset did not refit ICA when run again.
  The line now holds the call. Reading such a history also took the high-passed copy that ICA is
  fitted on for a filter of the data (a 1 Hz high-pass), which a later comparison on that dataset
  then treated as already applied.

## 0.9.0 (2026-10-05)

- *Use this pipeline* (and `adopt`) no longer fits ICA again: the decomposition computed during
  the comparison is reused, so adopting a pipeline with ICA no longer waits for a whole ICA. The result is the same (runica already started from a fixed state, and the replay
  check still compares the scores); the dataset history keeps the `pop_runica` command.
- ICLabel classifies each dataset once: pipelines that differ only in the ICLabel threshold share
  the classification. *Standard* for ERPs runs ICLabel 36 times instead of 108; the results are
  unchanged.

- Signal check: the injected ERP is at least 50 ms wide at half maximum. For N170 (40 ms window)
  it was 10 ms wide in sigma, half a real N170, so a 20 Hz low-pass rang beyond the artifact limit
  and was always excluded, although it changes a realistic N170 by about 0.1 %. The other ERP CORE
  components are unaffected.
- N2pc and LRP are scored contralateral minus ipsilateral, as ERP CORE measures them: the
  dialog takes the event types of each side (`pop_pipecompare(..., 'left', {...}, 'right',
  {...})`), each trial is scored as the electrode contralateral to its side minus the other, and
  the signal check uses a lateralized field. Before, the mean of the two electrodes was scored,
  which cancels the lateralized component and keeps the noise common to both hemispheres.
- Band power, *Standard*: one high-pass and one low-pass edge (the catalog values nearest the
  band outside it) instead of every combination, so 9 pipelines instead of 108 (ICLabel runs 3
  times instead of 36). Outside the band a filter does not change its power. *Filters only*
  still compares the filters.
- Band power: the signal check tested only the band centre, so a filter that cut into the band
  (a 40 Hz low-pass for a 30-45 Hz band) passed. It now also tests one frequency step inside each
  band edge. The simple mode no longer compares filter edges inside the band (e.g. a 20 Hz
  low-pass for beta, 13-30 Hz), and says so under *Left out*.
- Simple mode on epoched data: the ERP CORE epoch (-200 to 800 ms) was required, so data epoched
  otherwise (e.g. -100 to 600 ms) were refused although they hold the measurement window. Epoched
  data now keep their own epochs; the baseline starts at the epoch start when the epochs start
  later, and a window or baseline the epochs do not hold is named in the message.
- `pop_pipecompare`: when the search stopped with an error, its log was lost (only the error was
  shown); the log is now written to `pipecompare_last_run.log` first. `'recipe'` defaults to
  `'standard'`, as in the dialog (it was an error to leave it out); numeric event types are
  accepted; several selected datasets give a clear message.
- Simple dialog: switching between your own window and your own band clears the numbers, so
  milliseconds are not read as hertz.
- A single epoch (one event of the conditions, or rejection leaving one) stopped with a MATLAB
  formatting error; it now says that each condition needs at least two trials. Three error
  messages with time or frequency ranges failed the same way and now print their numbers.
- Simple mode: *Reference* (as recorded, or average reference) as a fixed step of every pipeline,
  after the bad channels and before ICA (`pop_pipecompare(..., 'reference', 'average')`).
  Previously re-referencing had to be done before PipeCompare, which spread bad channels into
  the average.
- Simple mode, *Standard*: bad channels are detected on a 1 Hz high-passed copy (slow drifts
  distorted the kurtosis of unfiltered data) and interpolated in the data as they are
  (`badchannels` parameter `detectHighpass`, 0 by default in the panel). EOG, ECG and EMG channels
  are no longer tested as bad channels or counted by the epoch-rejection threshold, where blinks
  removed many epochs; they are recognised by type or, when the type is not set, by name.
- *Save script...* for band power wrote the default ERP contract, so the script did not cut the
  data into segments and failed at its epoch step; it now keeps the band-power contract.
- A `pop_clean_rawdata` step added as an EEGLAB command is refused at plan time when ASR has no
  filter for the rate (no Signal Processing Toolbox), as the catalog ASR step is; it silently did
  nothing. An EEGLAB command with no argument after `EEG` no longer fails with a syntax error.

- Simple mode reads the data unit from the amplitude scale, as the panel does: on data stored in
  volts the epoch-rejection thresholds previously removed nothing.
- Simple mode no longer compares filter edges the data already have (from the history): they left
  the data unchanged but filtered the known signal, which favoured the lower high-pass edges.
- The result window names pipelines by the settings compared (*high-pass 0.5 Hz, low-pass
  30 Hz, …*) instead of the full step key, with one line for the steps all pipelines share; with
  no feasible pipeline it gives one pipeline's reason with its numbers.
- The time left is estimated from the pipelines after the first (which alone runs ICA), shown as
  hours and minutes; *Stop* says it stops after the current step.
- Simple mode: `boundary` markers are not offered as events; on epoched data the time-locking
  types are preselected; selected types can be scored as one condition (`'pool'`); a condition
  with fewer than 10 events is flagged before *Run* instead of excluding every pipeline after it.
- Simple-mode dialog: one *Measure* list with what the data support (the data-type menu and the
  segment field are gone; segments stay settable from scripts), *Standard* preselected, and *Run*
  off when fewer than two pipelines would be compared. The list adds *your own window and
  electrodes* (ERP) and *your own band and electrodes*; `pop_pipecompare` takes them as
  `'measure', 'custom'` with `'window'` and `'channels'`, or `'measure', 'band'` with `'band'`.
- *Save script…* / `writeScript` writes a function that runs the pipeline's steps on any
  recording (`pipecompare.PipeCompare.apply`): bad channels, ICLabel components and rejected
  epochs are decided from that recording's data. Previously the file replayed this dataset's
  channel, component and epoch numbers, which gave wrong results on other recordings without an
  error. The exact commands follow as comments.
- *Advanced…* in the simple dialog no longer leaves an empty panel and an error when the choices
  cannot be handed over (e.g. a missing electrode): it says why and the dialog stays open. It is
  off for band power, which the panel does not define.
- Result window: *Use this pipeline* shows that it is building the pipeline again (ICA too) and
  then says the new dataset is not saved yet; *Show all pipelines* lists every pipeline with the
  reason it was excluded, in place of *Details…* (the panel remains in the menu).
- `pop_pipecompare` prints a two-line summary instead of about 900 lines; the full log goes to
  `pipecompare_last_run.log` in `tempdir`. The menu item *Show dataset state and history* is
  removed (it only printed to the Command Window); `pipecompare.PipeCompare.state()` remains.

- A plan with ASR or ICLabel IC removal is now illegal when the clean_rawdata or ICLabel plugin is
  missing, with that reason, before the search starts; previously every candidate failed during it.
- ASR is also illegal when its filter cannot be built: without the Signal Processing Toolbox,
  clean_rawdata has it only for 100, 128, 200, 256, 300, 500 and 512 Hz, and at other rates it
  returned the data unchanged, so ASR candidates silently did nothing.
- Simple mode, *Standard*: bad channels are detected once (kurtosis, z = 5) and ICA is fitted once,
  before the filters, so all filter choices share one decomposition: 108 pipelines and 1 ICA
  instead of 432 pipelines and 48 ICAs. *Full* is removed from the simple mode (it was always above
  the search limit); ASR stays available in the panel and from scripts.
- Simple mode shows a progress window (pipelines done, time left) with *Stop*; stopping keeps the
  pipelines already run and the result covers those. Scripts get the same through the new
  `progress` option of `optimize`.
- The simple-mode result window says in one sentence which pipeline to use and why; columns and
  buttons use plain words (*Use this pipeline*, *Details…*).

## 0.8.0 (2026-10-04)

**Renamed: NeuroQC is now PipeCompare.** This is an incompatible change:
- Package `+neuroqc` → `+pipecompare`, class `NeuroQC` → `PipeCompare`
  (`pipecompare.PipeCompare.optimize`, `.adopt`, …), `eegplugin_pipecompare`,
  `pipecompare_setup`.
- Error IDs `PipeCompare:…`; Command Window prefix `[PipeCompare]`; base variable
  `pipecompare_result`; menu tag `pipecompare_menu`; environment variable
  `PIPECOMPARE_REAL_SET`.
- New datasets carry `EEG.etc.pipecompare`, and history lines are tagged `% PipeCompare`.
- The segment event type is `pipecompare_seg`.

**Compatibility.**
- Datasets adopted with NeuroQC still work: a trial rule they carry under `EEG.etc.neuroqc` is
  cleared before a search, as the new field is, and their `% NeuroQC` history lines are still
  recognized as NeuroQC's own.
- Checkpoint folders written by NeuroQC 0.7 cannot be resumed (other class names and search
  identity); run those searches again.
- Install the plugin folder as `PipeCompare` (or `PipeCompare0.8.0`) under `eeglab/plugins/`,
  and remove the old `NeuroQC` folder, or both menus appear.

**Added**
- Simple mode: EEGLAB > Tools > PipeCompare > *Compare pipelines…* (`pop_pipecompare`). It takes three
  choices: data type, a measure (ERP CORE component presets or a frequency band), and a recipe
  (filters, standard, full). It shows a live pipeline count, a result window, and an
  EEGLAB-style command in ALLCOM. The panel becomes *Advanced panel…*.
- Band power for continuous data (e.g. resting state):
  `Contract('analysis', 'bandpower', 'segment', T, 'bands', ...)`. Segments are marked with
  `eeg_regepochs` and paired by urevent. The score is log10 band power (Hann taper), and the
  signal check uses a sinusoid at the band centre. Dependent segments are compared with a
  moving-block bootstrap. Event-related band power is available with `conditions` + `epoch`.
  ERP results are unchanged.

## 0.7.1 (2026-10-04)

Bug fixes, cleanup and repository standards (plan stages 1–5), plus the evaluation corrections
made just before them (commit e6555f0).

**Changes to results.** Two changes can alter the ranking compared with 0.7.0:
- The ranking objective is the gain-corrected SME (SME divided by the candidate's signal gain;
  [docs/METHODS.md](docs/METHODS.md), section 2). A pipeline that only scales the data no longer
  looks more precise.
- The bootstrap uses B = 1999 (999 for peak measures) and an exact order-statistic quantile.

**Fixed**
- `writeScript(r, [], f)` and `script(r)` stop with the reason when there is no single
  recommendation, instead of writing an empty pipeline; `script()` includes the preparation
  lines (e.g. volts → µV).
- Closing the panel during a search, Inspect or Adopt no longer ends in an error.
- Interpolation and ICLabel steps are excluded before the search when the dataset has no
  channel locations; a channel without a position is never reported as interpolated.
- Event types are matched case-sensitively, as `pop_epoch` does, and the near match is named.
- The trials that are scored and the trials a candidate outputs come from one rule.
- Epochs marked but not removed are reported in the candidate's note.
- The failure-reason summary keeps each reason whole.
- No copy of the whole recording as double for the checkpoint identity or the line-frequency
  check. The checkpoint identity digest is unchanged, so 0.7.0 checkpoint folders still resume.

**Changed**
- The panel checks the current dataset cheaply every second and fully at least every 5 s.
- Menu callbacks use EEGLAB's error handling; no `addpath` in the plugin entry.
- New `result.robustness`: the multiverse summary of each measure over the feasible pipelines.
- One version number (`NeuroQC.Version`); the panel's text parsing lives in `PanelText` and
  `PanelValues`, with unit tests.
- README reorganized (quick start, limitations, tests); the panel reference is in
  [docs/PANEL.md](docs/PANEL.md) and the method in [docs/METHODS.md](docs/METHODS.md).
- CI runs the tests that need no window (MATLAB + EEGLAB on GitHub Actions).

## 0.7.0

The current architecture: NeuroQC works on the dataset that is current in EEGLAB. It runs every
legal pipeline of a plan (never sampled), scores the SME of the contract's ERP measures, and
checks the preservation of a known signal with the same decisions as the real data. The ranking
uses simultaneous bootstrap intervals and a stratum per reference, and recommends the least
aggressive of the candidates that are not distinguished from the best. Results can be adopted as
an EEGLAB dataset or exported as a script. 0.6-era features were removed: sampled search, the
spectral mode, Pareto and priority objectives, external QC, and the showcase site.
