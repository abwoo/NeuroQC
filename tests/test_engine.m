function tests = test_engine
%TEST_ENGINE End-to-end searches on synthetic EEG with known truth, and
%   engine invariants (prefix sharing, resume, parallel, units, rules).
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
end

function testEndToEndRecoversSensibleChoice(tc)
[EEG, truth] = nqc_synth();
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], truth.roi});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 2});
p = p.add('lowpass', 'cutoff', 30);
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {75, 1000});
r = neuroqc.NeuroQC.optimize(p, c);
T = r.ranking.table;
verifyEqual(tc, numel(r.leaves), 4);
verifyEqual(tc, r.report.nNodes, 2 + 2 + 2 + 2 + 4);
% 2 Hz high-pass distorts the P3 -> rejected by the signal check
hp2 = find(contains(r.labels, 'highpass(cutoff=2)'));
verifyTrue(tc, all(strcmp(T.status(hp2), 'rejected')));
% with movement artifacts on ~15% of trials, rejecting at 75 uV beats no rejection
rec = r.ranking.recommended;
verifyTrue(tc, contains(r.labels{rec}, 'highpass(cutoff=0.1)'));
verifyTrue(tc, contains(r.labels{rec}, 'uv=75'));
% every candidate carries its full command history
verifyTrue(tc, any(contains(r.cands(rec).coms, 'pop_eegfiltnew')));
verifyTrue(tc, any(contains(r.cands(rec).coms, 'pop_rejepoch')));
% the live dataset was not modified
cur = evalin('base', 'EEG');
verifyEqual(tc, cur.history, EEG.history);
% adopt: new dataset, full history, identical SME on replay
nBefore = evalin('base', 'numel(ALLEEG)');
neuroqc.NeuroQC.adopt(r);
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), nBefore + 1);
adopted = evalin('base', 'EEG');
verifyTrue(tc, contains(adopted.history, 'pop_eegthresh'));
verifyTrue(tc, contains(adopted.history, 'pop_rejepoch'));
m = neuroqc.eval.Measure.candidate(adopted, c, r.ref);
verifyEqual(tc, m.composite, r.cands(rec).m.composite, 'RelTol', 1e-9);
verifyEqual(tc, r.signalCheck, 'injection');   % rejection is data-driven -> injection check
end

function testIcaSharedAcrossThresholds(tc)
EEG = nqc_synth(struct('seconds', 240, 'nPerCond', 50));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4','POz'}});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average');
p = p.add('ica', 'fitHighpass', 1); p = p.add('icremove', 'threshold', {0.8, 0.9});
p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, c);
verifyEqual(tc, numel(r.leaves), 2);
verifyEqual(tc, r.report.nNodes, 4 + 2 * 3); % one ICA for both thresholds
verifyTrue(tc, all(strcmp({r.cands.status}, 'ok')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'EEGica = pop_eegfiltnew')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'pop_icflag')));
end

