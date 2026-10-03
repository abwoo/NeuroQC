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
verifyEqual(tc, neuroqc.eval.Measure.sme(S), std([1 2 3 4]) / 2, 'AbsTol', 1e-12);
end

function testSmeMatchesEmpiricalSdOfTheMean(tc)
% SME must estimate the SD of the averaged score across replications.
rs = RandStream('mt19937ar', 'Seed', 11);
N = 40; sigma = 7; reps = 4000;
m = zeros(reps, 1); sme = zeros(reps, 1);
for r = 1:reps
    x = 3 + sigma * randn(rs, N, 1);
    m(r) = mean(x); sme(r) = neuroqc.eval.Measure.sme(x);
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
opts = neuroqc.eval.Measure.defaults(); opts.nBootPeak = 400;
lat = zeros(reps, 1); bsme = zeros(reps, 1);
for r = 1:reps
    X = 5 * exp(-0.5 * ((t - 400) / 60) .^ 2) + 8 * randn(rs, N, numel(t));
    [lat(r), bsme(r)] = neuroqc.eval.Measure.estimate(o, X, opts, r);
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
N = 100; sims = 150; o = neuroqc.eval.Rank.defaults(); o.nBoot = 800;
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
% ANY of them is declared worse must stay near 5%. Per-comparison
% intervals against the selected best (adjust = 'none') fail this badly
% (audit: 87/100 searches), the default simultaneous procedure must not.
rs = RandStream('mt19937ar', 'Seed', 12);
K = 24; sims = 80; o = neuroqc.eval.Rank.defaults(); o.nBoot = 600;
for N = [30 100]
    ref = nqc_ref(N);
    fwer = 0; fwerNone = 0; frac = 0;
    for k = 1:sims
        common = randn(rs, N, 1);
        cs = arrayfun(@(j) nqc_cand(common + randn(rs, N, 1)), 1:K);
        R = neuroqc.eval.Rank.run(cs, ref, o);
        fwer = fwer + any(~R.table.notDistinguished); frac = frac + mean(~R.table.notDistinguished);
        oN = o; oN.adjust = 'none';
        R = neuroqc.eval.Rank.run(cs, ref, oN);
        fwerNone = fwerNone + any(~R.table.notDistinguished);
    end
    fprintf('%d candidates, %d trials: any false "worse" %.3f (adjust none: %.3f), mean share %.4f\n', ...
        K, N, fwer / sims, fwerNone / sims, frac / sims);
    verifyLessThanOrEqual(tc, fwer / sims, 0.08);
    verifyGreaterThan(tc, fwerNone / sims, 0.3);       % the problem the default avoids
end
end

function testPowerDoesNotCollapseWithManyCandidates(tc)
% A clearly noisier candidate (1.4x SD) among 23 equal ones must still
% usually be declared worse.
rs = RandStream('mt19937ar', 'Seed', 13);
N = 100; sims = 40; ref = nqc_ref(N); o = neuroqc.eval.Rank.defaults(); o.nBoot = 600;
hit = 0;
for k = 1:sims
    common = randn(rs, N, 1);
    cs = arrayfun(@(j) nqc_cand(common + randn(rs, N, 1)), 1:23);
    cs(24) = nqc_cand(common + 1.71 * randn(rs, N, 1));
    R = neuroqc.eval.Rank.run(cs, ref, o);
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
o = neuroqc.eval.Rank.defaults(); o.nBoot = 100;
ok = struct('source', 'injection', 'amplitudeError', 0.01, 'latencyShiftMs', 0, 'artifactPct', 0, ...
    'waveformCorr', 0.99, 'topoCorr', 0.99, 'chain', '', 'notApplicable', {{}});
