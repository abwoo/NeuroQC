# Methods: what PipeCompare computes, and why

This page states the mathematics behind the evaluation and ranking, with the sources each choice
rests on. The code that implements each part is named in brackets.

Notation. A candidate pipeline is a sequence of EEGLAB operations. For one component (ROI, time
window, measure) and one condition, trial *i* gives a score *y*ᵢ (*i* = 1…*N*), e.g. the mean
amplitude over the ROI channels and the window after baseline correction.

## Overview: how a search runs

1. **Starting point.**
   - The current state is read from the EEG structure: epoched or not, sampling rate, channels and
     their locations, ICA matrices, IC flags and reference.
   - `EEG.history` is parsed in order, without deduplication; continuation lines (`...`) are joined.
   - Where the history cannot describe the data, PipeCompare says so instead of guessing.
   - The data unit (uV or V) is judged from the amplitude scale (or set with `dataUnit`); volts are
     converted on PipeCompare's copy.
   - A floating-point sampling-rate residue (common after EDF import) is rounded on the copy, and
     the change is recorded.
2. **Legal pipelines.**
   - The plan expands into all combinations of searched values, alternatives and orders. Each is
     checked against the simulated data state; excluded combinations are counted with their reason.
   - Channels interpolated or removed after an average reference (of the plan, or of the data
     before PipeCompare) leave their share of that average in every channel unless the data are
     averaged again: such a pipeline is not legal. An order search never tries it, and a fixed
     order is refused with this reason.
   - Every legal pipeline is run; above `maxLeaves` (500 by default) the search is refused with its
     size, never sampled or truncated. To bring a large search within reach: fix the values you
     are already sure of, pin steps or add `before()` rules instead of searching every order, or
     search in stages (search the early steps, adopt the result, then search the later steps from
     that dataset). Raising `maxLeaves` is possible but every pipeline really runs.
3. **Execution.**
   - Pipelines run as a prefix tree, so a shared prefix (e.g. one ICA before several IC thresholds)
     is computed once.
   - Every step is a native EEGLAB call. Its command is printed and appended to that candidate's
     `EEG.history`.
   - Each candidate is checkpointed. `resume` continues and gives the same result as an
     uninterrupted run.
   - `parallel = true` distributes independent subtrees over a pool.
4. **What is measured.**
   - The contract defines the measures: mean amplitude, peak amplitude or peak latency per
     component.
   - No experimental effect is used, so choosing a pipeline cannot inflate the effect you test later.
   - The data quality of each measure is its standardized measurement error (SME): analytic for
     means, bootstrapped for peaks and latencies (Luck et al., 2021). SME falls when noise is removed
     and rises when trials are lost, so it prices the rejection trade-off.
5. **Signal preservation.** A known signal is used to catch processing that removes the effect along
   with the noise.
   - A copy containing only a known signal is carried through every candidate with the same
     operations and the same decisions as the real data (bad channels, ICA, removed components,
     rejected epochs, ASR reconstructions). Native commands that decide from the data on their own
     are re-run on the copy and flagged.
   - Amplitude error, peak shift, artifactual deflection, and waveform and topography correlation
     are each checked against a limit.
