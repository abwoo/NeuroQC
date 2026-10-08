# Manual check: native EEGLAB dialogs from the panel

The automated tests cover what the panel does with a dialog's result (the command EEGLAB returns,
the copy it ran on). They cannot click inside an EEGLAB dialog. This check takes about 10 minutes.
Run it when no other process is driving MATLAB.

```matlab
cd /path/to/PipeCompare; addpath(pwd, fullfile(pwd, 'tests'));
eeglab;                                   % main window
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10))); eeglab redraw
pipecompare.PipeCompare.app();                    % or EEGLAB > Tools > PipeCompare > Advanced panel...
```

For every dialog: **OK** must fill the panel as described, **Cancel** must change nothing and show no
error. The History list must keep 1 row unless the step says *Apply now*.

| # | Do | Expected |
|---|---|---|
| 1 | *Add from events…*: pick `11` (the list shows counts), name it `target`. Repeat with `31` / `standard`. | Conditions: `target: 11; standard: 31`; the green line shows the trials per condition. |
| 2 | *Choose trials…* > *Time ranges (EEGLAB pop_select)*: keep time 20–60 s. | Trials label: `time ranges [20 60] s (EEG = pop_select(...))`; counts drop to `x of 10`. Then *All trials*. |
| 3 | *Choose trials…* > *EEGLAB event selection*: in `pop_selectevent`, select events by latency. | Trials label: `n selected events (...)`. Then *All trials*. |
| 4 | *EEGLAB pop_epoch…*: set limits −0.3 0.9. | Epoch field `-0.3 0.9`. |
| 5 | *EEGLAB pop_rmbase…*: set −300 0 ms. | Baseline field `-0.3 0`. |
| 6 | *Add component…* > *your own component…*: P3, 0.3, 0.5, mean; then pick Pz P3 P4 in the channel window. *Set ROI…* again. *Add component…* > N2pc: tick `target` as the condition with the target on the left. Then *Measure* > *Band power*, *Add band…* > `alpha (8-13 Hz)`, OK in the channel window; then back to *ERP components*. | Components field shows the ROI; Objective list contains `P3.mean`. N2pc adds `N2pc: 0.2 0.275 @ PO7 PO8 # contra PO8 PO7`. With band power: conditions, epoch and baseline greyed, the Bands field shows `alpha: 8 13 @` all EEG channels, Objective list `alpha.logpower`; back on ERP the P3 is still there. |
| 7 | *View ERP (EEGLAB)…* | EEGLAB's `pop_timtopo` opens on the preview (title says PipeCompare preview). |
| 8 | Add `lowpass`, select it, *Configure in EEGLAB…*: higher edge 30. Again with 40. | Values column: `cutoff = {30, 40}`. The step stays `lowpass`. |
| 9 | Add `reject_threshold`, *Configure in EEGLAB…*: limits −60 / 120. | A question naming the asymmetric limits. *Only the step's values*: `uv = 120` added. |
| 10 | Repeat 9 and choose *Keep whole command*. | The step becomes the EEGLAB workflow (`pop_eegthresh` … then `pop_rejepoch`), both lines shown in the details area. |
| 11 | Add `highpass`, *Configure in EEGLAB…* with a band-pass 0.5–30 Hz, *Keep whole command*; then again with 1–30 Hz. | One step, `locutoff = {0.5 \| 1}  [2 combinations]`; *Edit values…* lists every argument. |
| 12 | *Skipping allowed on/off*, *Must come before…* | Effective column gains `none (skip)`; the order rule appears under the buttons. |
| 13 | Select `reref` (Add), *Apply now in EEGLAB*: average reference. | The History list gains a `reref` row; EEGLAB shows the new dataset. |
| 14 | *Chan. locations…* | `pop_chanedit` opens on the current dataset; OK updates it (history row). |
| 15 | *Options…*: choose a checkpoint folder. *Run search*. | Status shows done; results appear; details area shows the selected row in full. |
| 16 | Select a result, *Inspect selected (EEGLAB)…* > candidate > *Scroll data*. | `eegplot` titled `PipeCompare candidate n (not adopted)`; ALLEEG unchanged. |
| 17 | Make the window small. | The panel scrolls; no part is squeezed to nothing. |
| 18 | Start *Run search* on a plan that takes a while, then close the panel window while it runs. | No error in the Command Window when the search ends; the result is in `pipecompare_result`. Same for closing during *Inspect selected* and *Adopt selected*. |
| 19 | EEGLAB > Tools > PipeCompare > *Compare pipelines…* | Data `Continuous data with 2 event types: ERP measures or band power.`; Measure `(choose)` with ERP components, *your own window and electrodes*, bands and *your own band and electrodes*; no event selected; Compare: all steps ticked (bad channels, ICA, high-pass, low-pass, epoch rejection), the reference *as recorded*, *Epochs and baseline* ticked and greyed; *Run* greyed. |
| 20 | Select `11` and `31`, Measure `P3`, Compare *Filters only*; *Run* | Count `12 pipelines will be compared`; a progress window counts `n of 12 pipelines done, about … left` (from the third); then a window `Pipeline comparison` whose first line starts `Use pipeline n: high-pass … Hz, low-pass … Hz`, with the recommendation first (`*`); ALLCOM gains `EEG = pop_pipecompare(EEG, ...)`. |
| 21 | In the result window: *Save script…*, then *Use this pipeline*, then tick *Show all pipelines* | A `.m` file is written whose header says it runs on any dataset (`pipecompare.PipeCompare.apply`); while building, a progress window says the pipeline is built from the start; then `Pipeline n is now the current EEGLAB dataset. It is not saved yet…` and a new EEGLAB dataset appears; the table lists every pipeline with a *why excluded* column. |
| 22 | *Compare pipelines…* again, Compare *Standard*; *Run*, then *Stop* after a few pipelines | Count `12 pipelines will be compared (1 ICA decomposition)`; after *Stop* the result window starts `Stopped after n of 12 pipelines` and lists the finished ones; pipelines not run show `not run`. |
| 23 | *Compare pipelines…* again, Compare *Standard*; then *Advanced…* | The panel opens with conditions, epoch, baseline, the P3 component and the standard plan (bad channels, ICA, filters, …) filled in. |
| 24 | On a dataset where one event type has fewer than 10 events: select only that type, Measure `P3`, Compare *Filters only*; then select a second type; then tick *Score the selected event types as one condition* | First `… has n events; each condition needs at least 10.` with *Run* greyed; with two types the message suggests the tick box; after ticking, *Run* is on. |
| 25 | *Compare pipelines…* again, Measure *ERP: your own window and electrodes…*, type `250 500`, *Electrodes…* > `Cz`, `CPz`; select `11`; Compare *Filters only* | A window/electrodes row appears; the count shows `12 pipelines will be compared`; *Run* on. With Measure *Band power: your own band…* and `8 12`, the electrodes read `n electrodes` (all EEG) and *Run* is on. |
| 26 | *Compare pipelines…*, Measure `P3`, events `11` and `31`, Compare *Standard*, Reference *average*; then *Advanced…* | The count stays `12 pipelines will be compared (1 ICA decomposition)`; the panel's plan lists `reref` after `badchannels` and before `ica`. |
| 27 | After row 22, *Advanced…* and look at the `badchannels` and `reject_threshold` steps | `badchannels` shows `detectHighpass` 1 and `exclude` with the EOG channels (e.g. `VEOG`, `HEOG`); `reject_threshold` shows the same `exclude`. |
| 28 | *Compare pipelines…*, Measure `P3`, events `11` and `31`; untick *ICA*; then *Filters only*; then Reference *average*; then *as recorded* | `12 pipelines will be compared` without ICA; after *Filters only* `12 pipelines` with only the filters ticked; with *average* the bad-channel box is ticked and greyed (*always before an average reference*); with *as recorded* it is unticked again. On an epoched dataset the two filter boxes are greyed with *the data are already epoched*. |

Report any row whose result differs from the expected column.
