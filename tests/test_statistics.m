function tests = test_statistics
%TEST_STATISTICS Numerical validation of the evaluation statistics against
%   external criteria (definitions, simulation with known truth).
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
end

% ----------------------------------------------------------------- SME
function testSmeAnalytic(tc)
S = [1; 2; 3; 4; NaN];
verifyEqual(tc, pipecompare.eval.Measure.sme(S), std([1 2 3 4]) / 2, 'AbsTol', 1e-12);
end

function testSmeMatchesEmpiricalSdOfTheMean(tc)
% SME must estimate the SD of the averaged score across replications.
rs = RandStream('mt19937ar', 'Seed', 11);
N = 40; sigma = 7; reps = 4000;
m = zeros(reps, 1); sme = zeros(reps, 1);
for r = 1:reps
    x = 3 + sigma * randn(rs, N, 1);
    m(r) = mean(x); sme(r) = pipecompare.eval.Measure.sme(x);
end
verifyEqual(tc, mean(sme), std(m), 'RelTol', 0.05);
verifyEqual(tc, mean(sme), sigma / sqrt(N), 'RelTol', 0.05);
end

function testBootstrappedSmeOfPeakLatencyMatchesReplications(tc)
% bSME of the peak latency of the average must estimate the SD of that
% latency across independent replications (Luck et al., 2021).
rs = RandStream('mt19937ar', 'Seed', 4);
fs = 250; t = (0.2:1/fs:0.6) * 1000; N = 40; reps = 300;
o = struct('kind', 'peakLatency', 'polarity', 'positive', 'times', t);
opts = pipecompare.eval.Measure.defaults(); opts.nBootPeak = 400;
lat = zeros(reps, 1); bsme = zeros(reps, 1);
for r = 1:reps
    X = 5 * exp(-0.5 * ((t - 400) / 60) .^ 2) + 8 * randn(rs, N, numel(t));
    [lat(r), bsme(r)] = pipecompare.eval.Measure.estimate(o, X, opts, r);
end
fprintf('peak latency: empirical SD %.2f ms, mean bSME %.2f ms\n', std(lat), mean(bsme));
verifyEqual(tc, mean(bsme), std(lat), 'RelTol', 0.20);
end

% ------------------------------------------------- comparison and ranking
function testTieCriterionErrorRateAndPower(tc)
% With equal true noise the better-looking candidate must rarely be
% declared distinguishable (post-selection false "worse" rate <= ~5% at
% the default alpha); with 1.4x noise it must usually be.
rs = RandStream('mt19937ar', 'Seed', 5);
N = 100; sims = 150; o = pipecompare.eval.Rank.defaults(); o.nBoot = 800;
ref = nqc_ref(N);
fa = 0; hit = 0;
for k = 1:sims
    common = randn(rs, N, 1);
    a = common + randn(rs, N, 1); b = common + randn(rs, N, 1);
    c = common + 1.71 * randn(rs, N, 1);       % total SD 1.4x that of a
    fa = fa + worse(a, b, ref, o);
    hit = hit + worse(a, c, ref, o);
end
fprintf('not-distinguished test: false-worse rate %.3f, power %.3f\n', fa / sims, hit / sims);
verifyLessThan(tc, fa / sims, 0.06);
verifyGreaterThan(tc, hit / sims, 0.8);
end

function testManyCandidatesKeepTheFamilywiseErrorBounded(tc)
% 24 candidates with the same true noise: the share of searches in which
% ANY of them is declared worse must stay near 5% (per-comparison
% intervals against the selected best did this in 87/100 searches).
rs = RandStream('mt19937ar', 'Seed', 12);
K = 24; sims = 80; o = pipecompare.eval.Rank.defaults(); o.nBoot = 600;
for N = [30 100]
    ref = nqc_ref(N);
    fwer = 0; frac = 0;
    for k = 1:sims
        common = randn(rs, N, 1);
        cs = arrayfun(@(j) nqc_cand(common + randn(rs, N, 1)), 1:K);
        R = pipecompare.eval.Rank.run(cs, ref, o);
        fwer = fwer + any(~R.table.notDistinguished); frac = frac + mean(~R.table.notDistinguished);
    end
    fprintf('%d candidates, %d trials: any false "worse" %.3f, mean share %.4f\n', K, N, fwer / sims, frac / sims);
    verifyLessThanOrEqual(tc, fwer / sims, 0.08);
end
end