nanAmp = ok; nanAmp.amplitudeError = NaN; nanAmp.waveformCorr = NaN;
naTopo = ok; naTopo.topoCorr = NaN; naTopo.notApplicable = {'topoCorr'};
cs = [nqc_cand(x, 'signal', ok) nqc_cand(x, 'signal', nanAmp) nqc_cand(x, 'signal', naTopo) nqc_cand(x)];
cs(4).signal = [];
R = neuroqc.eval.Rank.run(cs, ref, o);
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'; 'feasible'; 'rejected'});
verifyTrue(tc, contains(R.table.reason{2}, 'amplitudeError not computed'));
verifyTrue(tc, contains(R.table.reason{2}, 'waveformCorr not computed'));
verifyTrue(tc, contains(R.table.reason{4}, 'signal check missing'));
% a NaN retention / interpolation count is not a pass either
c5 = nqc_cand(x); c5.interpolatedFraction = NaN;
R = neuroqc.eval.Rank.run(c5, ref, o);
verifyEqual(tc, R.table.status, {'rejected'});
end

function testPeakComparisonSpreadMatchesReplications(tc)
% For peak measures the paired resampling must reproduce how much the
% difference between two candidates' bSME varies across independent
% replications. Resampling with replacement around the inner bootstrap
% overstated it by ~50% (no power); half-samples rescaled to n do not.
rs = RandStream('mt19937ar', 'Seed', 80); fs = 250; t = (0.2:1/fs:0.6) * 1000; N = 60;
o = neuroqc.eval.Rank.defaults(); ref = nqc_ref(N, {'P3.lat'}, {'ms'});
sdBoot = zeros(1, 40); dpt = zeros(1, 40);
for s = 1:40
    base = 5 * exp(-0.5 * ((t - 400) / 60) .^ 2) + 4 * randn(rs, N, numel(t));
    c1 = nqc_cand(base + 6 * randn(rs, N, numel(t)), 'kind', {'peakLatency'}, 'times', t);
    c2 = nqc_cand(base + 9 * randn(rs, N, numel(t)), 'kind', {'peakLatency'}, 'times', t);
    B = neuroqc.eval.Rank.bootstrap([c1 c2], ref, o);
    sdBoot(s) = std(B{1}(2, :) - B{1}(1, :));
    dpt(s) = c2.m.composite - c1.m.composite;
end
fprintf('peak latency: SD of the difference across replications %.2f ms, paired resampling %.2f ms\n', std(dpt), mean(sdBoot));
verifyEqual(tc, mean(sdBoot), std(dpt), 'RelTol', 0.25);
end

function testEquivalenceNeedsAMarginAndEvidence(tc)
% "Not distinguished" is not equivalence. With a margin, equivalence is
% claimed when the 90% CI of the difference lies within it: often for
% equal noise and many trials, rarely when the true difference exceeds
% the margin.
rs = RandStream('mt19937ar', 'Seed', 8);
N = 200; sims = 60; ref = nqc_ref(N);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 600;
eqSame = 0; eqDiff = 0;
for k = 1:sims
    common = randn(rs, N, 1);
    a = common + randn(rs, N, 1); b = common + randn(rs, N, 1); c = common + 2 * randn(rs, N, 1);
    sa = std(a) / sqrt(N);
    o.equivalenceMargin = 0.25 * sa;   % 25% of the SME
    R = neuroqc.eval.Rank.run([nqc_cand(a) nqc_cand(b)], ref, o);
    eqSame = eqSame + all(R.table.equivalent == 1);
    R = neuroqc.eval.Rank.run([nqc_cand(a) nqc_cand(c)], ref, o);
    eqDiff = eqDiff + all(R.table.equivalent == 1);
end
o.equivalenceMargin = [];
R = neuroqc.eval.Rank.run([nqc_cand(a) nqc_cand(b)], ref, o);
fprintf('equivalence claimed: equal noise %.2f, 1.6x noise %.2f\n', eqSame / sims, eqDiff / sims);
verifyGreaterThan(tc, eqSame / sims, 0.5);
verifyLessThan(tc, eqDiff / sims, 0.05);
verifyTrue(tc, all(isnan(R.table.equivalent)));      % no margin -> no equivalence claim
end

