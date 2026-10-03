# Archived 0.6 modules

These modules come from NeuroQC 0.6 (historical revision `2dd5ef3`). Nothing in 0.7 calls them, so they
were moved out of the `+neuroqc` package on the MATLAB path. They are kept unchanged, with their
package structure, for reference and for reproducing 0.6 results.

| Module | 0.6 purpose | In 0.7 |
|---|---|---|
| `neuroqc.inspect.DatasetInspector` | channel/time/frequency/event health report (PASS / WARNING / REVIEW / FAIL) before preprocessing | `neuroqc.NeuroQC.state()` and the panel read the live dataset, its `EEG.history` and data/history inconsistencies (`neuroqc.live.DataState`) |
| `neuroqc.inspect.EventInspector` | event statistics, interval anomalies, timeline | event types and counts in `DataState`; trials per condition under the trial rule in the panel |
| `neuroqc.utils.estimateRank` | numerical rank to limit the ICA dimension after average reference or interpolation | `pop_runica` (EEGLAB 2026) detects the rank itself and adds `'pca', rank` when NeuroQC's ICA step calls it |

The 0.6 tests that covered the inspectors are mapped in
[tests/legacy_v06/MAPPING.md](../../tests/legacy_v06/MAPPING.md) (row `test_neuroqc_all`: obsolete).

To use them again, add this folder to the MATLAB path (MATLAB merges the `+neuroqc` package folders):

```matlab
addpath(fullfile(fileparts(which('neuroqc_setup')), 'archive', 'v06'));
report = neuroqc.inspect.DatasetInspector.inspect(EEG);
```