function testPowerDoesNotCollapseWithManyCandidates(tc)
% A clearly noisier candidate (1.4x SD) among 23 equal ones must still
% usually be declared worse.
rs = RandStream('mt19937ar', 'Seed', 13);
N = 100; sims = 40; ref = nqc_ref(N); o = pipecompare.eval.Rank.defaults(); o.nBoot = 600;
hit = 0;
for k = 1:sims
    common = randn(rs, N, 1);
    cs = arrayfun(@(j) nqc_cand(common + randn(rs, N, 1)), 1:23);
    cs(24) = nqc_cand(common + 1.71 * randn(rs, N, 1));
    R = pipecompare.eval.Rank.run(cs, ref, o);
    hit = hit + ~R.table.notDistinguished(24);
end
fprintf('power with 24 candidates: %.3f\n', hit / sims);
verifyGreaterThan(tc, hit / sims, 0.8);
end

function testMissingSignalCheckIsNotAPass(tc)
% NaN in an applicable signal metric means the check failed or was not
% computed; it must reject the candidate. A metric the check declares not
% applicable is skipped. A candidate without any signal check is rejected.
N = 40; ref = nqc_ref(N); x = randn(N, 1);
o = pipecompare.eval.Rank.defaults(); o.nBoot = 100;
ok = struct('source', 'injection', 'amplitudeError', 0.01, 'latencyShiftMs', 0, 'artifactPct', 0, ...
    'waveformCorr', 0.99, 'topoCorr', 0.99, 'chain', '', 'notApplicable', {{}});
nanAmp = ok; nanAmp.amplitudeError = NaN; nanAmp.waveformCorr = NaN;
naTopo = ok; naTopo.topoCorr = NaN; naTopo.notApplicable = {'topoCorr'};
cs = [nqc_cand(x, 'signal', ok) nqc_cand(x, 'signal', nanAmp) nqc_cand(x, 'signal', naTopo) nqc_cand(x)];
cs(4).signal = [];
R = pipecompare.eval.Rank.run(cs, ref, o);
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'; 'feasible'; 'rejected'});
verifyTrue(tc, contains(R.table.reason{2}, 'amplitudeError not computed'));
verifyTrue(tc, contains(R.table.reason{2}, 'waveformCorr not computed'));
verifyTrue(tc, contains(R.table.reason{4}, 'signal check missing'));
% a NaN retention / interpolation count is not a pass either
c5 = nqc_cand(x); c5.interpolatedFraction = NaN;
R = pipecompare.eval.Rank.run(c5, ref, o);
verifyEqual(tc, R.table.status, {'rejected'});
end

function testPeakComparisonSpreadMatchesReplications(tc)
% For peak measures the paired resampling must reproduce how much the
% difference between two candidates' bSME varies across independent
% replications. Resampling with replacement around the inner bootstrap
% overstated it by ~50% (no power); half-samples rescaled to n do not.
rs = RandStream('mt19937ar', 'Seed', 80); fs = 250; t = (0.2:1/fs:0.6) * 1000; N = 60;
o = pipecompare.eval.Rank.defaults(); ref = nqc_ref(N, {'P3.lat'}, {'ms'});
sdBoot = zeros(1, 40); dpt = zeros(1, 40);
for s = 1:40
    base = 5 * exp(-0.5 * ((t - 400) / 60) .^ 2) + 4 * randn(rs, N, numel(t));
    c1 = nqc_cand(base + 6 * randn(rs, N, numel(t)), 'kind', {'peakLatency'}, 'times', t);
    c2 = nqc_cand(base + 9 * randn(rs, N, numel(t)), 'kind', {'peakLatency'}, 'times', t);
    B = pipecompare.eval.Rank.bootstrap([c1 c2], ref, o);
    sdBoot(s) = std(B{1}(2, :) - B{1}(1, :));
    dpt(s) = c2.m.composite - c1.m.composite;
end
fprintf('peak latency: SD of the difference across replications %.2f ms, paired resampling %.2f ms\n', std(dpt), mean(sdBoot));
verifyEqual(tc, mean(sdBoot), std(dpt), 'RelTol', 0.25);
end

function testIdenticalCandidatesAreNotDistinguished(tc)
% Two pipelines that give identical data (e.g. removing vs interpolating a
% channel outside the ROI) are both kept; a clearly noisier one is not.
rng(7); N = 50; ref = nqc_ref(N); x = randn(N, 1);
o = pipecompare.eval.Rank.defaults(); o.nBoot = 300;
R = pipecompare.eval.Rank.run([nqc_cand(x) nqc_cand(x) nqc_cand(2 * x)], ref, o);
verifyEqual(tc, R.table.notDistinguished, [true; true; false]);
end