function testProbabilityOfBeingBest(tc)
rng(1); N = 150; ref = nqc_ref(N); base = randn(N, 1);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 500;
R = neuroqc.eval.Rank.run([nqc_cand(base + 0.5 * randn(N, 1)) nqc_cand(base * 1.5 + randn(N, 1)) ...
    nqc_cand(base + 0.5 * randn(N, 1))], ref, o);
verifyEqual(tc, sum(R.table.probBest), 1, 'AbsTol', 1e-12);
verifyLessThan(tc, R.table.probBest(2), 0.01);
end

function testIdenticalCandidatesShareProbabilityOfBeingBest(tc)
% Two pipelines that give identical data (e.g. removing vs interpolating a
% channel outside the ROI) must not have probBest assigned to one of them.
rng(7); N = 50; ref = nqc_ref(N); x = randn(N, 1);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 300;
R = neuroqc.eval.Rank.run([nqc_cand(x) nqc_cand(x) nqc_cand(2 * x)], ref, o);
verifyEqual(tc, R.table.probBest(1:2), [0.5; 0.5], 'AbsTol', 1e-12);
end

function testRankingIndependentOfOtherCandidates(tc)
% Adding a candidate must not change how two others compare (0.6 failed
% this, v06_reproductions R4).
rng(2); N = 80; ref = nqc_ref(N);
base = randn(N, 1);
A = nqc_cand(base * 1.0); B = nqc_cand(base * 1.2);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 500;
r1 = neuroqc.eval.Rank.run([A B], ref, o);
r2 = neuroqc.eval.Rank.run([A B nqc_cand(base * 3)], ref, o);
r3 = neuroqc.eval.Rank.run([A B nqc_cand(base * 1.1 + 0.3 * randn(N, 1))], ref, o);
verifyEqual(tc, r1.table.objective(1:2), r2.table.objective(1:2));
verifyEqual(tc, r1.table.objective(1:2), r3.table.objective(1:2));
verifyEqual(tc, r1.recommended, r2.recommended);
end

function testConstraintBoundaries(tc)
N = 20; ref = nqc_ref(N);
x = randn(N, 1);
atLimit = x; atLimit(11:end) = NaN;          % 10 of 20 trials = 50%
below = x; below(10:end) = NaN;              % 9 of 20 = 45%
o = neuroqc.eval.Rank.defaults(); o.nBoot = 100;
R = neuroqc.eval.Rank.run([nqc_cand(atLimit) nqc_cand(below)], ref, o);
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'});
verifyTrue(tc, contains(R.table.reason{2}, 'retention'));
end

function testNoFeasibleCandidateGivesNoRecommendation(tc)
N = 30; ref = nqc_ref(N);
o = neuroqc.eval.Rank.defaults(); o.minTrials = 1000; o.nBoot = 50;
R = neuroqc.eval.Rank.run([nqc_cand(randn(N, 1)) nqc_cand(randn(N, 1))], ref, o);
verifyEmpty(tc, R.recommended);
verifyEmpty(tc, R.byStratum);
txt = evalc('neuroqc.eval.Rank.print(R, {''a'',''b''})');
verifyTrue(tc, contains(txt, 'NO FEASIBLE PIPELINE'));
end

function testStrataAreRankedSeparately(tc)
rng(3); N = 60; ref = nqc_ref(N);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 200;
c1 = nqc_cand(randn(N, 1), 'stratum', 'ref=average');
c2 = nqc_cand(3 * randn(N, 1), 'stratum', 'ref=mastoids');   % much noisier, other measure
R = neuroqc.eval.Rank.run([c1 c2], ref, o);
verifyEqual(tc, numel(R.byStratum), 2);
verifyEmpty(tc, R.recommended);                  % no cross-stratum winner
verifyEqual(tc, sort([R.byStratum.recommended]), [1 2]);
end

