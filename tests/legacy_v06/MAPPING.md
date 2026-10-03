# The 0.6 test suite and where its checks now live

The 0.6 suite (`NeuroQC-gh-tests`, 252 tests, all passing on historical revision `2dd5ef3`) targets the 0.6 API: the
four-tab wizard, GoalRanker, recipes, receipts and the drift gate. Most of that API no longer exists,
so the files cannot run against 0.7 unchanged. Each file is mapped below to one of four outcomes:

- **Covered**: the invariant is checked by a 0.7 test, named in the table.
- **Ported**: rewritten for the current API in `tests/test_legacy_invariants.m`.
- **Obsolete**: the feature was removed on purpose ([REVIEW.md](../../REVIEW.md), sections 2 and 5),
  so there is nothing left to test.
- **Changed**: the 0.6 behaviour was found to be wrong. The 0.7 test checks the corrected behaviour.

| 0.6 file | Main invariants | 0.7 |
|---|---|---|
| `test_action_gate` | wizard gates before generate/compare; missing events block generation | Obsolete (wizard). Missing events: **ported** (`testMissingEventTypeFailsBeforeProcessing`). Unknown step: covered (`Catalog.get` errors, `test_plan`). |
| `test_algo_fixes` | Pareto sentinel, Spearman–Brown, GoalRanker degenerate cases, flat signals | Obsolete (Pareto-by-weights, split-half). Spectral sampling-rate handling: covered (`testSpectralProbe`, `testSpectralObjectiveEndToEnd`). Time-locking event fail-closed: **ported**. Fixed order fail-closed: covered (`test_plan/testFixedOrderConflictIsExplainedNotRearranged`). |
| `test_budget_sampling` | budget verdicts, deterministic sampling | Covered (`test_plan`: budget refusal, sampling reproducible/distinct/labelled). |
| `test_capture_inventory` | every step has a dialog capture path | **Ported** (`testEveryCatalogStepHasANativeDialog`); capture covered (`test_eeglab/testCaptureReturnsCommandWithoutTouchingData`). |
| `test_checkpoint` | history parsing of a dataset's processing stage | Covered (`test_history`). Menu entry tests: obsolete (plugin menu reduced to three items). |
| `test_eval_checkpoint` | interrupted evaluation resumes and equals one-shot | Covered (`test_engine/testResumeEqualsUninterruptedSearch`). |
| `test_exhaustive` | full coverage, invalid/duplicate handling, SNR must not choose the winner, arbitrary order | Covered (`test_plan` brute-force equality, legality; `test_engine` end-to-end, where the 2 Hz filter is rejected despite the lowest SME). |
| `test_goal_ranker` | weight profiles, Pareto reasons, external QC smoke | Obsolete (weights). Changed: Pareto set (`test_statistics/testParetoAndUnitSafety`), external QC (`testExternalQcColumnsAndLimits`). |
| `test_handoff_regression` | frozen prefix, defaults do not reappear, unit/ICA invariants, bad-channel detection does not imply removal | Prefix: obsolete (the live dataset is the start). Units: covered (`testVoltDataAreConvertedNotMisread`). Detection without removal: **ported**. Fixed values: **ported** (`testFixedValueIsNotReplacedBySuggestions`). |
| `test_lock_ux` | lock specification UI round trips | Obsolete (six lock mechanisms replaced by one rule, REVIEW.md section 5). |
| `test_mvp` | trial selection, unit round trip, IC policy, hash, external QC | Covered: trial rule, units, ICA, external QC. Hash: obsolete (fingerprint, `test_eeglab`). |
| `test_neuroqc_all` | contract round trip, estimate/rank, inspectors, ERP analysis, hard constraints, export script | Covered: contract validation, constraints, ranking (`test_statistics`), export (`testWriteScriptReproducesCandidate`). Inspectors: obsolete (`NeuroQC.state()`). |
| `test_order_search` | every legal permutation, pins, no silent truncation, existing ICA, all-off never runs all | Covered (`test_plan` order search, pin/before, budget). All-off: **ported** (`testNoneOnlyChoiceNeverBecomesRunAll`). |
| `test_resume` | stage collapse, mismatched EEG, remaining-only resume | Covered (resume test; stale-state guard `testAdoptRefusesStaleStartingDataset`). |
| `test_scope_integrity` | invalid explicit thresholds never default, dataset binding, parallel equals serial | **Ported** (`testInvalidExplicitValueIsRefusedNotDefaulted`); covered (`testParallelEqualsSerial`, `testSourceDatasetIsNeverModified`). |
| `test_semiauto` | native steps, no silent method substitution, explicit adoption | Covered (`testNativeCommandStep`, adopt tests). |
| `test_userflow_repair` | wizard flows and session restore | Obsolete (wizard and session files). |
| `test_wizard_display` | wizard layout | Obsolete (wizard). The panel is covered by `test_eeglab/testPanelFollowsLiveDatasetAndRuns`. |

To run the 0.6 suite itself, check out historical revision `2dd5ef3` and run `run_all_tests` from the separate `NeuroQC-gh-tests` checkout.
The [0.6 defect reproduction script](https://github.com/abwoo/NeuroQC/blob/8cf444c/tests/v06_reproductions.m)
is retained in Git history rather than the current test suite. Run that script with the 0.6 package on the path.
