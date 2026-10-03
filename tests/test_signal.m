function tests = test_signal
%TEST_SIGNAL Signal-preservation checks against known ground truth:
%   filter probe and matched-decision injection.
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
tc.TestData.EEG = EEG;
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz'}});
tc.TestData.c = c;
tc.TestData.ref = neuroqc.eval.Measure.reference(EEG, c);
end

% ------------------------------------------------------------ filter probe
function testFilterProbe(tc)
c = nqc_contract();
gentle = neuroqc.eval.FilterProbe.run({inst('highpass', 'cutoff', 0.1), inst('lowpass', 'cutoff', 30)}, 250, c);
harsh = neuroqc.eval.FilterProbe.run({inst('highpass', 'cutoff', 2)}, 250, c);
none = neuroqc.eval.FilterProbe.run({}, 250, c);
verifyLessThan(tc, gentle.amplitudeError, 0.05);
verifyLessThan(tc, gentle.artifactPct, 0.05);
verifyGreaterThan(tc, harsh.amplitudeError, 0.2);
verifyGreaterThan(tc, harsh.artifactPct, gentle.artifactPct);
verifyEqual(tc, none.amplitudeError, 0);
end

function testFilterProbeIsMonotonicAndNeutral(tc)
c = nqc_contract();
hp = [0.05 0.1 0.3 0.5 1 2]; lp = [10 20 30 40];
eh = arrayfun(@(v) neuroqc.eval.FilterProbe.run({inst('highpass', 'cutoff', v)}, 500, c).amplitudeError, hp);
el = arrayfun(@(v) neuroqc.eval.FilterProbe.run({inst('lowpass', 'cutoff', v)}, 500, c).amplitudeError, lp);
rs = neuroqc.eval.FilterProbe.run({inst('resample', 'fs', 250)}, 500, c);
fprintf('probe amp error HP %s: %s\nprobe amp error LP %s: %s\n', mat2str(hp), mat2str(eh, 3), mat2str(lp), mat2str(el, 3));
verifyTrue(tc, all(diff(eh) >= -1e-4));
verifyTrue(tc, all(diff(el) <= 1e-4));
verifyLessThan(tc, eh(2), 0.02);
verifyLessThan(tc, rs.amplitudeError, 0.01);
end

function testSpectralProbe(tc)
c = neuroqc.eval.Contract('analysis', 'spectral', 'segment', 2, 'bands', {'alpha', [8 12], {'Oz'}});
ok = neuroqc.eval.FilterProbe.run({inst('lowpass', 'cutoff', 30)}, 250, c);
bad = neuroqc.eval.FilterProbe.run({inst('lowpass', 'cutoff', 9)}, 250, c);
verifyLessThan(tc, ok.amplitudeError, 0.01);
verifyGreaterThan(tc, bad.amplitudeError, 0.3);
end

% -------------------------------------------------------------- injection
function testReReferencingIsNotDistortion(tc)
[S, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
in = inst('reref', 'mode', 'average', 'channels', {});
S = neuroqc.run.Steps.replayDecision(in, S, struct(), ctx(tc));
r = neuroqc.eval.Injection.compare(S, tc.TestData.c, truth, {in});
verifyLessThan(tc, r.amplitudeError, 0.02);
verifyGreaterThan(tc, r.topoCorr, 0.99);
verifyGreaterThan(tc, r.waveformCorr, 0.99);
end

function testReReferenceWithExcludedChannels(tc)
% Excluded channels (e.g. EOG) neither enter the average nor change; the
% expected field must follow the same rule.
[S0, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
in = inst('reref', 'mode', 'average', 'channels', {}, 'exclude', {'FPz', 'Oz'});
S = neuroqc.run.Steps.replayDecision(in, S0, struct(), ctx(tc));
k = strcmpi({S.chanlocs.labels}, 'FPz');
verifyEqual(tc, double(S.data(k, :)), double(S0.data(k, :)), 'AbsTol', 1e-4);
r = neuroqc.eval.Injection.compare(S, tc.TestData.c, truth, {in});
verifyLessThan(tc, r.amplitudeError, 0.02);
verifyGreaterThan(tc, r.topoCorr, 0.99);
end

function testChannelsRemovedAfterAverageReferenceAreNotDistortion(tc)
% Audit case: average reference, then P3/P4/POz removed. Removing channels
% does not change Pz, so the expected field must keep the reference over
% the channels present when it was applied (the old code re-averaged over
% the final channels and reported ~4% amplitude error).
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz'}});
[S, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, c, tc.TestData.ref);
x = struct('contract', c, 'highpass', 0);
in1 = inst('reref', 'mode', 'average', 'channels', {});
in2 = inst('channels', 'labels', {'P3', 'P4', 'POz'}, 'action', 'remove');
S = neuroqc.run.Steps.replayDecision(in1, S, struct(), x);
idx = find(ismember(lower({S.chanlocs.labels}), lower({'P3', 'P4', 'POz'})));
S = neuroqc.run.Steps.replayDecision(in2, S, struct('listedIdx', idx), x);
r = neuroqc.eval.Injection.compare(S, c, truth, {in1, in2});
verifyLessThan(tc, r.amplitudeError, 0.005);
verifyGreaterThan(tc, r.waveformCorr, 0.999);
end

function testOverlappingEpochsAreNotReadAsDistortion(tc)
% Events 0.42 s apart with 1.2 s epochs: each epoch contains neighbouring
% injected responses. The expectation must include them.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 60, 'artifactTrials', 0));
c = tc.TestData.c; ref = neuroqc.eval.Measure.reference(EEG, c);
[S, truth] = neuroqc.eval.Injection.prepare(EEG, c, ref);
r = neuroqc.eval.Injection.compare(S, c, truth, {});
verifyLessThan(tc, r.amplitudeError, 0.01);
verifyLessThan(tc, r.artifactPct, 0.01);
verifyGreaterThan(tc, r.waveformCorr, 0.999);
end