function testNativeCommandStep(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4'}});
p = neuroqc.plan.Plan();
p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''plotfreqz'',1);');
p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, c);
verifyEqual(tc, r.cands(1).status, 'ok');
verifyTrue(tc, contains(r.cands(1).coms{1}, '''plotfreqz'',0'));
verifyEqual(tc, r.signalCheck, 'probe');                     % a native fixed filter needs no injection
verifyEqual(tc, r.cands(1).signal.source, 'filter probe');
verifyGreaterThan(tc, r.cands(1).signal.amplitudeError, 0); % filter recognised by the probe
end

% ------------------------------------------------- numerical validation

function testPrefixSharingEqualsIndependentRunsWithIca(tc)
% Shared-prefix execution must give exactly what each pipeline gives when
% run alone from the starting dataset - with real EEGLAB processing,
% including ICA (runica with rndreset 'no' is deterministic).
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average'); p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', 0.8);
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
r = neuroqc.NeuroQC.optimize(p, c);
for k = 1:numel(r.leaves)
    E = neuroqc.run.Executor.replay(r, k);
    m = neuroqc.eval.Measure.candidate(E, c, r.ref);
    verifyEqual(tc, m.composite, r.cands(k).m.composite, 'RelTol', 1e-10, r.labels{k});
    h = regexp(E.history, '[^\n]+', 'match');
    verifyEqual(tc, h(end-numel(r.cands(k).coms)+1:end), r.cands(k).coms);
end
end

function testSourceDatasetIsNeverModified(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
before = evalin('base', 'EEG');
c = nqc_c();
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('epoch'); p = p.add('baseline');
neuroqc.NeuroQC.optimize(p, c);
after = evalin('base', 'EEG');
verifyEqual(tc, after.data, before.data);
verifyEqual(tc, after.history, before.history);
verifyEqual(tc, numel(after.event), numel(before.event));
A = evalin('base', 'ALLEEG');
verifyEqual(tc, numel(A), 1);
end

function testResumeEqualsUninterruptedSearch(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 25));
nqc_setBase(EEG);
c = nqc_c();
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
full = neuroqc.NeuroQC.optimize(p, c);
d = tempname; cleanup = onCleanup(@() rmdir(d, 's'));
verifyError(tc, @() neuroqc.NeuroQC.optimize(p, c, struct('checkpoint', d, 'stopAfter', 3)), 'NeuroQC:Interrupted');
verifyEqual(tc, numel(dir(fullfile(d, 'leaf_*.mat'))), 3);
evalin('base', 'EEG.setname = ''changed after the interruption'';');   % the live data may change meanwhile
res = neuroqc.NeuroQC.resume(d);
verifyEqual(tc, {res.cands.status}, {full.cands.status});
for k = 1:numel(full.cands)
    verifyEqual(tc, res.cands(k).m.composite, full.cands(k).m.composite, 'RelTol', 1e-12);
    verifyEqual(tc, res.cands(k).coms, full.cands(k).coms);
end
verifyEqual(tc, res.ranking.recommended, full.ranking.recommended);
verifyEqual(tc, res.rootFingerprint, full.rootFingerprint);   % identity of the starting dataset kept
end

function testParallelEqualsSerial(tc)
assumeTrue(tc, license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel')), 'Parallel Computing Toolbox not available');
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 25));
nqc_setBase(EEG);
c = nqc_c();
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
s = neuroqc.NeuroQC.optimize(p, c);
q = neuroqc.NeuroQC.optimize(p, c, struct('parallel', true));
for k = 1:numel(s.cands)
    verifyEqual(tc, q.cands(k).m.composite, s.cands(k).m.composite, 'RelTol', 1e-12);
    verifyEqual(tc, q.cands(k).coms, s.cands(k).coms);
end
end

function testVoltDataAreConvertedNotMisread(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
V = EEG; V.data = V.data * 1e-6;
c = nqc_c();
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {80, 1000});
nqc_setBase(EEG); a = neuroqc.NeuroQC.optimize(p, c);
nqc_setBase(V);   b = neuroqc.NeuroQC.optimize(p, c, struct('dataUnit', 'V'));
verifyEqual(tc, [b.cands.status], [a.cands.status]);
verifyEqual(tc, arrayfun(@(x) x.m.composite, b.cands), arrayfun(@(x) x.m.composite, a.cands), 'RelTol', 1e-4);
verifyTrue(tc, any(contains(b.rootComs, '1e6')));
s = neuroqc.live.DataState.fromEEG(V);
verifyTrue(tc, any(contains(s.warnings, 'volts')));
end

function testTrialRuleExcludesPracticeBlock(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
nqc_setBase(EEG);
c0 = nqc_c();
c1 = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}}, ...
    'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
a = neuroqc.NeuroQC.optimize(p, c0); b = neuroqc.NeuroQC.optimize(p, c1);
lat = [EEG.event.latency] / EEG.srate;
expected = sum(lat >= 30 & ismember({EEG.event.type}, {'11'}));
verifyEqual(tc, b.ref.n(1), expected);
verifyLessThan(tc, sum(b.ref.n), sum(a.ref.n));
end

function testInjectionUnaffectedByTrialRule(tc)
% Trials excluded by a trial rule still carry the injected signal, so the
% injection check does not read the exclusion as amplitude loss.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}}, ...
    'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', 1000);
r = neuroqc.NeuroQC.optimize(p, c);
verifyEqual(tc, r.signalCheck, 'injection');
verifyLessThan(tc, r.cands(1).signal.amplitudeError, 0.05);
verifyEqual(tc, r.ranking.table.status{1}, 'feasible');
end

function testNoStepPipelineIsEvaluated(tc)
% "Do nothing" is a legitimate option: when every slot chooses 'none' the
% starting copy itself is a candidate.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(nqc_epoched(EEG));
p = neuroqc.plan.Plan(); p = p.addChoice('hp', {'reject_threshold', 'uv', 100}, 'none');
r = neuroqc.NeuroQC.optimize(p, nqc_contract());
verifyEqual(tc, numel(r.leaves), 2);
verifyTrue(tc, all(strcmp({r.cands.status}, 'ok')));
end

function testEveryCatalogStepRunsThroughEeglab(tc)
% Each catalog step executes as a native EEGLAB call, is recorded in the
% candidate's history, and its decisions replay on the injected copy.
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30, 'noisyChannels', {{'T7'}}, 'noisyUv', 200));
nqc_setBase(EEG);
p = neuroqc.plan.Plan();
p = p.add('linenoise', 'freq', 50);
p = p.add('highpass', 'cutoff', 0.5);
p = p.add('badchannels', 'measure', 'kurt', 'threshold', 5, 'action', 'remove');
p = p.add('restore');
p = p.add('reref', 'mode', 'average');
p = p.add('epoch'); p = p.add('baseline');
p = p.addChoice('rej', {'reject_jointprob', 'sd', 5}, {'reject_kurtosis', 'sd', 5});
r = neuroqc.NeuroQC.optimize(p, nqc_c());
verifyEqual(tc, {r.cands.status}, {'ok', 'ok'});
coms = strjoin(r.cands(1).coms, newline);
for f = {'pop_eegfiltnew', 'revfilt', 'pop_rejchan', 'pop_interp', 'pop_reref', 'pop_epoch', 'pop_rmbase', 'pop_jointprob', 'pop_rejepoch'}
    verifyTrue(tc, contains(coms, f{1}), f{1});
end
verifyTrue(tc, contains(strjoin(r.cands(2).coms, newline), 'pop_rejkurt'));
verifyEqual(tc, r.signalCheck, 'injection');
verifyEmpty(tc, [r.cands.unmatched]);          % every decision was replayed, none re-run
end

function testAsrRunsAndIsFlaggedAsNotDecisionMatched(tc)
assumeTrue(tc, exist('pop_clean_rawdata', 'file') == 2, 'clean_rawdata plugin not installed');
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 20));
nqc_setBase(EEG);
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 1); p = p.add('asr', 'cutoff', 20);
p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, nqc_c());
verifyEqual(tc, r.cands(1).status, 'ok');
verifyTrue(tc, any(contains(r.cands(1).coms, 'clean_rawdata')) || any(contains(r.cands(1).coms, 'clean_artifacts')));
verifyEqual(tc, r.cands(1).unmatched, {'asr'});
end

function testSpectralObjectiveEndToEnd(tc)
% Continuous alpha power: a 9 Hz low-pass destroys the band and must be
% rejected by the signal check; 30 Hz is fine.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 10, 'alphaUv', 10, 'artifactTrials', 0));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('analysis', 'spectral', 'segment', 2, 'bands', {'alpha', [8 12], {'Oz','O1','O2'}});
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 1); p = p.add('lowpass', 'cutoff', {9, 30});
p = p.add('epoch');
r = neuroqc.NeuroQC.optimize(p, c);
lp9 = contains(r.labels, 'cutoff=9'); lp30 = contains(r.labels, 'cutoff=30');
verifyEqual(tc, r.ranking.table.status{lp9}, 'rejected');
verifyEqual(tc, r.ranking.table.status{lp30}, 'feasible');
verifyGreaterThan(tc, r.ref.n, 50);
verifyEqual(tc, r.ref.units{1}, 'log10(uV^2)');
end

function testPeakLatencyObjective(tc)
EEG = nqc_synth(struct('seconds', 200, 'nPerCond', 40, 'p3Jitter', 0.03));
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'t', {'11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.25 0.6], {'Pz','P3','P4'}, 'peakLatency'});
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', {10, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {75, 1000});
r = neuroqc.NeuroQC.optimize(p, c, struct('objective', {{'P3.peakLatency'}}, 'nBootPeakOuter', 100, 'nBootPeak', 300));
verifyEqual(tc, r.ref.units{1}, 'ms');
ok = strcmp({r.cands.status}, 'ok');
verifyTrue(tc, all(ok));
est = arrayfun(@(x) x.m.objectives(1).estimate, r.cands);
verifyLessThan(tc, abs(est - 400), 60);   % true peak at 400 ms
verifyNotEmpty(tc, r.ranking.recommended);
end

function testNamedChannelRepairOptions(tc)
% A broken electrode is either kept, removed or interpolated - only as the
% user allows; the result reports which choice keeps more trials.
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30, 'noisyChannels', {{'O1','O2'}}, 'noisyUv', 80, 'artifactTrials', 0, 'blinkRate', 0));
nqc_setBase(EEG);
c = nqc_c();
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1);
p = p.addChoice('o1o2', {'channels', 'labels', {'O1','O2'}, 'action', 'interpolate'}, ...
    {'channels', 'labels', {'O1','O2'}, 'action', 'remove'}, 'none');
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', 100);
r = neuroqc.NeuroQC.optimize(p, c);
T = r.ranking.table;
keepAll = find(~contains(r.labels, 'channels('));
verifyEqual(tc, T.status{keepAll}, 'rejected');       % noisy O1/O2: the threshold removes every epoch
verifyEqual(tc, T.minRetention(keepAll), 0);
verifyTrue(tc, contains(T.reason{keepAll}, 'retention 0%'));
fixed = find(contains(r.labels, 'channels('));
verifyTrue(tc, all(T.minRetention(fixed) > 0.9));
verifyTrue(tc, all(contains(r.labels([r.ranking.byStratum.recommended]), 'channels(')));
end

function testVerboseNormalShowsCommandsNotEeglabChatter(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10, 'artifactTrials', 0));
nqc_setBase(EEG);
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
txt = evalc('neuroqc.NeuroQC.optimize(p, nqc_c());');
verifyTrue(tc, contains(txt, 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5'));
verifyFalse(tc, contains(txt, 'pop_eegfiltnew() - performing'));   % EEGLAB's own progress lines
verifyTrue(tc, contains(txt, 'Recommended'));
end

% ---------------------------------------------------------------- helpers
function c = nqc_c()
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
end
