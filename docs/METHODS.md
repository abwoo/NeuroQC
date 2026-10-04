# Methods: what NeuroQC computes, and why

This page states the mathematics behind the evaluation and ranking, with the sources each choice
rests on. The code that implements each part is named in brackets.

Notation. A candidate pipeline is a sequence of EEGLAB operations. For one component (ROI, time
window, measure) and one condition, trial *i* gives a score *y*ᵢ (*i* = 1…*N*), e.g. the mean
amplitude over the ROI channels and the window after baseline correction.

## 1. Data quality: the standardized measurement error

For a mean-amplitude score the averaged ERP's score is ȳ, and its standard error is the analytic
SME (Luck et al., 2021):

  SME = s_y / √N,  s_y = sample SD of *y*₁…*y*_N.

For a peak amplitude or latency the score of the average is not a mean of trial scores, so the SME
is bootstrapped (bSME): draw *N* trials with replacement *B* times, average, take the peak, and use
the SD of the *B* values (Luck et al., 2021). [`neuroqc.eval.Measure`]

Several measures that share a unit are combined as the root mean square over measures and
conditions. Measures in different units (µV and ms) are never added: one of them must be chosen.

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
SME′/*g*′ = SME/*g*: an overall rescaling can no longer win. (Test:
`test_statistics/testScalingTheDataDoesNotChangeTheObjective`.)

**Measuring g.** The matched-decision injection already processes a copy that holds only a known
signal through the same operations and decisions (section 4). The gain is read there: for a mean
amplitude, the ratio of the recovered and expected window means over the ROI; for a peak
amplitude, the ratio of the peaks; for a latency, *g* = 1, because a latency does not change
when the amplitude is scaled. A gain that is not positive (signal lost or inverted) leaves the
objective undefined, and the candidate is rejected with that reason.
[`neuroqc.eval.Injection.compare` → `gain`; `neuroqc.eval.Rank`]

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
| 200 (previous, peak measures) | 4 ± 1.98 | 49 % |
| 999 (now, peak measures) | 20 ± 4.43 | 22 % |
| 1999 (now, mean measures) | 40 ± 6.26 | 16 % |

With *B* = 200 the verdict for a borderline candidate could change with the random seed. The
defaults are now *B* = 1999 and, for the nested peak bootstrap, *B* = 999. [`neuroqc.eval.Rank`]

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

**Injected field.** One Gaussian per component, centred in its window with σ = window/4. Over the
scalp it is a Gaussian in the angle θ between a channel's unit position vector and the ROI
centroid, w(θ) = exp(−θ²/(2·0.5²)), normalized to mean 1 over the ROI. Channels without coordinates
(often EOG/ECG) have no defined scalp position: they get no field outside the ROI and the ROI's
mean field inside it. Their presence no longer reduces the whole field to a box over the ROI. A box
is used only when no ROI channel has a position. [`neuroqc.eval.Injection`]

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
epochs' flags, which ERPLAB's averager honours (Lopez-Calderon & Luck, 2014). NeuroQC's scores use
every epoch that is still in the data. A candidate that ends with epochs marked but not removed
therefore carries a note, so a marking-only step is not mistaken for a rejection.
[`neuroqc.run.Executor`, note column of the ranking]

## References

- Davison, A. C., & Hinkley, D. V. (1997). *Bootstrap Methods and Their Application*. Cambridge
  University Press.
- Delorme, A., & Makeig, S. (2004). EEGLAB: an open source toolbox for analysis of single-trial EEG
  dynamics including independent component analysis. *Journal of Neuroscience Methods, 134*(1),
  9–21.
- Efron, B., & Tibshirani, R. J. (1993). *An Introduction to the Bootstrap*. Chapman & Hall.
- Hansen, P. R., Lunde, A., & Nason, J. M. (2011). The model confidence set. *Econometrica, 79*(2),
  453–497.
- Lopez-Calderon, J., & Luck, S. J. (2014). ERPLAB: an open-source toolbox for the analysis of
  event-related potentials. *Frontiers in Human Neuroscience, 8*, 213.
- Luck, S. J., Stewart, A. X., Simmons, A. M., & Rhemtulla, M. (2021). Standardized measurement
  error: A universal metric of data quality for averaged event-related potentials.
  *Psychophysiology, 58*(6), e13793.
- McCarthy, P. J. (1969). Pseudo-replication: Half samples. *Review of the International
  Statistical Institute, 37*(3), 239–264.
- Perrin, F., Pernier, J., Bertrand, O., & Echallier, J. F. (1989). Spherical splines for scalp
  potential and current density mapping. *Electroencephalography and Clinical Neurophysiology,
  72*(2), 184–187.
- Pion-Tonachini, L., Kreutz-Delgado, K., & Makeig, S. (2019). ICLabel: An automated
  electroencephalographic independent component classifier, dataset, and website. *NeuroImage,
  198*, 181–197.
- Romano, J. P., & Wolf, M. (2005). Stepwise multiple testing as formalized data snooping.
  *Econometrica, 73*(4), 1237–1282.
- White, H. (2000). A reality check for data snooping. *Econometrica, 68*(5), 1097–1126.
- Widmann, A., Schröger, E., & Maess, B. (2015). Digital filter design for electrophysiological
  data – a practical approach. *Journal of Neuroscience Methods, 250*, 34–46.
- Zhang, G., Garrett, D. R., & Luck, S. J. (2024). Optimal filters for ERP research I: A general
  approach for selecting filter settings. *Psychophysiology, 61*(6), e14531.