function testIcaRemovalOfSignalComponentIsDetected(tc)
% With identity unmixing every component is one channel: removing the Pz
% component deletes the measured signal; removing FPz does not touch it.
[S0, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
n = S0.nbchan; labs = {S0.chanlocs.labels};
ica = struct('icaweights', eye(n), 'icasphere', eye(n), 'icachansind', 1:n);
S0 = neuroqc.run.Steps.replayDecision(inst('ica'), S0, struct('ica', ica), ctx(tc));
bad = neuroqc.run.Steps.replayDecision(inst('icremove'), S0, struct('comps', find(strcmpi(labs, 'Pz'))), ctx(tc));
good = neuroqc.run.Steps.replayDecision(inst('icremove'), S0, struct('comps', find(strcmpi(labs, 'FPz'))), ctx(tc));
rb = neuroqc.eval.Injection.compare(bad, tc.TestData.c, truth, {});
rg = neuroqc.eval.Injection.compare(good, tc.TestData.c, truth, {});
verifyGreaterThan(tc, rb.amplitudeError, 0.9);
verifyLessThan(tc, rg.amplitudeError, 0.01);
end

function testInterpolatingAnRoiChannelIsMeasured(tc)
[S, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
pz = find(strcmpi({S.chanlocs.labels}, 'Pz'));
in = inst('badchannels', 'action', 'interpolate', 'measure', 'kurt', 'threshold', 5);
S = neuroqc.run.Steps.replayDecision(in, S, struct('badIdx', pz), ctx(tc));
r = neuroqc.eval.Injection.compare(S, tc.TestData.c, truth, {in});
fprintf('interpolated ROI channel: amplitude error %.3f, topo r %.3f\n', r.amplitudeError, r.topoCorr);
verifyGreaterThan(tc, r.amplitudeError, 0.001);   % the real value at Pz is replaced
% ... by a spherical-spline estimate from its neighbours. Pz is the peak of
% a focal (0.5 rad) field, so the estimate is lower than the true peak
% (measured: 0.28). The bound only checks it is an estimate of the same
% field, not a collapse (a missing channel would give 1).
verifyLessThan(tc, r.amplitudeError, 0.5);
verifyGreaterThan(tc, r.topoCorr, 0.95);
end

function testHighpassDistortionAgreesWithProbe(tc)
[S, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
in = inst('highpass', 'cutoff', 2);
S = neuroqc.run.Steps.replayDecision(in, S, struct(), ctx(tc));
r = neuroqc.eval.Injection.compare(S, tc.TestData.c, truth, {in});
p = neuroqc.eval.FilterProbe.run({in}, 250, tc.TestData.c);
verifyEqual(tc, r.amplitudeError, p.amplitudeError, 'AbsTol', 0.03);
end

function testEpochRejectionDoesNotDistortTheAverage(tc)
[S, truth] = neuroqc.eval.Injection.prepare(tc.TestData.EEG, tc.TestData.c, tc.TestData.ref);
c = tc.TestData.c;
S = neuroqc.run.Steps.replayDecision(inst('epoch'), S, struct(), ctx(tc));
S = neuroqc.run.Steps.replayDecision(inst('reject_threshold', 'uv', 100), S, struct('rejIdx', 1:5), ctx(tc));
r = neuroqc.eval.Injection.compare(S, c, truth, {});
verifyLessThan(tc, r.amplitudeError, 1e-6);
end

% ---------------------------------------------------------------- helpers
function s = inst(type, varargin)
p = struct();
for k = 1:2:numel(varargin), p.(varargin{k}) = varargin{k+1}; end
s = struct('type', type, 'params', p, 'key', type, 'slot', type, 'label', type);
end

function x = ctx(tc)
x = struct('contract', tc.TestData.c, 'highpass', 0);
end