function testPriorityObjectivesAreLexicographic(tc)
% Two objectives: A and B are indistinguishable on the first, B is
% clearly better on the second -> B. Units may differ (uV, ms).
rng(4); N = 120; ref = nqc_ref(N, {'P3.mean', 'N2.mean'}, {'uV', 'uV'});
base = randn(N, 1);
A = nqc_cand({{base + 0.05 * randn(N, 1)}, {3 * randn(N, 1)}});
B = nqc_cand({{base + 0.05 * randn(N, 1)}, {1 * randn(N, 1)}});
C = nqc_cand({{2 * base}, {0.5 * randn(N, 1)}});
o = neuroqc.eval.Rank.defaults(); o.nBoot = 400;
o.objective = {'obj1', 'obj2'};
ref.objectives = {'obj1', 'obj2'};
R = neuroqc.eval.Rank.run([A B C], ref, o);
verifyEqual(tc, R.recommended, 2);
verifyFalse(tc, R.table.notDistinguished(3));     % C is worse on the first objective
end

function testParetoAndUnitSafety(tc)
rng(5); N = 80;
ref = nqc_ref(N, {'obj1', 'obj2'}, {'uV', 'ms'});
A = nqc_cand({{randn(N, 1)}, {5 * randn(N, 1)}}, 'units', {'uV', 'ms'});
B = nqc_cand({{2 * randn(N, 1)}, {1 * randn(N, 1)}}, 'units', {'uV', 'ms'});
C = nqc_cand({{3 * randn(N, 1)}, {6 * randn(N, 1)}}, 'units', {'uV', 'ms'});
o = neuroqc.eval.Rank.defaults(); o.nBoot = 100;
verifyError(tc, @() neuroqc.eval.Rank.run([A B C], ref, o), 'NeuroQC:Objective'); % composite of uV and ms
o.objective = 'pareto';
R = neuroqc.eval.Rank.run([A B C], ref, o);
verifyEqual(tc, find(R.table.pareto)', [1 2]);
verifyEmpty(tc, R.recommended);                   % two non-dominated: no single winner
end

function testExternalQcColumnsAndLimits(tc)
% Imported QC values are joined by pipeline key, shown as columns and can
% exclude candidates; a candidate without a value is not given one.
rng(9); N = 40; ref = nqc_ref(N);
A = nqc_cand(randn(N, 1), 'key', 'hp=0.1'); B = nqc_cand(randn(N, 1), 'key', 'hp=1'); C = nqc_cand(randn(N, 1), 'key', 'hp=2');
Q = table({'hp=0.1'; 'hp=1'}, [0.2; 0.9], 'VariableNames', {'key', 'icFraction'});
o = neuroqc.eval.Rank.defaults(); o.nBoot = 100;
o.externalQC = Q; o.externalLimits = struct('icFraction', [0 0.5]);
R = neuroqc.eval.Rank.run([A B C], ref, o);
verifyEqual(tc, R.table.ext_icFraction(1:2), [0.2; 0.9]);
verifyTrue(tc, isnan(R.table.ext_icFraction(3)));
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'; 'rejected'});   % no value -> outside the limit
verifyTrue(tc, contains(R.table.reason{2}, 'icFraction'));
end

function testBonferroniWidensIntervals(tc)
rng(6); N = 60; ref = nqc_ref(N); base = randn(N, 1);
cs = arrayfun(@(k) nqc_cand(base + 0.8 * randn(N, 1)), 1:6);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 2000; o.adjust = 'none';
R1 = neuroqc.eval.Rank.run(cs, ref, o);
o.adjust = 'bonferroni';
R2 = neuroqc.eval.Rank.run(cs, ref, o);
w1 = R1.table.diffHi - R1.table.diffLo; w2 = R2.table.diffHi - R2.table.diffLo;
k = w1 > 0;
verifyTrue(tc, all(w2(k) >= w1(k)));
verifyGreaterThanOrEqual(tc, sum(R2.table.notDistinguished), sum(R1.table.notDistinguished));
end

% ---------------------------------------------------------------- helpers
function tf = worse(a, b, ref, o)
R = neuroqc.eval.Rank.run([nqc_cand(a) nqc_cand(b)], ref, o);
tf = sum(R.table.notDistinguished) < 2;
end