6. **Ranking.**
   - Failures are reported, never ranked. Constraint violations are listed with their reasons.
     If nothing is feasible, PipeCompare says so and relaxes nothing.
   - Objective: the **gain-corrected SME**, SME divided by the factor by which the candidate scales a
     known signal in that measure (read from the signal check). Raw SME would reward a pipeline that
     shrinks signal and noise alike; SME/gain does not, and ranking it is ranking signal-to-noise
     (Zhang, Garrett & Luck, 2024). Composite over measures that share a unit, or the one measure
     you choose; the others are reported. Derivation in section 2 below.
   - Paired bootstrap over trials (matched by `urevent`); intervals of the difference from the best
     are simultaneous over all candidates (bootstrap max statistic; White, 2000; Romano & Wolf,
     2005), so a larger search does not produce more false "worse" verdicts. *Not distinguished* is
     absence of evidence, not equivalence.
   - A multiverse summary reports, for each measure and condition, the spread of its value over the
     feasible pipelines and the searched choice behind most of it (`result.robustness`; Steegen et
     al., 2016). It shows sensitivity to processing and is not used for the ranking.
   - A candidate that ends with epochs marked for rejection but not removed (e.g. an ERPLAB artifact
     detection step without a removal) carries a note: marks do not remove epochs.
   - Candidates that differ in the reference are ranked in separate strata, never against each other.
     With several strata there is no overall recommendation: each stratum has its own (marked `*`),
     and you choose the one that fits your analysis.
   - The recommendation is the least aggressive candidate among those not distinguished from the
     best: most trials kept, then least distortion.

## 1. Data quality: the standardized measurement error

For a mean-amplitude score the averaged ERP's score is ȳ, and its standard error is the analytic
SME (Luck et al., 2021):

  SME = s_y / √N,  s_y = sample SD of *y*₁…*y*_N.

For a peak amplitude or latency the score of the average is not a mean of trial scores, so the SME
is bootstrapped (bSME): draw *N* trials with replacement *B* times, average, take the peak, and use
the SD of the *B* values (Luck et al., 2021). [`pipecompare.eval.Measure`]

Several measures that share a unit are combined as the root mean square over measures and
conditions. Measures in different units (µV and ms) are never added: one of them must be chosen.

**Difference waves.** A lateralized component (N2pc, LRP) is scored as ERP CORE measures it,
contralateral minus ipsilateral: each trial's score is the electrode contralateral to its side
(target side, response hand) minus the other, so the SME is that of the difference wave. It can
rank pipelines differently from scoring each electrode: noise common to both hemispheres cancels
in the difference. The signal check then injects a field centred on one of the two electrodes and
checks the difference of the two. A difference between independent conditions (MMN, deviant
minus standard) needs no such scoring: its SME is √(SME₁² + SME₂²), √2 times the root mean
square over the two conditions, so the ranking is the same.

## 2. Gain-corrected SME (the ranking objective)

**Problem with raw SME.** SME is in µV, so it is not invariant to the scale of the data. A pipeline
that multiplies signal and noise by *c* < 1 lowers SME by the factor *c* without measuring the
signal more precisely. With the default amplitude-error limit of 10 %, a pipeline that attenuates
everything by 9 % passes every constraint and gains 9 % in raw SME, which is more than typical
real differences between pipelines. Zhang, Garrett and Luck (2024) make the same point for filters:
filters reduce the signal as well as the noise, so settings must be compared by signal-to-noise
ratio, not by noise alone.

**Model.** Given its decisions (bad channels, ICA weights, removed components, rejected epochs,
ASR reconstructions), each catalog step acts linearly on the data. Write a trial as signal plus
noise, *x*ᵢ = *a*·*s* + *n*ᵢ, where *s* is the unit signal and *a* its amplitude. The score is a
linear functional φ of the processed data, so

  *y*ᵢ = φ(P*x*ᵢ) = *a*·φ(P*s*) + φ(P*n*ᵢ) = *g*·*a* + *e*ᵢ,  with  *g* = φ(P*s*) / φ(R*s*).

*g* is the pipeline's **gain** for this measure, relative to the signal re-referenced like the
candidate (operator R: a change of reference changes what is measured but is not a distortion,
and candidates with different references are ranked in separate strata anyway).

**Estimator.** ȳ/*g* estimates the same quantity *a* for every candidate in a stratum, with standard
error

  SE(ȳ/*g*) = SME / *g*.

So the objective is SME/*g*. Since *a* is common to the candidates of a stratum, minimizing SME/*g*
is maximizing the signal-to-noise ratio *g*·*a*/SME.