function testRankingIndependentOfOtherCandidates(tc)
% Adding a candidate must not change how two others compare (0.6 failed
% this, v06_reproductions R4).
rng(2); N = 80; ref = nqc_ref(N);
base = randn(N, 1);
A = nqc_cand(base * 1.0); B = nqc_cand(base * 1.2);
o = pipecompare.eval.Rank.defaults(); o.nBoot = 500;
r1 = pipecompare.eval.Rank.run([A B], ref, o);
r2 = pipecompare.eval.Rank.run([A B nqc_cand(base * 3)], ref, o);
r3 = pipecompare.eval.Rank.run([A B nqc_cand(base * 1.1 + 0.3 * randn(N, 1))], ref, o);
verifyEqual(tc, r1.table.objective(1:2), r2.table.objective(1:2));
verifyEqual(tc, r1.table.objective(1:2), r3.table.objective(1:2));
verifyEqual(tc, r1.recommended, r2.recommended);
end

function testConstraintBoundaries(tc)
N = 20; ref = nqc_ref(N);
x = randn(N, 1);
atLimit = x; atLimit(11:end) = NaN;          % 10 of 20 trials = 50%
below = x; below(10:end) = NaN;              % 9 of 20 = 45%
o = pipecompare.eval.Rank.defaults(); o.nBoot = 100;
R = pipecompare.eval.Rank.run([nqc_cand(atLimit) nqc_cand(below)], ref, o);
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'});
verifyTrue(tc, contains(R.table.reason{2}, 'retention'));
end

function testNoFeasibleCandidateGivesNoRecommendation(tc)
N = 30; ref = nqc_ref(N);
o = pipecompare.eval.Rank.defaults(); o.minTrials = 1000; o.nBoot = 50;
R = pipecompare.eval.Rank.run([nqc_cand(randn(N, 1)) nqc_cand(randn(N, 1))], ref, o);
verifyEmpty(tc, R.recommended);
verifyEmpty(tc, R.byStratum);
txt = evalc('pipecompare.eval.Rank.print(R, {''a'',''b''})');
verifyTrue(tc, contains(txt, 'NO FEASIBLE PIPELINE'));
end

function testStrataAreRankedSeparately(tc)
rng(3); N = 60; ref = nqc_ref(N);
o = pipecompare.eval.Rank.defaults(); o.nBoot = 200;
c1 = nqc_cand(randn(N, 1), 'stratum', 'ref=average');
c2 = nqc_cand(3 * randn(N, 1), 'stratum', 'ref=mastoids');   % much noisier, other measure
R = pipecompare.eval.Rank.run([c1 c2], ref, o);
verifyEqual(tc, numel(R.byStratum), 2);
verifyEmpty(tc, R.recommended);                  % no cross-stratum winner
verifyEqual(tc, sort([R.byStratum.recommended]), [1 2]);
end

function testObjectiveAndUnitSafety(tc)
% Measures in different units cannot be combined; the user chooses the
% one to optimize, the others are reported (sme_ columns).
rng(5); N = 80;
ref = nqc_ref(N, {'obj1', 'obj2'}, {'uV', 'ms'});
A = nqc_cand({{randn(N, 1)}, {5 * randn(N, 1)}}, 'units', {'uV', 'ms'});
B = nqc_cand({{2 * randn(N, 1)}, {1 * randn(N, 1)}}, 'units', {'uV', 'ms'});
o = pipecompare.eval.Rank.defaults(); o.nBoot = 100;
verifyError(tc, @() pipecompare.eval.Rank.run([A B], ref, o), 'PipeCompare:Objective');     % composite of uV and ms
o.objective = 'obj2';
R = pipecompare.eval.Rank.run([A B], ref, o);
verifyEqual(tc, R.best, 2);
verifyEqual(tc, R.objective, 'obj2');
verifyTrue(tc, all(isfinite(R.table.sme_obj1)));                                    % still reported
o.objective = {'obj1', 'obj2'};
verifyError(tc, @() pipecompare.eval.Rank.run([A B], ref, o), 'PipeCompare:Objective');     % one objective, not a list
end

function tf = worse(a, b, ref, o)
R = pipecompare.eval.Rank.run([nqc_cand(a) nqc_cand(b)], ref, o);
tf = sum(R.table.notDistinguished) < 2;
end

