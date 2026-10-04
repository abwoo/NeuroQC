# Panel reference

## Simple mode (*Compare pipelines…*, `pop_pipecompare`)

Two choices (what to measure; for ERP, the event types); the recipe is preselected:

1. **Data**, described from the data: epoched data offer ERP measures, continuous data with
   events ERP measures and band power, continuous data without events band power.
2. **Measure**, one list of what the data support: the ERP components, *your own window and
   electrodes*, the bands, and *your own band and electrodes*. For your own measure, type two
   numbers (window in ms after the event, e.g. `300 600`, or band in Hz, e.g. `8 12`) and pick
   the electrodes with *Electrodes…* (EEGLAB's channel list; a band starts with all EEG
   channels). Your own window uses a −200 ms epoch start and a −200–0 ms baseline, and the band
   lengthens the segments to hold two cycles of its low edge. ERP: the time-locking event
   types. Each type is one condition,
   or tick *Score the selected event types as one condition* when several codes mean one
   condition (e.g. one code per block). `boundary` markers are not offered; on epoched data the
   types the epochs are time-locked to are preselected. A condition with fewer events than the
   search needs (10) is flagged before *Run*, which stays off. The component's
   epoch, baseline, electrode sites and mean-amplitude window are those of ERP CORE (Kappenman et
   al., 2021, Tables 1 and 2): N170 PO8 110–150 ms; MMN FCz 125–225 ms; N2pc PO7/PO8 200–275 ms;
   N400 CPz 300–500 ms; P3 Pz 300–600 ms; LRP C3/C4 −100–0 ms (response-locked); ERN FCz 0–100
   ms (response-locked). Each condition's waveform is scored at these sites; difference waves
   are formed later in your analysis. Band power: delta 1–4, theta 4–8, alpha 8–13, beta 13–30
   Hz over all EEG channels, in 2 s segments.
3. **Compare**: *standard* (preselected) or *filters only* (high-pass × low-pass edges; with fewer
   than two pipelines, as on epoched data, *Run* stays off). *Standard* adds the ICLabel threshold
   and epoch rejection; each searches the catalog's default lists. *Standard* detects bad channels
   once (kurtosis, z = 5) and fits ICA once, before the filters, so every filter choice shares
   one decomposition (fitted on a 1 Hz high-passed copy; filtering and unmixing are linear, so
   their order does not change the data). ASR is compared from the panel or a script. The number
   of pipelines (and of ICA decompositions) is shown live. Steps the data or the installation
   cannot support are left out, with the reason: no channel locations, no ICLabel, or data that
   are already epoched. Filter edges the data already have (read from the history) are not
   compared: they would leave the data unchanged but still filter the known signal. Above the search limit (500) *Run* stays off; use *Advanced…* to fix
   some values.

*Run* shows a progress window (pipelines done, time left) with *Stop*: stopping keeps the
pipelines already run, and the result covers those. The time left is estimated from the
pipelines after the first, which alone runs the shared steps (ICA included). Data stored in volts
are recognised from the amplitude scale and compared in µV.

*Advanced…* opens the panel below with these choices filled in. The result window says in one
sentence which pipeline to use and why, naming pipelines by the settings compared (e.g. high-pass
0.5 Hz, low-pass 30 Hz), lists it (*) with the best others (checks, noise (SME), trials kept,
signal change, settings) above one line with the steps every pipeline shares, and offers *Use this pipeline* (a new EEGLAB dataset), *Save
script…* and *Details…* (the panel's result table).

## Panel (*Advanced panel…*)

Open EEGLAB > Tools > PipeCompare > *Advanced panel…*. PipeCompare has no load step: it
always works on the current EEGLAB dataset and never modifies it during a search. Each candidate
runs on its own copy.

- **History and state.** The left side shows the live `EEG.history`, parsed line by line. The top
  shows the dataset's state (including channel locations) and any inconsistency between data and
  history.
- **Analysis contract, from EEGLAB's own dialogs.** Conditions are picked from the dataset's event
  list (*Add from events…*); the trials that count from markers, an EEGLAB data selection
  (`pop_select`) or event selection (`pop_selectevent`); the epoch from `pop_epoch`; the baseline from
  `pop_rmbase` (ms converted to s); the ROI from EEGLAB's channel selection. When a dialog sets
  something the contract cannot hold as is (epoch events that differ from the conditions, epoch
  options, a baseline on a channel subset), the panel asks which to keep. A trial rule belongs to
  the recording it was set on and is reset (or flagged) when another recording becomes current. *View ERP* opens
  `pop_timtopo`, *Chan. locations…* opens `pop_chanedit`. The text fields stay editable and show
  the trials per condition under the rule.
- **Nothing is prefilled for a particular study.** Conditions, epoch and components start empty.
  Defaults that are used are stated and come from conventions or from the data: an empty baseline
  is the pre-stimulus interval [epoch start, 0]; an empty epoch on epoched data is the data's own
  epochs; the line-noise frequency (50/60 Hz) and the data unit (uV/V) are judged from the
  recording; resampling has no default rate. Constraint limits and the catalog's search lists are
  general starting values, shown in the panel and editable.
- **Plan.** Add steps in the order they should run. The table shows every parameter as it will
  run (one value = fixed, several = searched, defaults marked). *Configure in EEGLAB…* opens the
  step's EEGLAB dialog: its values join the step, and a value that differs from those already there
  becomes a searched candidate; settings the step cannot hold (e.g. asymmetric limits) are kept as
  the whole EEGLAB command if you choose so. Each dialog opens on the data as the plan has them at
  that step (the current dataset's first 120 s run through the steps before it). *Add EEGLAB menu
  step…* adds any operation of EEGLAB's menus, plugins included (e.g. CleanLine, ERPLAB): its own
  dialog opens and the command it returns becomes a step whose arguments can be searched.
  *Edit values…* lists the parameters (channel lists picked in EEGLAB's channel list). *Skipping allowed*, *Must come before…* and the *pin* column
  control alternatives and order.
- **Apply now in EEGLAB.** Runs the step on the current dataset through EEGLAB's own menu code path
  (`EEG.history`, `ALLCOM`, new dataset), so the plan starts after it.
- **Run search / Options… / Resume…** Every command and score is printed in the Command Window and
  the result is stored in `pipecompare_result`. Options: data unit, checkpoint folder, parallel.
- **Results.** Selecting a row shows its full pipeline, reason, measures and commands below the
  table. *Inspect selected* opens a rebuilt candidate (not adopted) or the source in EEGLAB's
  viewers; *Adopt* stores a candidate as a new EEGLAB dataset whose `EEG.history` reproduces it.

What the evaluation and ranking compute is described in [METHODS.md](METHODS.md).