**Invariance.** If P′ = *c*·P with *c* > 0, then *g*′ = *c*·*g* and SME′ = *c*·SME, so
SME′/*g*′ = SME/*g*: an overall rescaling cannot win. (Test:
`test_statistics/testScalingTheDataDoesNotChangeTheObjective`.)

**Measuring g.** The matched-decision injection already processes a copy that holds only a known
signal through the same operations and decisions (section 4). The gain is read there: for a mean
amplitude, the ratio of the recovered and expected window means over the ROI; for a peak
amplitude, the ratio of the peaks; for a latency, *g* = 1, because a latency does not change
when the amplitude is scaled. A gain that is not positive (signal lost or inverted) leaves the
objective undefined, and the candidate is rejected with that reason.
[`pipecompare.eval.Injection.compare` → `gain`; `pipecompare.eval.Rank`]

**Limits.**
- For a peak amplitude the correction is first-order: max(·) is not linear. It is exact when the
  peak is dominated by the signal.
- For steps that are re-run on the signal copy instead of replayed (data-driven native commands,
  flagged in the result), *g* is the gain on a noise-free copy, not necessarily on the real data.
- The correction does not make strong attenuation acceptable. The amplitude-error,
  waveform-correlation and artifactual-deflection limits are checked first and still reject such
  pipelines.

## 3. "Not distinguished from the best": simultaneous bootstrap

The *K* feasible candidates of a stratum are compared on the same trials, so one bootstrap draw
resamples the same trials (by `urevent`) for every candidate. This is the paired bootstrap of
Efron and Tibshirani (1993). With objective estimates θ̂ₖ and bootstrap replicates θ*ₖᵇ, the
statistic is the maximum over all ordered pairs of the centred differences:

  *M*ᵇ = max over *i*, *j* of [ (θ*ᵢᵇ − θ*ⱼᵇ) − (θ̂ᵢ − θ̂ⱼ) ].

Let *c* be the (1 − α) quantile of *M*. Candidate *i* is declared worse than *j* only when
θ̂ᵢ − θ̂ⱼ > *c*. Because *c* bounds all pairs at once, the probability that any candidate is wrongly
declared worse is at most about α, however many candidates there are and whichever one looks best.
This is the bootstrap reality check of White (2000) and the max-statistic step of Romano and Wolf
(2005). The set kept, every candidate not shown worse than another, is a model confidence set in
the sense of Hansen, Lunde and Nason (2011).

Raw differences are used instead of studentized ones. With few trials the per-pair bootstrap SD is
itself noisy, and a maximum over many pairs is then driven by underestimated SDs. In simulation
this gave 40 % false "worse" verdicts at 30 trials and 24 candidates. α = 0.02 was set by
simulation so that the family-wise rate stays at or below about 5 % for 2–24 candidates and 20–100
trials (`test_statistics`). In the current suite the rates are 5.3 % with 2 candidates, and 0 %
(30 trials) and 2.5 % (100 trials) with 24 candidates.

**Quantile and number of replicates.** *c* is the order statistic *M*₍ₖ₎ with *k* = (*B* + 1)(1 − α),
which is exact when (*B* + 1)α is an integer (Davison & Hinkley, 1997). Monte-Carlo error enters
through the number of replicates beyond *c*. That number is binomial(*B*, α), with SD √(*B*α(1−α)):

| *B* | replicates beyond *c* (mean ± SD) | relative SD |
|---|---|---|
| 200 | 4 ± 1.98 | 49 % |
| 999 (default, peak measures) | 20 ± 4.43 | 22 % |
| 1999 (default, mean measures) | 40 ± 6.26 | 16 % |

With *B* = 200 the verdict for a borderline candidate could change with the random seed. The
defaults are therefore *B* = 1999 and, for the nested peak bootstrap, *B* = 999. [`pipecompare.eval.Rank`]

**Half-samples for peak measures.** A peak measure already carries an inner bootstrap. Resampling
with replacement around it overstates how much its bSME varies. Each outer draw therefore takes a
half-sample without replacement, the classical pseudo-replication device (McCarthy, 1969), and
rescales the result to the full sample by √(*m*/*N*), since bSME ∝ 1/√*n*. In simulation the SD
of a difference was 7.0 ms against 7.4 ms across real replications; with replacement it was 11 ms.

