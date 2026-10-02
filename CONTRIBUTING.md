# Contributing

Thanks for your interest in NeuroQC!

The code is published under the **MIT License**, but code PRs are not accepted at this stage
(fork and adapt freely). The most useful contributions today are:

## Documentation

- Fix typos, broken steps or stale screenshots — open a PR against `main`.
- Found a wrong or dead link? The `docs-links` CI job should catch it; if it slipped through,
  please open an issue with the file and heading.
- All new documentation content should follow the existing style:
  - Relative links only (no absolute local paths).
  - **Never commit real subject data, real names, or local filesystem paths.**

## Screenshots

Screenshots must come from the **synthetic** demo dataset
(`neuroqc.inspect.SyntheticEEG`) — never from real recordings.

## Issues

Use the issue templates:

- 🐛 **Bug report** — problems in this repository (docs, screenshots, configs, examples, plugin entry files)
- 💡 **Feature request** — documentation, GUI or workflow ideas

## Pull requests

1. One logical change per PR.
2. Keep the `docs-links` CI check green (it validates every relative link offline).
3. Fill in the pull request template.

## Scope

This repository ships the plugin source, documentation and demo assets. Large new feature
proposals belong with the maintainer rather than in this tracker.
