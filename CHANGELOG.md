# Changelog

All notable changes. Versions follow `NeuroQC.Version`; each release has a git tag `vX.Y.Z`.

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
