# Manual check: native EEGLAB dialogs from the panel

The automated tests cover what the panel does with a dialog's result (the command EEGLAB returns,
the copy it ran on). They cannot click inside an EEGLAB dialog. This check takes about 10 minutes.
Run it when no other process is driving MATLAB.

```matlab
cd /path/to/NeuroQC; addpath(pwd, fullfile(pwd, 'tests'));
eeglab;                                   % main window
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10))); eeglab redraw
neuroqc.NeuroQC.app();                    % or EEGLAB > Tools > NeuroQC > Optimize from current dataset...
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
| 6 | *Add component…*: P3, 0.3, 0.5, mean; then pick Pz P3 P4 in the channel window. *Set ROI…* again. | Components field shows the ROI; Objective list contains `P3.mean`. |
| 7 | *View ERP (EEGLAB)…* | EEGLAB's `pop_timtopo` opens on the preview (title says NeuroQC preview). |
| 8 | Add `lowpass`, select it, *Configure in EEGLAB…*: higher edge 30. Again with 40. | Values column: `cutoff = {30, 40}`. The step stays `lowpass`. |
| 9 | Add `reject_threshold`, *Configure in EEGLAB…*: limits −60 / 120. | A question naming the asymmetric limits. *Only the step's values*: `uv = 120` added. |
| 10 | Repeat 9 and choose *Keep whole command*. | The step becomes the EEGLAB workflow (`pop_eegthresh` … then `pop_rejepoch`), both lines shown in the details area. |
| 11 | Add `highpass`, *Configure in EEGLAB…* with a band-pass 0.5–30 Hz, *Keep whole command*; then again with 1–30 Hz. | One step, `locutoff = {0.5 \| 1}  [2 combinations]`; *Edit values…* lists every argument. |
| 12 | *Skipping allowed on/off*, *Must come before…* | Effective column gains `none (skip)`; the order rule appears under the buttons. |
| 13 | Select `reref` (Add), *Apply now in EEGLAB*: average reference. | The History list gains a `reref` row; EEGLAB shows the new dataset. |
| 14 | *Chan. locations…* | `pop_chanedit` opens on the current dataset; OK updates it (history row). |
| 15 | *Options…*: choose a checkpoint folder. *Run search*. | Status shows done; results appear; details area shows the selected row in full. |
| 16 | Select a result, *Inspect selected (EEGLAB)…* > candidate > *Scroll data*. | `eegplot` titled `NeuroQC candidate n (not adopted)`; ALLEEG unchanged. |
| 17 | Make the window small. | The panel scrolls; no part is squeezed to nothing. |

Report any row whose result differs from the expected column.
