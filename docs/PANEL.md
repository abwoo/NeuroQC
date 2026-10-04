# Panel reference

## Simple mode (*Compare pipelines…*, `pop_pipecompare`)

Three choices, nothing preselected:

1. **Data**, judged from the data: epoched, or continuous with events → event-related (ERP);
   continuous without events → band power. The reason is shown, and you can change it.
2. **Measure.** ERP: the time-locking event types (one condition each) and a component. Its
   epoch, baseline, electrode sites and mean-amplitude window are those of ERP CORE (Kappenman et
   al., 2021, Tables 1 and 2): N170 PO8 110–150 ms; MMN FCz 125–225 ms; N2pc PO7/PO8 200–275 ms;
   N400 CPz 300–500 ms; P3 Pz 300–600 ms; LRP C3/C4 −100–0 ms (response-locked); ERN FCz 0–100
   ms (response-locked). Each condition's waveform is scored at these sites; difference waves
   are formed later in your analysis. Band power: delta 1–4, theta 4–8, alpha 8–13, beta 13–30
   Hz over all EEG channels, in 2 s segments.
3. **Compare**: *filters only* (high-pass × low-pass edges), *standard* (+ bad channels,
   ICA/ICLabel threshold, epoch rejection) or *full* (+ ASR), each over the catalog's default
   lists. The number of pipelines (and of ICA decompositions) is shown live. Steps the data or
   the installation cannot support are left out, with the reason: no channel locations, no
   ICLabel or clean_rawdata, or data that are already epoched. Above the search limit (500) *Run*
   stays off; use *Advanced…* to fix some values.

*Advanced…* opens the panel below with these choices filled in. The result window shows the
recommendation and why, the recommended candidate (*) with the best others, and *Adopt*, *Save
script…*, *All results…* (the panel's result table).

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
