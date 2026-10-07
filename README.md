<p align="center"><img src="docs/assets/banner.svg" alt="PipeCompare" width="640"></p>

**Data-driven comparison of EEG preprocessing pipelines in EEGLAB.**

[![MATLAB tests](https://github.com/abwoo/PipeCompare/actions/workflows/matlab-tests.yml/badge.svg)](https://github.com/abwoo/PipeCompare/actions/workflows/matlab-tests.yml)
![Version](https://img.shields.io/badge/version-0.9.2-2f6fed)
![MATLAB](https://img.shields.io/badge/MATLAB-R2021b%2B-orange)
![EEGLAB](https://img.shields.io/badge/EEGLAB-2024.2%2B-blueviolet)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

PipeCompare is an [EEGLAB](https://github.com/sccn/eeglab) plugin that chooses how to preprocess
an EEG recording, based on the recording itself. It compares complete preprocessing pipelines
(filters, reference, bad channels, ICA with ICLabel, epoch rejection) and recommends the one that
measures your ERP or band power most precisely, without distorting it.

## Contents

- [What PipeCompare does](#what-pipecompare-does)
- [What happens to your data](#what-happens-to-your-data)
- [Features](#features)
- [Where PipeCompare fits in an analysis](#where-pipecompare-fits-in-an-analysis)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Scripting interface](#scripting-interface)
- [How a pipeline is chosen](#how-a-pipeline-is-chosen)
- [Outputs](#outputs)
- [Limitations](#limitations)
- [Testing](#testing)
- [Documentation](#documentation)
- [Citation](#citation)
- [License](#license)

## What PipeCompare does

Before an ERP amplitude or a band power can be measured, the raw recording has to be cleaned: it
is filtered, re-referenced, bad channels are found and repaired, eye and muscle artifacts are
removed with ICA, the data are cut into epochs and noisy epochs are rejected. Every one of these
steps has settings, such as the high-pass cutoff, the ICLabel threshold for removing a component
or the amplitude limit for rejecting an epoch. One complete set of steps and settings is a
*pipeline*. Published studies use many different pipelines, and the choice changes how much noise
is left in the final measurement. In practice the settings are usually copied from an earlier
paper or kept out of habit, without checking how well they work on the data at hand.

PipeCompare makes this choice from the data, in these steps:

1. **It reads the dataset open in EEGLAB**, including what has already been done to it (from
   `EEG.history`), so earlier processing is neither repeated nor ignored.
2. **You say what will be measured**: an ERP component (mean amplitude, peak amplitude or peak
   latency in a time window, at the electrodes you choose, time-locked to the events you choose),
   or the power in a frequency band. Presets cover the ERP CORE components and the classic
   frequency bands.
3. **It builds every pipeline** from the steps and settings left open. The *Standard* recipe, for
   example, compares up to 108 combinations of high-pass and low-pass filters, ICLabel thresholds and
   epoch-rejection thresholds; you can also decide the steps and values yourself.
4. **It runs each pipeline** with EEGLAB's own functions, on your data.
5. **It removes pipelines that harm the data.** A pipeline is excluded when it keeps too few
   trials, interpolates too many channels, or changes the brain signal. To check the last point,
   a known artificial signal is added to a copy of the data and carried through the same pipeline;
   if it comes out smaller, shifted or reshaped, the pipeline is excluded.
6. **It ranks the rest by precision.** The measure is the standardized measurement error (SME;
   Luck et al., 2021): how much your averaged value would vary if the experiment were repeated.
   It is corrected for how much each pipeline shrinks the signal, so a pipeline cannot look good
   just by making everything smaller. A bootstrap test then finds the pipelines that cannot be
   told apart from the best.
7. **It recommends one pipeline**, among those as good as the best the one that keeps the most
   trials and changes the signal least, and explains why. You can adopt it as a new EEGLAB dataset,
   already epoched and cleaned and ready to average, or save it as a MATLAB script to process your
   other recordings the same way.

The comparison never uses an experimental effect (condition differences, p-values), so selecting a
pipeline does not bias the statistical test you run afterwards.

PipeCompare is useful when you start working with a new dataset, paradigm or recording setup and
want preprocessing settings with a documented, data-based reason, or want to check whether your
usual settings suit these data. It works on one recording at a time, and covers ERP and band-power
measures; time-frequency, connectivity and source analysis are not covered (see
[Limitations](#limitations)).

## What happens to your data

With the *Standard* recipe, every pipeline runs the steps below in this order. Steps marked
*compared* are tried with several settings; the others are done once, in the same way for every
pipeline, so that the comparison is about the settings that matter.

1. **Channels removed earlier are put back** (only with the average reference). If you deleted EEG
   channels before PipeCompare, they are interpolated back first, so that the average is taken
   over the whole montage.
2. **Bad channels are found and repaired.** A channel is marked bad when its signal is much
   spikier (kurtosis) or much noisier (joint probability, e.g. a poorly connected electrode) than
   the other channels, more than 5 standard deviations away. The test looks at a copy of the data
   high-passed at 1 Hz, so slow drifts are not mistaken for bad channels. Bad channels are then
   interpolated from their neighbours (spherical interpolation), so the dataset keeps all its
   channels. EOG, ECG and EMG channels (by channel type, or by name such as VEOG or ECG1) are never
   tested. A pipeline that interpolates more than 20 % of the channels is excluded.
3. **Re-reference** (if you chose the average reference). It comes after the bad channels are
   repaired, so a bad channel cannot spread its noise into every other channel; non-EEG channels
   are left out of the average. Data that were already average-referenced are averaged again,
   which removes the repaired channels' share of the earlier average.
4. **ICA is computed once** (extended Infomax, `pop_runica`) on a copy high-passed at 1 Hz, which
   gives a cleaner decomposition. All pipelines share this one decomposition, which saves the
   largest part of the computing time.
5. **High-pass filter**, *compared*: 0.1, 0.3, 0.5 and 1 Hz.
6. **Low-pass filter**, *compared*: 20, 30 and 40 Hz.
7. **Artifact components are removed with ICLabel**, *compared*: a component is removed when
   ICLabel gives it a probability of at least 0.7, 0.8 or 0.9 of being eye, muscle, heart, line
   noise or channel noise.
8. **Epochs are cut** around the events you chose, and the **baseline** is subtracted.
9. **Noisy epochs are rejected**, *compared*: an epoch is dropped when any EEG channel exceeds
   ±75, ±100 or ±150 µV (non-EEG channels are ignored).

One more step can be ticked; it is not part of *Standard*. **Repairing epochs instead of rejecting
them**: an epoch in which only 1 to 3 channels exceed the rejection limit is kept, and those
channels are interpolated from the other channels within that epoch only; an epoch with more
channels over the limit is still rejected. It does not add pipelines (it uses the limit being
compared). See [Repairing epochs with a few bad channels](#repairing-epochs-with-a-few-bad-channels).

That makes 4 × 3 × 3 × 3 = 108 pipelines for an ERP. The *Filters only* recipe compares only
steps 5 and 6. For band power, the data are cut into 2 s segments instead of epochs, and only the
filter edges nearest the band, outside it, are used (a filter outside a band does not change its
power), which leaves 9 pipelines. In the advanced panel or a script you can change every list
above, change the order, allow a step to be skipped, and add other steps: line-noise removal (the
50 or 60 Hz mains frequency is detected from the recording), ASR (artifact subspace
reconstruction), resampling, rejection by joint probability or kurtosis, a reference to chosen
channels, or any operation from EEGLAB's menus, plugins included.

Along the way PipeCompare also takes care of the following, so you do not have to:

- **It checks that the channel labels fit the electrode positions** before the run, and names
  channels whose signal does not look like their neighbours' (see [Montage check](#montage-check)).
  This is a warning only.
- **It tells you when ICA did nothing useful**: when ICLabel recognised almost none of the
  components, or no pipeline removed any component, and when the recording was too short for ICA
  (see [When ICA does nothing](#when-ica-does-nothing)).
- **It tells you when one channel caused most rejected epochs**, which usually means it is a bad
  channel the detection missed (see [Reading the result](#reading-the-result)).

- **It respects what was done before.** Processing already applied (read from `EEG.history`) is
  listed and not repeated. A filter the data already have is kept as one of the choices
  (e.g. *low-pass as in the data (30 Hz)*) instead of forcing a stricter one, and you are warned
  when that earlier filter alone already distorts the signal you measure. When ICA was already run
  and components removed, ICA is not compared again.
- **It leaves out what the data cannot support, and says why.** Without channel locations,
  interpolation and ICLabel are left out; without ICLabel installed, ICA is left out; on data that
  are already epoched, filters are not compared (they must run before epoching) and the data keep
  their own epochs as long as they hold the measurement window. A condition with too few events
  (fewer than 10) is flagged before the run.
- **It checks units.** Data stored in volts are recognised from their amplitude and compared in µV.
- **It measures lateralized components correctly.** N2pc and LRP are scored as ERP CORE does,
  contralateral minus ipsilateral, from the event types you give for each side.
- **It handles long runs.** A progress window shows the step running and the time so far and left;
  *Stop* keeps the pipelines already finished. A search can be saved to a checkpoint folder and
  resumed, and can run in parallel with the Parallel Computing Toolbox.
- **It keeps everything reproducible.** The adopted dataset's `EEG.history` contains every EEGLAB
  command that produced it, and *Save script…* writes the same steps as a MATLAB function that makes
  the data-driven decisions (bad channels, components, rejected epochs) anew on each recording you
  run it on.

## Features

- **Works on the dataset you have open.** Reads the current EEGLAB state (continuous or epoched
  data, channel locations, ICA decomposition, reference, sampling rate) and parses `EEG.history`,
  so earlier processing is taken into account.
- **ERP and band-power measures.** Mean amplitude, peak amplitude and peak latency for event-related
  data. Log band power for continuous recordings such as resting state.
- **Presets for common analyses.** ERP CORE parameters (Kappenman et al., 2021) for N170, MMN,
  N2pc, N400, P3, LRP and ERN, and standard delta, theta, alpha and beta bands.
- **User-defined search space.** Choose the steps and their order, fix some values and let others
  vary, allow steps to be skipped. Any EEGLAB menu operation that takes and returns the dataset,
  plugins included, can be added as a step and configured in its own EEGLAB dialog.
- **Exhaustive search.** Every admissible pipeline is run, with shared leading steps computed only
  once. The search is never sampled or truncated.
- **Signal-preservation check.** A known signal is carried through every pipeline with the same
  data-driven decisions as the real data (bad channels, ICA, rejected epochs, removed components,
  ASR reconstructions); steps whose decisions cannot be replayed are re-run on it and flagged (see
  [Limitations](#limitations)). Pipelines that distort it are excluded.
- **Statistically controlled ranking.** A paired bootstrap with simultaneous intervals identifies
  the pipelines that cannot be distinguished from the best, controlling the error rate across all
  candidates.
- **Reproducible output.** Each candidate's full list of EEGLAB commands, an exportable script, and
  adoption as a new dataset whose `EEG.history` reproduces it.
- **Practical for long searches.** A progress window that can stop a search and keep the finished
  pipelines, checkpointing and resume, and optional parallel execution.

## Where PipeCompare fits in an analysis

PipeCompare replaces the preprocessing part of a single-recording EEGLAB analysis:

1. **Before PipeCompare** (done by you): import the recording, add channel locations
   (*Edit > Channel locations*), and, if needed, remove channels that are not EEG or that you know
   are broken.
2. **PipeCompare**: filtering, reference, bad-channel detection and interpolation, ICA with
   ICLabel, epoching, baseline correction and epoch rejection. These are the steps it compares, so
   they should not be applied beforehand.
3. **After PipeCompare**: average the epochs into ERPs (or compute spectra for band power) and
   measure. The adopted dataset is already filtered, re-referenced and cleaned, so these steps are
   not repeated.

Processing that was already applied to the data is read from `EEG.history` and taken into account:
the dialog lists it, does not compare it again, and checks whether it already distorts the
measured signal. The cleanest comparison starts from the raw continuous recording, because then
every step is part of the comparison.

PipeCompare compares pipelines on one recording at a time. To process a whole study the same way,
choose the pipeline on a representative recording and run the saved script (*Save script…*) on
every recording; the script makes the data-driven decisions (bad channels, components, rejected
epochs) from each recording's own data.

## Requirements

| Component | Requirement |
|---|---|
| MATLAB | R2021b or later (see the tested versions below). GNU Octave is not supported: the interface uses `uifigure`. |
| [EEGLAB](https://github.com/sccn/eeglab) | 2024.2.1 or later. The PipeCompare menu and *Add EEGLAB menu step…* need EEGLAB's main window; scripts also run after `eeglab nogui` |
| EEGLAB plugins | firfilt (bundled with EEGLAB); ICLabel for IC removal; clean_rawdata for ASR |
| Optional | Parallel Computing Toolbox, for parallel execution; Signal Processing Toolbox, for ASR at sampling rates other than 100, 128, 200, 256, 300, 500 and 512 Hz and for faster low-frequency high-pass filtering |

MATLAB R2026a with EEGLAB 2026.0.0 is the combination run by hand
([docs/COVERAGE.md](docs/COVERAGE.md)). Continuous integration runs the full automated test suite
on MATLAB R2021b, R2023b, R2024b and the latest release with EEGLAB 2026.0.0, on the latest MATLAB
with EEGLAB 2024.2.1, 2025.1.0 and the current head of EEGLAB's default branch. MATLAB R2022b is
not in that list: in the test machines' virtual display one dialog test stops responding inside
MATLAB's own alert window, so that release is untested. Older MATLAB and EEGLAB releases have not
been tested. PipeCompare reads the current dataset from EEGLAB's base-workspace variables `EEG`, `ALLEEG`
and `CURRENTSET`, and stores adopted pipelines there.

## Installation

PipeCompare is listed in EEGLAB's extension manager
([list of EEGLAB extensions](https://sccn.ucsd.edu/eeglab/plugin_uploader/plugin_list_all.php)), so the simplest way to install it is from
inside EEGLAB. The other two ways are for computers without internet access in MATLAB and for
working with the source code.

Keep only one copy of PipeCompare in `eeglab/plugins/`. EEGLAB loads every plugin folder it finds,
so two copies (for example one from the extension manager and one unzipped by hand) both add
their menus and their functions shadow each other.

**From EEGLAB's extension manager (recommended)**

1. Start EEGLAB and choose **File > Manage EEGLAB extensions**.
2. Find **PipeCompare** in the list (typing its name in the search field narrows the list), tick
   it and press **Install/Update**.
3. The menu **Tools > PipeCompare** appears; if it does not, restart EEGLAB.

EEGLAB downloads the release zip and places it in `eeglab/plugins/PipeCompare<version>/`. When a
newer version is listed, the same window offers it, and installing it replaces the old folder.

**From a GitHub release**

1. Download `PipeCompare<version>.zip` from the
   [Releases](https://github.com/abwoo/PipeCompare/releases) page.
2. Unzip it into `eeglab/plugins/`. The folder must be named `PipeCompare` or
   `PipeCompare<version>`, because EEGLAB takes the plugin's name and version from the folder name.
3. Start or restart EEGLAB. The menu **Tools > PipeCompare** appears.

**From source**

```bash
git clone https://github.com/abwoo/PipeCompare.git
```

Either copy the cloned folder into `eeglab/plugins/` as above, or keep it elsewhere and register
it with the running EEGLAB:

```matlab
eeglab                                    % start EEGLAB first
pipecompare_setup                         % run from the PipeCompare folder
```

`pipecompare_setup` adds the menu to the running EEGLAB session only. Run it again after each
`eeglab` call, because EEGLAB rebuilds its menus.

## Quick start

### From the EEGLAB menu

1. Load a dataset in EEGLAB.
2. Open **Tools > PipeCompare > Compare pipelines…**
3. Choose what to measure: an ERP component (with the event types it is time-locked to) or a
   frequency band, or your own time window or band with the electrodes you pick. The list only
   offers what the data support. The electrodes and time window of each ERP component are not
   taken from your data but from the published ERP CORE conventions (Kappenman et al., 2021),
   for example P3 at Pz, 300–600 ms. You can change a component's electrodes with
   **Electrodes…** next to its time window (for example Pz, CPz and POz for the P3); the window
   stays the convention's. N2pc and LRP keep their electrode pair, since they are scored as the
   difference between the two sides. When several electrodes are chosen, PipeCompare averages
   them first and scores that average waveform; for band power, the power of each chosen
   electrode is computed and then averaged. The simple mode scores one measure per run; to compare pipelines on several
   components at once, each with its own electrodes, use the advanced panel (*Add component…*).

   Then tick the steps you want. They are listed in the order they run, and that order is fixed,
   so you only decide which steps are done, never in which order:

   | Order | Step | What is compared |
   |---|---|---|
   | 1 | Bad channels: detect and interpolate | nothing (one fixed setting, see below) |
   | 2 | Reference: as recorded or average | nothing (your choice, the same in every pipeline) |
   | 3 | ICA: remove artifact components | the ICLabel probability above which a component is removed (0.7, 0.8, 0.9) |
   | 4 | High-pass filter | the cutoff (0.1, 0.3, 0.5, 1 Hz) |
   | 5 | Low-pass filter | the cutoff (20, 30, 40 Hz) |
   | 6 | Epochs and baseline (segments for band power) | always done |
   | 7 | Reject epochs over an amplitude limit | the limit (75, 100, 150 µV) |
   | 8 | Instead, repair epochs with up to 3 channels over the limit (optional) | nothing (it uses the limit of step 7) |

   Two buttons tick a usual set at once: **Standard**, preselected, ticks steps 1 to 7 (every
   step except the repair in line 8); **Filters only** ticks the two filters. Line 8 can only be
   ticked together with step 7, since it uses the same limit (see
   [Repairing epochs with a few bad channels](#repairing-epochs-with-a-few-bad-channels)).
   Ticking it does not change the number of pipelines. An unticked step is not done at all: for example,
   without the high-pass the data keep whatever high-pass they already had. Steps that these data
   cannot take are greyed out, with the reason next to them: on epoched data the filters (they
   must run before epoching), without channel locations bad-channel interpolation and ICA (ICLabel
   needs the locations), without the ICLabel plugin ICA, and ICA when the history shows that ICA
   components were already removed. When the average reference is chosen (or the data are
   already average-referenced), bad-channel detection is always ticked, because a bad channel in
   the average would spread into every channel. For band power, when ICA or epoch rejection is
   compared, each filter uses one cutoff, the one nearest the band outside it (outside the band a
   filter does not change its power), so the standard set gives 9 pipelines instead of 108; tick
   only the filters to compare their cutoffs.

   Bad channels are detected once and ICA is fitted once, before the filters, so every filter
   setting shares one decomposition. A channel is bad when its kurtosis (spiky) or joint
   probability (noisy, e.g. poor contact) is more than 5 SD from the other channels'. Both steps
   look at a 1 Hz high-passed copy, so slow drifts do not mislead them; the data themselves are
   filtered only by the settings being compared. EOG, ECG
   and EMG channels (by type or by name, such as VEOG) are not tested as bad channels and do not
   count in epoch rejection. The dialog shows how many pipelines will run before you
   start. Steps the data cannot support are left out, with the reason; for example, interpolation
   and ICLabel require channel locations, and for band power no filter edge inside the band is
   compared. Epoched data keep their own epochs when these hold the measurement window. N2pc and
   LRP are scored as ERP CORE measures them, contralateral minus ipsilateral: choose the event
   types of each side (target on the left and on the right; left-hand and right-hand responses).
   To compare ASR (artifact subspace reconstruction) or other steps, use the advanced panel or a
   script.

   Start from the raw continuous data. If your analysis uses the average reference, choose it in the
   **Reference** line of the step list rather than re-referencing beforehand: it is then applied in every pipeline after
   the bad channels are interpolated and before ICA. (Data already average-referenced are averaged
   again after the interpolation.) Steps already applied to the data are read from `EEG.history`
   and listed in the dialog; they are not compared again. A filter the data already have is kept
   as one of the choices (e.g. *low-pass as in the data (30 Hz)*), and the result warns when such
   a filter alone already distorts the measured signal. With the average reference, EEG channels
   removed before PipeCompare are interpolated back first, so the average covers the whole
   montage.
4. Press **Run**. A progress window shows how many pipelines are done, the step running now (for
   example *fitting ICA*), the time so far and the time left. Before the first pipeline is done
   (it runs the steps all pipelines share, such as ICA, which can take several minutes) the bar
   moves back and forth instead of filling. **Stop** ends the search and keeps the pipelines
   already finished. The Command Window prints each step and each finished pipeline as the
   search runs, then a summary; the same log is kept in `pipecompare_last_run.log` in MATLAB's
   `tempdir`.
5. The result window says which pipeline to use and why, naming each pipeline by its settings
   (for example *high-pass 0.5 Hz, low-pass 30 Hz*). **Use this pipeline** stores it as a new
   EEGLAB dataset; **Save script…** writes it as a MATLAB function that you can run on your other
   recordings; **Show all pipelines** lists every pipeline with the reason it was excluded.
   **Use this pipeline** runs the steps again, except ICA, whose decomposition comes from the
   comparison; save the new dataset afterwards with File > Save current dataset as. The new
   dataset is cut into epochs (segments for band power) and cleaned, ready to average into ERPs
   or to compute band power; do not filter, re-reference or reject epochs again.

### Reading the result

The recommended pipeline is marked with `*`, followed by the best of the others. The columns are:

| Column | Meaning |
|---|---|
| checks | *passed*: the pipeline met every constraint; *excluded*: it broke one (the reason is under *Show all pipelines*); *error*: a step failed; *not run*: the search was stopped first |
| noise (SME) | the standardized measurement error of your measure, divided by the share of a known signal the pipeline keeps. Lower is better: the averaged value is measured more precisely |
| trials kept | the smallest share of trials kept in any condition |
| signal change | how much the pipeline changed the amplitude of the known signal |
| settings | the settings that differ between the pipelines |

The line under the table names the steps that every pipeline shares. When several pipelines cannot
be told apart from the best, PipeCompare recommends the one that keeps the most trials, so that
data are not cleaned more than they need to be. When the settings compared make no difference on
these data, the result says so. When no pipeline passes because most lost too many epochs to
rejection, it names the channels most often over the rejection limit (likely bad channels to
remove or interpolate before running again) and, for data that keep their recorded reference,
suggests the average reference.

When pipelines do pass, PipeCompare still looks at why the recommended pipeline rejected its
epochs. If one channel (or two or three) was over the limit in at least half of the rejected
epochs, and in at least 3 of them, the result names it, for example *Most rejected epochs are due
to one channel: T7 was over the limit in 40 of the 45 epochs rejected in pipeline 2*. Such a
channel is probably bad for long stretches without being bad enough over the whole recording for
the bad-channel test. Look at it in **Plot > Channel data (scroll)**; if it is bad, mark it as bad
or interpolate it (**Tools > Interpolate electrodes**) and run again, which keeps more trials. The
note appears after the headline, in the Command Window and in the advanced panel's notes.

The result also says how large a difference this recording can show, for example *With this many
trials and this noise, two conditions must differ in P3 by about 6 uV to be told apart; smaller
differences need more trials.* This comes from the recommended pipeline's own measurement error
(SME, the error of your measure in its own units, not the gain-corrected value in the table). For
two conditions with errors *a* and *b*, the difference between them has the error
sqrt(*a*² + *b*²); a true difference of 2.8 times that (1.96 + 0.84) is found by a two-sided test
at p < .05 in 80% of recordings like this one. With more than two conditions, the pair with the
largest error is used; with one condition, the value is compared with 0. When the largest
difference actually seen between the conditions (or the value itself, with one condition) is
smaller than this, the result adds that more trials (more events, or several recordings) would
help more than other preprocessing. That comparison is made in the measure's own units, so it
works the same for amplitudes (uV), latencies (ms) and band power (log10 uV²). The same sentence
appears in the Command Window and in the advanced panel's result notes. It describes this one
recording, trial by trial; a group study's power depends on the number of participants instead.

Under the table, the window lists what the recommended pipeline did, step by step in the order the
steps ran; select another row to see that pipeline's steps instead. Each line gives the step's
settings and what it decided on these data, for example:

```
1. Bad channels (kurtosis or joint probability over 5 SD, found on a 1 Hz high-passed copy): O1, O2 interpolated (not tested: VEOG, HEOG)
2. Average reference (left out: VEOG, HEOG)
3. ICA (extended runica), fitted on a 1 Hz high-passed copy and applied to the data
4. High-pass filter 0.5 Hz
5. Low-pass filter 40 Hz
6. ICLabel: 4 of 60 components removed (Muscle, Eye, Heart, Line Noise, Channel Noise with probability 0.8 or more); 21 look like brain activity, 9 were labelled Other
7. Epochs -200 to 800 ms around event type(s) ...
8. Baseline -200 to 0 ms removed
9. Epochs beyond +/-150 uV on any channel rejected: 12 of 120
Trials kept per condition: ...
```

When epochs are repaired (line 8 of the step list), the rejection line adds how many epochs were
kept that way, for example *Epochs beyond +/-150 uV on any channel rejected: 9 of 120; 7 epoch(s)
kept by interpolating up to 3 channel(s) within the epoch*, and with the average reference a last
line *Average reference again (after the epochs repaired by interpolation)* follows.

When ICA did nothing useful, the result says so after the headline (see
[When ICA does nothing](#when-ica-does-nothing)).

This is a readable summary of the pipeline's `EEG.history`; the dataset you get with *Use this
pipeline* keeps the full history (every EEGLAB command) unchanged. The same list is printed in the
Command Window after a run from `pop_pipecompare`, and the advanced panel shows it under *Steps*
when you select a result row.

For any EEGLAB step, order search, several components or different constraints, open
**Advanced…** in the dialog, or **Tools > PipeCompare > Advanced panel…**. The panel defines the
same measures as the dialog (ERP components, N2pc and LRP contralateral minus ipsilateral, band
power). See [docs/PANEL.md](docs/PANEL.md) for a description of every control.

### Ear and mastoid channels

Electrodes on the earlobes or mastoids are reference sites, not scalp electrodes. PipeCompare
recognises them automatically, in any dataset, by their standard names: **A1** and **A2** (10-20
earlobes) and **M1** and **M2** (mastoids), in any upper or lower case and also with the `POL `
prefix some EDF exports add (`POL A1`). A channel whose type is set to `REF` in the channel
locations counts too. These channels:

- stay in the data, unchanged;
- are not tested as bad channels, so they are never interpolated (the scalp cannot predict them);
- do not count in epoch rejection;
- are left out of an average reference, as EOG channels are;
- are not interpolated back when they were removed before PipeCompare.

This also covers data already referenced to linked ears or mastoids, where A1 and A2 are flat or
mirror each other and a bad-channel test would wrongly flag them. The dialog (step 1, *Data*),
the Command Window log and the advanced panel's dataset summary list them, e.g. *Ear/mastoid
channels left out: A1, A2*; in the panel they are filled into each step's *exclude* list, where
you can edit them.

Some channels with these names are not ears, and are left as scalp channels:

- caps numbered by letter, such as BioSemi's A1-A32: when the data also have A3 (or M3), A1 and A2
  are scalp electrodes there;
- TP9 and TP10, which sit near the mastoids but are scalp electrodes in the 10-10 system;
- a channel you set to type `EEG` in **Edit > Channel locations** while other channels have other
  types. Use this to keep A1 and A2 as scalp channels. (When every channel has type `EEG`, that is
  the importer's default, not a choice, and the names decide.)

### Montage check

Before the run, PipeCompare checks whether each channel's signal looks like that of the channels
next to it. On the scalp, neighbouring electrodes record similar signals, so a channel that does
not resemble its neighbours is either a bad channel or not where its label says it is (for
example, two labels swapped when the recording was set up or exported). A wrong label matters
more than it seems: bad-channel interpolation and ICLabel both use the positions that come from
the labels.

How it works:

- It uses the EEG channels that have a location, leaving out EOG, ECG and similar channels and the
  ear and mastoid channels. It needs at least 8 of them; with fewer, it is skipped.
- It takes the first 10 minutes of a continuous recording (for epoched data, as many epochs as fit
  in 10 minutes, each with its mean removed), keeps 1-30 Hz and applies an average reference, all
  on a copy. Your data are not changed.
- For each channel it computes the mean correlation with its 3 nearest channels (by electrode
  position).
- A channel is flagged when this correlation is far below the other channels': more than 3 robust
  standard deviations below their median (median and MAD; the spread counts as at least 0.05), or
  below 0.1 while the median of the montage is at least 0.3. On caps with few, widely spaced
  electrodes the median is lower, and then only the first rule applies. The worst channel is
  flagged first and the check runs again without it, so a swapped channel does not also drag its
  neighbours down. At most a quarter of the channels are flagged.
- For each flagged channel it names the two channels it resembles most. If these are far away on
  the head, the label is probably wrong; if it resembles no channel (correlation below 0.3), it is
  more likely a bad channel.

The result appears in the dialog's first line (*Data*), in the Command Window log, and in the
advanced panel's list of data warnings, for example: *Montage check: these channels do not
resemble their neighbours ... AF3 (r = -0.50 with its neighbours; most like TP7 r = 0.61, CP6
r = 0.55) ...*. It is a warning only: nothing is changed and the comparison runs as usual. If
channels are flagged, check the montage with whoever recorded the data, correct the labels or
locations in **Edit > Channel locations**, and run again.

### When ICA does nothing

After the run, PipeCompare looks at what ICA and ICLabel did in the recommended pipeline (or, if
it has no ICA, the first pipeline with ICA), and says so when:

- ICLabel recognised almost none of the components: fewer than 2 components have a Brain
  probability of 50 % or more, or the median probability of *Other* is above 0.8. The message gives
  the numbers, for example *ICLabel recognised almost none of the 61 ICA components: 0 look like
  brain activity (Brain 50% or more) and 56 were labelled Other*. ICLabel judges components partly
  by their scalp maps, so this usually means that the channel labels do not match the electrode
  positions (see [Montage check](#montage-check)); too little clean recording for ICA can do the
  same. In that case the ICA step changed nothing useful.
- No pipeline removed any component. If ICLabel did recognise brain components, the message says
  that no component passed the artifact threshold, which is expected on clean data.
- ICA had too little data. A usual rule is that ICA needs at least 20 × (number of components)²
  data points for a reliable decomposition, more being better: with 60 components, 72 000 points,
  that is 4.8 minutes at 250 Hz or 72 seconds at 1000 Hz. With fewer, the components can mix brain
  activity and artifacts, and ICLabel cannot sort them. The message gives the numbers, for example
  *ICA had too little data: 30000 data points for 61 components, while a reliable decomposition
  needs about 20 x 61 x 61 = 74420 or more*. This is said whatever ICLabel recognised. The fix is
  a longer recording; fewer channels (fewer components) also lower the need.

The note appears in the result window after the headline, in the Command Window, and in the
advanced panel's notes below the results. Each pipeline's step list also gives, on its ICLabel
line, how many components look like brain activity and how many were labelled *Other*.

### Repairing epochs with a few bad channels

Sometimes a single electrode loses contact for a moment: in a few epochs one channel goes far over
the rejection limit while all the others are fine. Rejecting those epochs loses trials because of
one channel. With **repair epochs with up to 3 channels over the limit** ticked (line 8 of the
step list; `'epochinterp'` in `pop_pipecompare`), the rejection step works as follows, in each
epoch:

1. It tests every EEG channel against the limit, as usual (non-EEG and ear/mastoid channels are not
   tested).
2. If 1, 2 or 3 channels are over the limit, and they all have locations, those channels are
   replaced in that epoch only by spherical-spline interpolation from the other channels of the
   same epoch (the same computation as EEGLAB's `eeg_interp`), and the epoch is kept.
3. If more than 3 channels are over the limit, the epoch is rejected as before.

This is the idea of the epoch-level channel interpolation in FASTER (Nolan, Whelan & Reilly,
2010). It runs after ICA, filtering, epoching and baseline correction, as part of the rejection
step, so it sees the same data the limit is applied to. Repaired epochs are not tested again.
With the average reference, the data are averaged again afterwards: the replaced values were part
of that epoch's average, which would otherwise keep a share of the bad signal in every channel.
The signal check applies exactly the same repairs (same channels, same epochs) to its copy, so any
change to the measured signal is counted. Repaired epochs do not count towards the 20 % limit on
interpolated channels, which is about whole channels. Each pipeline's `EEG.history` records the
repairs as one command listing the channels and epochs.

In the advanced panel, every rejection step (amplitude, joint probability, kurtosis) has the
parameter `interpolate`: the largest number of flagged channels an epoch may have and still be
repaired (0, the default, turns it off). Set any number there, or several (for example `0 | 3`)
to compare pipelines with and without repairs. For joint probability and kurtosis, the flagged
channels are those over the per-channel limit.

### From the command line

The menu dialog records an equivalent command in EEGLAB's command history (`ALLCOM`):

```matlab
% ERP: compare pipelines for the P3, one condition per event type
EEG = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'target', 'standard'}, 'recipe', 'standard');

% N2pc, contralateral minus ipsilateral: the event types of each target side
EEG = pop_pipecompare(EEG, 'measure', 'N2pc', 'left', {'111', '112'}, 'right', {'121', '122'});

% Continuous data: compare pipelines for alpha-band power in 2 s segments
EEG = pop_pipecompare(EEG, 'measure', 'alpha', 'recipe', 'filters');

% Only some steps (any of 'badchannels', 'ica', 'highpass', 'lowpass', 'reject', 'epochinterp'),
% always run in that order
EEG = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'target'}, 'steps', {'highpass', 'lowpass', 'reject'});

% Standard plus repairing epochs that have up to 3 channels over the rejection limit
EEG = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'target'}, ...
    'steps', {'badchannels', 'ica', 'highpass', 'lowpass', 'reject', 'epochinterp'});

% A component with your own electrodes instead of its ERP CORE site
EEG = pop_pipecompare(EEG, 'measure', 'P3', 'channels', {'Pz', 'CPz', 'POz'}, 'events', {'target'});

% Your own window (s) and electrodes; or 'measure', 'band', 'band', [8 12]
EEG = pop_pipecompare(EEG, 'measure', 'custom', 'window', [0.25 0.5], 'channels', {'Cz', 'CPz'}, ...
    'events', {'target'}, 'recipe', 'standard');
```

Replace `'target'` and `'standard'` with the event types in your dataset. The dataset is returned
unchanged, and the result is also stored in the base-workspace variable `pipecompare_result`. Type
`help pop_pipecompare` for all options.

## Scripting interface

For full control, describe what is measured (an analysis *contract*) and what may vary (a *plan*):

```matlab
pipecompare.PipeCompare.state();          % summary of the current dataset and its history

% What is measured: conditions, epoch, baseline, and the measure (window, channels, type)
c = pipecompare.eval.Contract( ...
    'conditions', {'target', {'target'}; 'standard', {'standard'}}, ...
    'epoch',      [-0.2 1.0], ...
    'baseline',   [-0.2 0], ...
    'components', {'P3', [0.30 0.60], {'Pz', 'CPz', 'POz'}, 'mean'});

% What may vary
p = pipecompare.plan.Plan();
p = p.add('highpass');                                   % cutoff searched over 0.1, 0.3, 0.5, 1 Hz
p = p.add('lowpass', 'cutoff', 30);                      % fixed value
p = p.addEeglab('EEG = pop_reref(EEG, []);', 'reref');   % one EEG = pop_*(EEG, ...) call as a step
p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', {0.8, 0.9});          % searched over two values
p = p.add('epoch');                                      % windows come from the contract
p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {100, 150}, 'interpolate', {0, 3});   % with and without repairing epochs

r = pipecompare.PipeCompare.optimize(p, c, struct('checkpoint', 'pc_run1'));

pipecompare.PipeCompare.adopt(r);                          % recommended pipeline -> new dataset
pipecompare.PipeCompare.writeScript(r, 3, 'pipeline3.m');  % candidate 3 as a function for any recording
r = pipecompare.PipeCompare.resume('pc_run1');             % continue an interrupted search
```

Band power of continuous data uses a band-power contract and the same plan without the `baseline`
step (segments have no baseline window, so a `baseline` step would make every pipeline fail):

```matlab
c = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, ...
    'bands', {'alpha', [8 12], {'O1', 'Oz', 'O2'}});
```

By default, steps run in the order they were added. If that order is invalid, PipeCompare lists
the conflicts instead of rearranging the steps. Set `p.OrderMode = 'search'` to compare every
valid order; `p = p.pin(id)` keeps a step in place and `p = p.before(a, b)` makes step `a` run
before step `b` (a plan is a value object, so assign the result).

The available steps are listed in [docs/COVERAGE.md](docs/COVERAGE.md). Search options (for
example `parallel`, `checkpoint` and `maxLeaves`) are documented in `help pipecompare.run.Executor`,
and constraints and ranking options in `help pipecompare.eval.Rank`.

## How a pipeline is chosen

1. **Feasibility.** Pipelines that fail or violate a constraint are excluded, each with a stated
   reason. Default constraints:
   - at least 10 trials and 50 % retention per condition;
   - at most 20 % of channels interpolated;
   - preservation of the known signal: amplitude error ≤ 10 %, peak shift ≤ 10 ms, artifactual
     deflection ≤ 5 %, waveform correlation ≥ 0.95, topography correlation ≥ 0.90 (for band power
     only the amplitude error and topography correlation apply).
2. **Precision.** Feasible pipelines are scored by their SME, divided by the gain each pipeline
   applies to the known signal. This makes the comparison one of signal-to-noise ratio, so a
   pipeline cannot appear more precise just by attenuating everything (Zhang, Garrett & Luck,
   2024).
3. **Uncertainty.** A paired bootstrap over trials, with simultaneous intervals across all pairs
   of candidates (White, 2000; Romano & Wolf, 2005), finds the set of pipelines that the data
   cannot distinguish from the best.
4. **Recommendation.** Within that set, PipeCompare recommends the least aggressive pipeline: the
   one with the highest trial retention, then the least signal distortion.

Pipelines that differ in something that changes the measured quantity, such as the reference, are
ranked separately and never compared with each other. With several such groups there is no overall
recommendation: each group has its own, and `adopt` and `writeScript` then need a candidate id.
A multiverse summary reports, for each measure and condition, how much its value varies over the
feasible pipelines and which searched choice accounts for most of that variation (η²); it is
descriptive and not used in the ranking. The full derivations are in
[docs/METHODS.md](docs/METHODS.md).

## Outputs

- A ranked table of all pipelines: status, objective (gain-corrected SME), simultaneous interval
  of its difference from the best, trial retention, interpolation, signal-check results, and the
  reason for each exclusion.
- The recommended pipeline and why it was chosen.
- The full EEGLAB command sequence for every candidate.
- A MATLAB function that runs a chosen candidate's steps on any recording, deciding bad channels,
  components and rejected epochs from that recording's data (`writeScript`).
- Adoption of a candidate as a new EEGLAB dataset whose `EEG.history` replays it (`adopt`).

## Limitations

- **The analysis contract is fixed by you.** Event types, epoch and baseline windows, regions of
  interest and measurement windows define what is measured, and are never searched.
- **The signal check is necessary, not sufficient.** The known signal has an assumed topography
  centred on the region of interest. Real components may be affected differently.
- **Some steps are re-run on the signal copy.** EEGLAB commands added as steps that make their
  own data-driven decisions, other than mark-and-remove workflows, are re-run on the copy carrying
  the known signal rather than replayed; this includes ASR added as an EEGLAB command. The built-in
  `asr` step replays the reconstructions ASR chose and is re-run only when they cannot be
  reproduced exactly. The result flags every re-run step.
- **Reference.** The dialog offers the recorded reference or the average reference. For another
  reference (e.g. linked mastoids), add a re-reference step with those channels in the panel or a
  script.
- **Channel locations are needed** for spherical interpolation and ICLabel. Without them those
  steps are excluded before the search, with the reason.
- **Peak latency is a weak criterion.** Its precision is hard to estimate with few trials, so it
  rarely separates pipelines; mean-amplitude measures are more informative.
- **Computation cost.** Every pipeline also runs on the signal copy, roughly doubling the EEGLAB
  computation. Memory use grows with plan depth; the expected peak is reported when it exceeds
  2 GB. Resampling early in the plan reduces both.
- **Single-dataset scope.** STUDY-level processing, time-frequency measures, connectivity and
  source analysis are not covered.

[docs/COVERAGE.md](docs/COVERAGE.md) lists every supported operation and how it has been
validated.

## Testing

```matlab
eeglab nogui                              % EEGLAB and its plugins must be on the path
addpath(fullfile(pwd, 'tests'));          % run from the PipeCompare folder
results = run_all();
```

The suite runs on synthetic data with known ground truth. It covers history parsing, plan
enumeration (checked against brute force), the statistics (validated by simulation), signal
preservation for every built-in step except `resample`, end-to-end searches with resume and
parallel execution, and EEGLAB and panel integration. Continuous integration runs every suite,
including those that open windows (on a virtual display); tests that need a toolbox CI does not
install, such as parallel execution (Parallel Computing Toolbox), are skipped there. Steps that
require clicking in EEGLAB's own dialogs cannot be automated and are listed in
[tests/MANUAL_GUI_CHECK.md](tests/MANUAL_GUI_CHECK.md).

Two optional checks use your own data, which is never committed: set the environment variable
`PIPECOMPARE_REAL_SET` to a `.set` file, or run `tests/realdata_validation.m`.

## Documentation

| Document | Contents |
|---|---|
| [docs/PANEL.md](docs/PANEL.md) | The dialog and the advanced panel, control by control |
| [docs/METHODS.md](docs/METHODS.md) | Measures, statistics and signal check, with derivations and references |
| [docs/COVERAGE.md](docs/COVERAGE.md) | Supported steps and their validation status |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Bug reports, documentation fixes and tests |

## Citation

If you use PipeCompare in published work, please cite it:

```bibtex
@software{pipecompare2026,
  author  = {abwoo},
  title   = {PipeCompare: data-driven comparison of EEG preprocessing pipelines in EEGLAB},
  year    = {2026},
  version = {0.9.2},
  url     = {https://github.com/abwoo/PipeCompare}
}
```

Please also cite the methods it builds on:

- Luck, S. J., Stewart, A. X., Simmons, A. M., & Rhemtulla, M. (2021). Standardized measurement
  error: A universal metric of data quality for averaged event-related potentials.
  *Psychophysiology*, 58(6), e13793.
- Kappenman, E. S., Farrens, J. L., Zhang, W., Stewart, A. X., & Luck, S. J. (2021). ERP CORE: An
  open resource for human event-related potential research. *NeuroImage*, 225, 117465.
- Zhang, G., Garrett, D. R., & Luck, S. J. (2024). Optimal filters for ERP research I: A general
  approach for selecting filter settings. *Psychophysiology*, 61(6), e14531.
- White, H. (2000). A reality check for data snooping. *Econometrica*, 68(5), 1097–1126.
- Romano, J. P., & Wolf, M. (2005). Stepwise multiple testing as formalized data snooping.
  *Econometrica*, 73(4), 1237–1282.

The pipelines run on EEGLAB (Delorme, A., & Makeig, S. (2004). *Journal of Neuroscience Methods*,
134(1), 9–21); when the chosen pipeline removes components with ICLabel, cite it too
(Pion-Tonachini, L., Kreutz-Delgado, K., & Makeig, S. (2019). *NeuroImage*, 198, 181–197). The
complete reference list is in [docs/METHODS.md](docs/METHODS.md#references).

## License

PipeCompare is released under the [MIT License](LICENSE).