## 4. Signal preservation: matched-decision injection

A copy of the starting data that holds only a known signal is processed with the same operations
and the same data-driven decisions as the real data. Because these operations are linear given
the decisions, the processed copy shows exactly how the candidate transfers the signal. It is
compared with the expected signal: amplitude error, peak-latency shift, artifactual opposite-polarity
deflection, and waveform and topography correlation. The artifactual-deflection limit (5 %) follows
the artifactual-peak criterion of Zhang, Garrett and Luck (2024). Filters are linear time-invariant
operators fixed by their design parameters (Widmann, Schröger & Maess, 2015), so re-running them on
the copy applies the same operator.

**Injected field.** One Gaussian per component, centred in its window with σ = window/4, but at
least 21.2 ms (50 ms wide at half maximum). With σ = window/4 alone, N170's 40 ms window gave
σ = 10 ms, about half a real N170's width: a 20 Hz low-pass then rang below the template by 7.5 %
of its peak, past the 5 % artifact limit, so every pipeline with that filter was excluded, while it
changes a realistic N170 (σ ≈ 20 ms) by about 0.1 % (simulation of EEGLAB's `pop_eegfiltnew` at
250–1000 Hz; N2pc's template widens from 18.75 ms, and no other verdict changes). Over the
scalp it is a Gaussian in the angle θ between a channel's unit position vector and the ROI
centroid, w(θ) = exp(−θ²/(2·0.5²)), normalized to mean 1 over the ROI. Channels without coordinates
(often EOG/ECG) have no defined scalp position: they get no field outside the ROI and the ROI's
mean field inside it, so their presence does not reduce the whole field to a box over the ROI. A box
is used only when no ROI channel has a position. [`pipecompare.eval.Injection`]

## 5. Preconditions checked before anything runs

- **Interpolation needs electrode positions.** Spherical-spline interpolation is defined on
  positions on the sphere (Perrin et al., 1989). Without any channel location, interpolation steps
  (`badchannels` with action interpolate, `channels` interpolate, `restore`, native `pop_interp`)
  are excluded at plan time, with the reason. When only some channels lack a position, a step that
  would interpolate one of those channels fails with the channel named. EEGLAB's `eeg_interp`
  would leave such a channel unchanged without saying so, while the step would report it
  interpolated.
- **ICLabel needs channel locations.** Its features include the components' scalp maps
  (Pion-Tonachini et al., 2019), so `icremove` and native `pop_iclabel` are excluded without them.
- **Event types are matched exactly.** `pop_epoch` selects events with `strmatch(…, 'exact')`, so
  'S 1' and 's 1' are different types. The contract is validated the same way and names the
  near match.

## 6. Marks are not removals

EEGLAB keeps rejection marks (`EEG.reject.*`) separate from the data; only `pop_rejepoch` removes
epochs (Delorme & Makeig, 2004). ERPLAB's artifact detection marks `EEG.reject.rejmanual` and the
epochs' flags, which ERPLAB's averager honours (Lopez-Calderon & Luck, 2014). PipeCompare's scores use
every epoch that is still in the data. A candidate that ends with epochs marked but not removed
therefore carries a note, so a marking-only step is not mistaken for a rejection.
[`pipecompare.run.Executor`, note column of the ranking]

## 7. Multiverse summary (sensitivity, not ranking)

Every allowed pipeline is run, so the plan's whole "multiverse" of processing choices is available,
not a sample of it (Steegen et al., 2016; for ERP processing, Clayson et al., 2021). For each
measure and condition, and within each stratum, the result reports the spread of the point estimate
over the feasible pipelines (min, median, max, range). It also names the searched choice that
accounts for most of that spread. For a choice with values *v* (with *n*ᵥ pipelines and mean
estimate *x̄*ᵥ), the share is

  η² = Σᵥ *n*ᵥ (*x̄*ᵥ − *x̄*)² / Σᵢ (*x*ᵢ − *x̄*)²,

the fraction of the spread that lies between that choice's values. The summary describes how much
the measured quantity depends on processing. It is not used to rank or recommend pipelines, and it
contains no comparison between conditions. [`pipecompare.eval.Rank.robustness`, `result.robustness`]

## 8. Band power (continuous data, e.g. resting state)

**Segments.** A band-power contract with `segment` *T* cuts the continuous recording into
consecutive *T*-second segments. They are marked with EEGLAB's own `eeg_regepochs(…,
'extractepochs', 'off')`, which inserts the events and their urevents. A segment is therefore
identified by its urevent in every candidate, exactly as an ERP trial is, and a segment that a
candidate rejects is missing (NaN) in that candidate. *T* must hold at least two cycles of the
lowest band edge (*T* ≥ 2/*f*₁), and band edges must lie below Nyquist.

**Score and SME.** Per segment, the score is log₁₀ of the mean power in the band. The power is the
one-sided power spectral density with a Hann taper (Harris, 1978), averaged over the band's bins
and the ROI channels. The SME is SD/√*n* over segments, as for a mean amplitude (section 1). With
`conditions` and `epoch` instead of `segment`, each epoch's band power is scored (event-related
band power).

**No gain correction is needed.** The log is scale-free: if the data are multiplied by *c*, every
score shifts by 2·log₁₀ *c*, and their SD (the SME) is unchanged. The gain of section 2 is
therefore 1 for band power. A step that attenuates the band itself is caught by the signal check:
sinusoids one frequency step (1/T for epochs of T s) inside each band edge and at the band's
centre, over the band's ROI, are carried through the candidate with the same decisions as the real
data, so a filter that cuts into the band is seen even when the centre is untouched. Their
recovered amplitudes (least squares per epoch, all frequencies fitted together, averaged) are
compared with the expected, re-referenced field; the worst frequency of the band counts (amplitude
error, topography correlation). The test frequencies lie on the 1/T grid, so they are orthogonal
over an epoch, and contiguous bands do not share one. A band narrower than five grid steps is
tested at its centre.

**Dependent segments: moving-block bootstrap.** Consecutive segments of one recording are not
independent, because state and noise change slowly. Resampling them one by one treats them as
independent and understates how much an SME difference varies. In a simulation with AR(1) segment
scores (φ = 0.6, 120 segments, two candidates with the same true noise), the false "worse" rate
was 11.3 % with independent resampling and 5.3 % with blocks (`test_statistics`). The comparison
of section 3 therefore resamples segments in blocks of *l* = round(*n*^{1/3}) consecutive segments.
This is the moving-block bootstrap (Künsch, 1989), with the block-length order of Hall, Horowitz
and Jing (1995). ERP trials, which are separated by inter-trial intervals and time-locked to
different events, are resampled one by one as before.

## 9. Repairing epochs: channels interpolated within an epoch

A rejection step (`reject_threshold`, `reject_jointprob`, `reject_kurtosis`) with `interpolate` =
*n* > 0 keeps an epoch that the test fails because of at most *n* channels, as FASTER's epoch-level
channel interpolation does (Nolan, Whelan & Reilly, 2010). The decision is the test's own
per-channel marks (`EEG.reject.rejthreshE`, `rejjpE`, `rejkurtE`), taken before anything is
changed: an epoch with 1 to *n* flagged channels, all with a location, gets those channels replaced
in that epoch by EEGLAB's spherical-spline interpolation (`eeg_interp`, Perrin et al., 1989) from
the other channels of the same epoch, its marks are cleared, and it is kept; the other marked
epochs are removed with `pop_rejepoch`. `eeg_interp` is linear in the data, so its weights for a
set of channels are read once, as its output for a unit impulse on each channel, and applied to
every epoch with that set: the numbers are those `eeg_interp` gives on the epochs themselves
(checked in `test_engine`). Repaired epochs are not tested again.

Interpolated values change the average reference of their epoch: the replaced values were part of
it. As for whole channels (section 5), a plan that repairs epochs after an average reference must
average again afterwards, or it is refused with the reason; the simple mode adds that second
average reference. The signal check replays the same repairs (same channels in the same epochs)
on the copy, so the change they make to the known signal is measured and limited like any other.
The 20 % limit on interpolated channels concerns whole channels and does not count repairs.
[`pipecompare.run.Steps.rejectEpochs`, `pipecompare.run.Steps.interpolateEpochs`]

## 10. Montage check (before a run)

Scalp potentials vary smoothly over the head, so after an average reference a channel resembles its
nearest neighbours. `pipecompare.live.Montage.check` measures this on the located EEG channels (not
EOG/ECG/..., not ear or mastoid sites; at least 8): a sample of the data (the first 600 s, or as
many epochs as fit in 600 s with each epoch's mean removed; at most 2·10⁷ values) is band-passed
1–30 Hz in the frequency domain and average-referenced, and for each channel *nn* is its mean
Pearson correlation with its 3 nearest channels (straight-line distance between unit position
vectors). With *m* the median and *s* = max(0.05, 1.4826 · MAD) over the channels, a channel is
flagged when (*nn* − *m*)/*s* < −3, or when *nn* < 0.1 and *m* ≥ 0.3 (on sparse caps the
neighbours are far apart and the absolute rule would flag good channels). Flagging is iterative:
the worst flagged channel is set aside and *nn* is computed again with neighbours chosen among the
remaining channels, so a swapped channel does not also lower its neighbours' *nn*; at most a
quarter of the channels are flagged. For each flagged channel the two channels with the highest
correlation are named; when none reaches 0.3 the channel resembles nothing and is more likely bad
than mislabelled. The check only warns; it never changes the data or blocks a run.

## 11. ICA check (after a run)

ICLabel's features include the components' scalp maps (Pion-Tonachini et al., 2019), so channel
labels that do not match the positions leave it unable to recognise components. After a run, the
recommended pipeline's ICLabel step (else the first pipeline's with one) is read: fewer than 2
components with Brain probability ≥ 0.5, or a median Other probability above 0.8, is reported as
"recognised almost none"; no component removed in any pipeline is reported too, with the montage
as the first thing to check when recognition was poor, and as expected on clean data when it was
not. ICA fitted on fewer than 20 × n² data points (n components; the data points the ICA step
had, all epochs together) is reported in any case, after the usual rule for a reliable infomax
decomposition (Onton & Makeig, 2006). [`pipecompare.simple.Presets.icaText`]

## 12. Channels behind the rejected epochs (after a run)

Each rejection step records, per channel, in how many of the epochs it rejected that channel was
over the limit (`overLimit`, summed over the pipeline's rejection steps). When the recommended
pipeline has a channel over the limit in at least half of its rejected epochs, and in at least 3,
the result names it (up to 3 such channels) as likely bad over stretches the bad-channel test,
which scores the whole recording, does not catch. When no pipeline passed, the same counts give
`nextStep`'s list instead (channels with at least 10% of all over-limit marks).
[`pipecompare.simple.Presets.rejectText`]

## References

- Clayson, P. E., Baldwin, S. A., Rocha, H. A., & Larson, M. J. (2021). The data-processing
  multiverse of event-related potentials (ERPs): A roadmap for the optimization and standardization
  of ERP processing and reduction pipelines. *NeuroImage, 245*, 118712.
- Davison, A. C., & Hinkley, D. V. (1997). *Bootstrap Methods and Their Application*. Cambridge
  University Press.
- Delorme, A., & Makeig, S. (2004). EEGLAB: an open source toolbox for analysis of single-trial EEG
  dynamics including independent component analysis. *Journal of Neuroscience Methods, 134*(1),
  9–21.
- Efron, B., & Tibshirani, R. J. (1993). *An Introduction to the Bootstrap*. Chapman & Hall.
- Hall, P., Horowitz, J. L., & Jing, B.-Y. (1995). On blocking rules for the bootstrap with dependent
  data. *Biometrika, 82*(3), 561–574.
- Hansen, P. R., Lunde, A., & Nason, J. M. (2011). The model confidence set. *Econometrica, 79*(2),
  453–497.
- Harris, F. J. (1978). On the use of windows for harmonic analysis with the discrete Fourier
  transform. *Proceedings of the IEEE, 66*(1), 51–83.
- Kane, N., Acharya, J., Beniczky, S., Caboclo, L., Finnigan, S., Kaplan, P. W., et al. (2017). A
  revised glossary of terms most commonly used by clinical electroencephalographers and updated
  proposal for the report format of the EEG findings. *Clinical Neurophysiology Practice, 2*,
  170–185.
- Kappenman, E. S., Farrens, J. L., Zhang, W., Stewart, A. X., & Luck, S. J. (2021). ERP CORE: An
  open resource for human event-related potential research. *NeuroImage, 225*, 117465.
- Kothe, C. A. E., & Makeig, S. (2013). BCILAB: a platform for brain-computer interface development.
  *Journal of Neural Engineering, 10*(5), 056014 (artifact subspace reconstruction).
- Künsch, H. R. (1989). The jackknife and the bootstrap for general stationary observations.
  *The Annals of Statistics, 17*(3), 1217–1241.
- Lopez-Calderon, J., & Luck, S. J. (2014). ERPLAB: an open-source toolbox for the analysis of
  event-related potentials. *Frontiers in Human Neuroscience, 8*, 213.
- Luck, S. J., Stewart, A. X., Simmons, A. M., & Rhemtulla, M. (2021). Standardized measurement
  error: A universal metric of data quality for averaged event-related potentials.
  *Psychophysiology, 58*(6), e13793.
- McCarthy, P. J. (1969). Pseudo-replication: Half samples. *Review of the International
  Statistical Institute, 37*(3), 239–264.
- Nolan, H., Whelan, R., & Reilly, R. B. (2010). FASTER: Fully Automated Statistical Thresholding for
  EEG artifact Rejection. *Journal of Neuroscience Methods, 192*(1), 152–162.
- Onton, J., & Makeig, S. (2006). Information-based modeling of event-related brain dynamics.
  *Progress in Brain Research*, 159, 99–120.
- Perrin, F., Pernier, J., Bertrand, O., & Echallier, J. F. (1989). Spherical splines for scalp
  potential and current density mapping. *Electroencephalography and Clinical Neurophysiology,
  72*(2), 184–187.
- Pion-Tonachini, L., Kreutz-Delgado, K., & Makeig, S. (2019). ICLabel: An automated
  electroencephalographic independent component classifier, dataset, and website. *NeuroImage,
  198*, 181–197.
- Romano, J. P., & Wolf, M. (2005). Stepwise multiple testing as formalized data snooping.
  *Econometrica, 73*(4), 1237–1282.
- Steegen, S., Tuerlinckx, F., Gelman, A., & Vanpaemel, W. (2016). Increasing transparency through
  a multiverse analysis. *Perspectives on Psychological Science, 11*(5), 702–712.
- White, H. (2000). A reality check for data snooping. *Econometrica, 68*(5), 1097–1126.
- Widmann, A., Schröger, E., & Maess, B. (2015). Digital filter design for electrophysiological
  data – a practical approach. *Journal of Neuroscience Methods, 250*, 34–46.
- Zhang, G., Garrett, D. R., & Luck, S. J. (2024). Optimal filters for ERP research I: A general
  approach for selecting filter settings. *Psychophysiology, 61*(6), e14531.
