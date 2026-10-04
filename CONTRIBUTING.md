# Contributing

Thanks for your interest in PipeCompare!

The code is published under the **MIT License**, but code PRs are not accepted at this stage
(fork and adapt freely). The most useful contributions today are bug reports and documentation
fixes.

## Issues

Use the issue templates:

- **Bug report**: MATLAB and EEGLAB versions, steps to reproduce, Command Window output.
- **Feature request**: the problem in your analysis and what you would like.

Never attach real subject data; a synthetic dataset (`tests/nqc_synth.m`) or a description of the
data's shape is enough.

## Documentation

- Fix typos or stale steps with a PR against `main`.
- Relative links only (the `docs-links` CI job checks them offline).
- Never commit real subject data, real names, or local filesystem paths.

## Tests

```matlab
addpath(fullfile(pwd, 'tests')); results = run_all();
```

CI runs the suites that need no window (`test_history`, `test_plan`, `test_panel_text`,
`test_statistics`, `test_invariants`). The others need EEGLAB's window and run locally; panel
changes are also checked by hand with `tests/MANUAL_GUI_CHECK.md`.
