function tests = test_signal
%TEST_SIGNAL Signal-preservation checks against known ground truth:
%   matched-decision injection (filters included).
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
tc.TestData.EEG = EEG;
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz'}});
tc.TestData.c = c;
tc.TestData.ref = pipecompare.eval.Measure.reference(EEG, c);
end

function testFilterDistortionIsMeasuredByInjection(tc)
% Fixed filters go through the same injection check: a gentle band keeps
% the component, a 2 Hz high-pass visibly distorts it, and the error grows
% with the high-pass edge.
hp = [0.1 0.5 1 2]; e = zeros(size(hp));
for k = 1:numel(hp)
    [S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
    in = inst('highpass', 'cutoff', hp(k));
    S = pipecompare.run.Steps.replayDecision(in, S, struct(), ctx(tc));
    r = pipecompare.eval.Injection.compare(S, tc.TestData.c, truth, {in});
    e(k) = r.amplitudeError;
end
fprintf('injection amp error HP %s: %s\n', mat2str(hp), mat2str(e, 3));
verifyLessThan(tc, e(1), 0.03);
verifyGreaterThan(tc, e(end), 0.2);
verifyTrue(tc, all(diff(e) >= -0.01));
end

function testReReferencingIsNotDistortion(tc)
[S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
in = inst('reref', 'mode', 'average', 'channels', {});
S = pipecompare.run.Steps.replayDecision(in, S, struct(), ctx(tc));
r = pipecompare.eval.Injection.compare(S, tc.TestData.c, truth, {in});
verifyLessThan(tc, r.amplitudeError, 0.02);
verifyGreaterThan(tc, r.topoCorr, 0.99);
verifyGreaterThan(tc, r.waveformCorr, 0.99);
end

function testReReferenceWithExcludedChannels(tc)
% Excluded channels (e.g. EOG) neither enter the average nor change; the
% expected field must follow the same rule.
[S0, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
in = inst('reref', 'mode', 'average', 'channels', {}, 'exclude', {'FPz', 'Oz'});
S = pipecompare.run.Steps.replayDecision(in, S0, struct(), ctx(tc));
k = strcmpi({S.chanlocs.labels}, 'FPz');
verifyEqual(tc, double(S.data(k, :)), double(S0.data(k, :)), 'AbsTol', 1e-4);
r = pipecompare.eval.Injection.compare(S, tc.TestData.c, truth, {in});
verifyLessThan(tc, r.amplitudeError, 0.02);
verifyGreaterThan(tc, r.topoCorr, 0.99);
end

function testChannelsRemovedAfterAverageReferenceAreNotDistortion(tc)
% Audit case: average reference, then P3/P4/POz removed. Removing channels
% does not change Pz, so the expected field must keep the reference over
% the channels present when it was applied (the old code re-averaged over
% the final channels and reported ~4% amplitude error).
c = pipecompare.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz'}});
[S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, c, tc.TestData.ref);
x = struct('contract', c, 'highpass', 0);
in1 = inst('reref', 'mode', 'average', 'channels', {});
in2 = inst('channels', 'labels', {'P3', 'P4', 'POz'}, 'action', 'remove');
S = pipecompare.run.Steps.replayDecision(in1, S, struct(), x);
idx = find(ismember(lower({S.chanlocs.labels}), lower({'P3', 'P4', 'POz'})));
S = pipecompare.run.Steps.replayDecision(in2, S, struct('listedIdx', idx), x);
r = pipecompare.eval.Injection.compare(S, c, truth, {in1, in2});
verifyLessThan(tc, r.amplitudeError, 0.005);
verifyGreaterThan(tc, r.waveformCorr, 0.999);
end

function testOverlappingEpochsAreNotReadAsDistortion(tc)
% Events 0.42 s apart with 1.2 s epochs: each epoch contains neighbouring
% injected responses. The expectation must include them.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 60, 'artifactTrials', 0));
c = tc.TestData.c; ref = pipecompare.eval.Measure.reference(EEG, c);
[S, truth] = pipecompare.eval.Injection.prepare(EEG, c, ref);
r = pipecompare.eval.Injection.compare(S, c, truth, {});
verifyLessThan(tc, r.amplitudeError, 0.01);
verifyLessThan(tc, r.artifactPct, 0.01);
verifyGreaterThan(tc, r.waveformCorr, 0.999);
end

function testIcaRemovalOfSignalComponentIsDetected(tc)
% With identity unmixing every component is one channel: removing the Pz
% component deletes the measured signal; removing FPz does not touch it.
[S0, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
n = S0.nbchan; labs = {S0.chanlocs.labels};
ica = struct('icaweights', eye(n), 'icasphere', eye(n), 'icachansind', 1:n);
S0 = pipecompare.run.Steps.replayDecision(inst('ica'), S0, struct('ica', ica), ctx(tc));
bad = pipecompare.run.Steps.replayDecision(inst('icremove'), S0, struct('comps', find(strcmpi(labs, 'Pz'))), ctx(tc));
good = pipecompare.run.Steps.replayDecision(inst('icremove'), S0, struct('comps', find(strcmpi(labs, 'FPz'))), ctx(tc));
rb = pipecompare.eval.Injection.compare(bad, tc.TestData.c, truth, {});
rg = pipecompare.eval.Injection.compare(good, tc.TestData.c, truth, {});
verifyGreaterThan(tc, rb.amplitudeError, 0.9);
verifyLessThan(tc, rg.amplitudeError, 0.01);
end

function testInterpolatingAnRoiChannelIsMeasured(tc)
[S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
pz = find(strcmpi({S.chanlocs.labels}, 'Pz'));
in = inst('badchannels', 'action', 'interpolate', 'measure', 'kurt', 'threshold', 5);
S = pipecompare.run.Steps.replayDecision(in, S, struct('badIdx', pz), ctx(tc));
r = pipecompare.eval.Injection.compare(S, tc.TestData.c, truth, {in});
fprintf('interpolated ROI channel: amplitude error %.3f, topo r %.3f\n', r.amplitudeError, r.topoCorr);
verifyGreaterThan(tc, r.amplitudeError, 0.001);   % the real value at Pz is replaced
% ... by a spherical-spline estimate from its neighbours. Pz is the peak of
% a focal (0.5 rad) field, so the estimate is lower than the true peak
% (measured: 0.28). The bound only checks it is an estimate of the same
% field, not a collapse (a missing channel would give 1).
verifyLessThan(tc, r.amplitudeError, 0.5);
verifyGreaterThan(tc, r.topoCorr, 0.95);
end

function testEpochRejectionDoesNotDistortTheAverage(tc)
[S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
c = tc.TestData.c;
S = pipecompare.run.Steps.replayDecision(inst('epoch'), S, struct(), ctx(tc));
S = pipecompare.run.Steps.replayDecision(inst('reject_threshold', 'uv', 100), S, struct('rejIdx', 1:5), ctx(tc));
r = pipecompare.eval.Injection.compare(S, c, truth, {});
verifyLessThan(tc, r.amplitudeError, 1e-6);
end

% ---------------------------------------------------------------- helpers
function testSignalGainIsReportedPerMeasure(tc)
% A pipeline that scales the data by 0.9 transfers the signal with gain
% 0.9; Rank divides the SME by it (see test_statistics).
[S, truth] = pipecompare.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
S.data = 0.9 * S.data;
r = pipecompare.eval.Injection.compare(S, tc.TestData.c, truth, {});
verifyEqual(tc, r.gain, 0.9, 'AbsTol', 1e-6);
verifyEqual(tc, r.amplitudeError, 0.1, 'AbsTol', 1e-6);
end

function testFieldStaysSmoothWithChannelsWithoutPositions(tc)
% Channels without coordinates (often EOG) no longer turn the injected
% field into a box over the ROI: located channels keep the smooth field,
% an unlocated channel outside the ROI gets none, one inside the ROI the
% ROI's mean field.
EEG = tc.TestData.EEG;
for lab = {'Fz', 'P3'}
    k = find(strcmpi({EEG.chanlocs.labels}, lab{1}));
    EEG.chanlocs(k).X = []; EEG.chanlocs(k).Y = []; EEG.chanlocs(k).Z = [];
end
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz', 'P3'}});
[~, truth] = pipecompare.eval.Injection.prepare(EEG, c, pipecompare.eval.Measure.reference(EEG, c));
w = truth.weights(:, 1); L = lower(truth.labels);
verifyEqual(tc, w(strcmp(L, 'fz')), 0);
verifyEqual(tc, w(strcmp(L, 'p3')), 1);
outside = w(~ismember(L, {'fz', 'pz', 'p3'}));
verifyTrue(tc, any(outside > 0.05 & outside < 0.95));     % graded, not a box
end

function testBandPowerSignalCheck(tc)
% A sinusoid at the band centre goes through the candidate: a 30 Hz
% low-pass keeps the alpha band, a 9 Hz low-pass removes most of it.
% The gain is 1 for log power (scale-free: the SD of log power does not
% change when the data are scaled).
EEG = tc.TestData.EEG;
c = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, 'bands', {'alpha', [8 12], {'Oz', 'O1', 'O2'}});
[~, root] = evalc('pipecompare.run.Executor.prepareRoot(EEG, c)');
ref = pipecompare.eval.Measure.reference(root, c);
err = zeros(1, 2); cut = [30 9];
for k = 1:2
    [S, truth] = pipecompare.eval.Injection.prepare(root, c, ref);
    in = inst('lowpass', 'cutoff', cut(k));
    S = pipecompare.run.Steps.replayDecision(in, S, struct(), ctx(tc));
    r = pipecompare.eval.Injection.compare(S, c, truth, {in});
    err(k) = r.amplitudeError;
    verifyEqual(tc, r.gain, 1);
end
verifyLessThan(tc, err(1), 0.02);
verifyGreaterThan(tc, err(2), 0.3);
end

function s = inst(type, varargin)
p = struct();
for k = 1:2:numel(varargin), p.(varargin{k}) = varargin{k+1}; end
s = struct('type', type, 'params', p, 'key', type, 'slot', type, 'label', type);
end

function x = ctx(tc)
x = struct('contract', tc.TestData.c, 'highpass', 0);
end