% ----------------------------------------------- gain-corrected objective
function testScalingTheDataDoesNotChangeTheObjective(tc)
% score = g*a + e: a candidate that scales signal and noise by 0.92 has a
% raw SME 8% lower but measures the signal no more precisely. SME/g is
% the same for both, so neither is preferred for it, and the least
% aggressive one (no amplitude change) is recommended.
rs = RandStream('mt19937ar', 'Seed', 11); N = 60; ref = nqc_ref(N);
x = 3 + randn(rs, N, 1);
sig = @(g) struct('source', 'test', 'amplitudeError', abs(g - 1), 'latencyShiftMs', 0, 'artifactPct', 0, ...
    'waveformCorr', 1, 'topoCorr', NaN, 'chain', '', 'notApplicable', {{'topoCorr'}}, 'gain', g);
a = nqc_cand(x, 'signal', sig(1)); b = nqc_cand(0.92 * x, 'signal', sig(0.92));
verifyLessThan(tc, b.m.objectives.agg, a.m.objectives.agg);          % raw SME prefers b
o = pipecompare.eval.Rank.defaults(); o.nBoot = 199;
R = pipecompare.eval.Rank.run([a b], ref, o);
verifyEqual(tc, R.table.objective(2), R.table.objective(1), 'RelTol', 1e-12);
verifyTrue(tc, all(R.table.notDistinguished));
verifyEqual(tc, R.recommended, 1);
verifyEqual(tc, R.table.gain_P3_mean(2), 0.92);
end

function testNonPositiveGainLeavesTheObjectiveUndefined(tc)
x = randn(RandStream('mt19937ar', 'Seed', 12), 40, 1);
sig = struct('source', 'test', 'amplitudeError', 0, 'latencyShiftMs', 0, 'artifactPct', 0, ...
    'waveformCorr', 1, 'topoCorr', NaN, 'chain', '', 'notApplicable', {{'topoCorr'}}, 'gain', -0.5);
o = pipecompare.eval.Rank.defaults(); o.nBoot = 99;
R = pipecompare.eval.Rank.run(nqc_cand(x, 'signal', sig), nqc_ref(40), o);
verifyEqual(tc, R.table.status{1}, 'rejected');
verifyTrue(tc, contains(R.table.reason{1}, 'objective undefined'));
end

function testBootstrapSizesGiveAnExactQuantile(tc)
% (B+1)*alpha integer: the critical value is an order statistic of the
% bootstrap maxima, with no interpolation (Davison & Hinkley, 1997).
o = pipecompare.eval.Rank.defaults();
verifyEqual(tc, mod((o.nBoot + 1) * o.alpha, 1), 0, 'AbsTol', 1e-9);
verifyEqual(tc, mod((o.nBootPeakOuter + 1) * o.alpha, 1), 0, 'AbsTol', 1e-9);
end

function testReasonSummaryKeepsEachReasonWhole(tc)
% A reason that contains ';' (a step key with a list) or ends with a full
% stop is counted as one reason, not cut apart.
x = randn(RandStream('mt19937ar', 'Seed', 3), 30, 1);
a = nqc_cand(x); a.status = 'failed';
a.message = 'reref(exclude={EOG1;EOG2}): channel(s) not in the dataset: EOG1, EOG2 (Edit > Channel locations).';
o = pipecompare.eval.Rank.defaults(); o.nBoot = 99;
R = pipecompare.eval.Rank.run([a a], nqc_ref(30), o);
txt = evalc('pipecompare.eval.Rank.print(R, {''a'', ''b''})');
verifyTrue(tc, contains(txt, [a.message ' (x2)']));
end

% ----------------------------------------------- dependent segments
function testBlockBootstrapKeepsTheErrorRateWithDependentSegments(tc)
% Segment scores of one recording are autocorrelated. Two candidates with
% the same true noise (AR(1), phi = 0.6) must rarely be declared different;
% the moving-block bootstrap keeps the false "worse" rate near the ERP one.
rs = RandStream('mt19937ar', 'Seed', 21);
N = 120; sims = 150; phi = 0.6;
o = pipecompare.eval.Rank.defaults(); o.nBoot = 599;
ar = @(n) filter(1, [1 -phi], randn(rs, n, 1)) * sqrt(1 - phi ^ 2);
fa = [0 0];
for k = 1:sims
    common = ar(N);
    a = nqc_cand(common + ar(N)); b = nqc_cand(common + ar(N));
    for mode = 1:2
        ref = nqc_ref(N); ref.segmented = (mode == 1);
        R = pipecompare.eval.Rank.run([a b], ref, o);
        fa(mode) = fa(mode) + any(~R.table.notDistinguished);
    end
end
fprintf('AR(1) segments: false "worse" rate block %.3f, i.i.d. %.3f\n', fa / sims);
verifyLessThanOrEqual(tc, fa(1) / sims, 0.07);
end
