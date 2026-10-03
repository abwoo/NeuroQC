# Manual check: native EEGLAB dialogs from the panel

The automated tests cover what these buttons do with a dialog's result: capturing the command, and
applying it through EEGLAB's code path. They cannot click inside an EEGLAB dialog. This check takes
about 3 minutes.

```matlab
cd /path/to/NeuroQC; addpath(pwd, fullfile(pwd, 'tests'));
eeglab;                                   % main window
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10))); eeglab redraw
neuroqc.NeuroQC.app();                    % or EEGLAB > Tools > NeuroQC > Optimize from current dataset...
```

| # | Do | Expected |
|---|---|---|
| 1 | Select step type `highpass` and click **Fix via EEGLAB dialog**. Enter a lower edge of 0.5, then click OK. | EEGLAB's own `pop_eegfiltnew` dialog opens. The plan gets a fixed `native` step whose command contains `'locutoff',0.5`. The History list still has 1 row, because the dataset is unchanged. |
| 2 | Repeat step 1, but click **Cancel** in the dialog. | No step is added and no error appears. |
| 3 | Select `reref` and click **Apply now in EEGLAB**. Choose average reference, then click OK. | The History list gains a `reref` row, the EEGLAB main window shows the updated dataset, and `EEG.history` ends with `pop_reref`. |
| 4 | Repeat step 3, but click **Cancel**. | Nothing changes and no error appears. |

Report any row whose result differs from the expected column.
