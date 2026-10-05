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
c = pipecompare.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], truth.roi});
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 2});
p = p.add('lowpass', 'cutoff', 30);
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {75, 1000});
r = pipecompare.PipeCompare.optimize(p, c);
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
pipecompare.PipeCompare.adopt(r);
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), nBefore + 1);
adopted = evalin('base', 'EEG');
verifyTrue(tc, contains(adopted.history, 'pop_eegthresh'));
verifyTrue(tc, contains(adopted.history, 'pop_rejepoch'));
m = pipecompare.eval.Measure.candidate(adopted, c, r.ref);
verifyEqual(tc, m.composite, r.cands(rec).m.composite, 'RelTol', 1e-9);
end

function testIcaSharedAcrossThresholds(tc)
EEG = nqc_synth(struct('seconds', 240, 'nPerCond', 50));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4','POz'}});
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average');
p = p.add('ica', 'fitHighpass', 1); p = p.add('icremove', 'threshold', {0.8, 0.9});
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
verifyEqual(tc, numel(r.leaves), 2);
verifyEqual(tc, r.report.nNodes, 4 + 2 * 3); % one ICA for both thresholds
verifyTrue(tc, all(strcmp({r.cands.status}, 'ok')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'EEGica = pop_eegfiltnew')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'pop_icflag')));
end

function testNativeCommandStep(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4'}});
p = pipecompare.plan.Plan();
p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''plotfreqz'',1);');
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
verifyEqual(tc, r.cands(1).status, 'ok');
verifyTrue(tc, contains(r.cands(1).coms{1}, '''plotfreqz'',0'));
verifyEqual(tc, r.cands(1).signal.source, 'injection');
verifyGreaterThan(tc, r.cands(1).signal.amplitudeError, 0); % the filter's effect on the known signal is measured
end

% ------------------------------------------------- numerical validation

function testPrefixSharingEqualsIndependentRunsWithIca(tc)
% Shared-prefix execution must give exactly what each pipeline gives when
% run alone from the starting dataset - with real EEGLAB processing,
% including ICA (runica with rndreset 'no' is deterministic).
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average'); p = p.add('ica', 'fitHighpass', 1);
p = p.add('icremove', 'threshold', 0.8);
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
r = pipecompare.PipeCompare.optimize(p, c);
for k = 1:numel(r.leaves)
    E = pipecompare.run.Executor.replay(r, k);
    m = pipecompare.eval.Measure.candidate(E, c, r.ref);
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
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('epoch'); p = p.add('baseline');
pipecompare.PipeCompare.optimize(p, c);
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
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
full = pipecompare.PipeCompare.optimize(p, c);
d = tempname; cleanup = onCleanup(@() rmdir(d, 's'));
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, c, struct('checkpoint', d, 'stopAfter', 3)), 'PipeCompare:Interrupted');
verifyEqual(tc, numel(dir(fullfile(d, 'leaf_*.mat'))), 3);
evalin('base', 'EEG.setname = ''changed after the interruption'';');   % the live data may change meanwhile
res = pipecompare.PipeCompare.resume(d);
verifyEqual(tc, {res.cands.status}, {full.cands.status});
for k = 1:numel(full.cands)
    verifyEqual(tc, res.cands(k).m.composite, full.cands(k).m.composite, 'RelTol', 1e-12);
    verifyEqual(tc, res.cands(k).coms, full.cands(k).coms);
end
verifyEqual(tc, res.ranking.recommended, full.ranking.recommended);
verifyEqual(tc, res.rootFingerprint, full.rootFingerprint);   % identity of the starting dataset kept
% resuming with the relative folder name still stores the absolute path
% (it is used to read the starting dataset back from any folder later)
[parent, name] = fileparts(d);
here = pwd; cd(parent); c3 = onCleanup(@() cd(here)); %#ok<NASGU>
res2 = pipecompare.PipeCompare.resume(name);
cd(here);
w = what(d); verifyEqual(tc, res2.options.checkpoint, w(1).path);
res2.root = [];
E = pipecompare.run.Executor.rootOf(res2);
verifyEqual(tc, E.nbchan, EEG.nbchan);
end

function testParallelEqualsSerial(tc)
assumeTrue(tc, license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel')), 'Parallel Computing Toolbox not available');
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 25));
nqc_setBase(EEG);
c = nqc_c();
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
s = pipecompare.PipeCompare.optimize(p, c);
q = pipecompare.PipeCompare.optimize(p, c, struct('parallel', true));
for k = 1:numel(s.cands)
    verifyEqual(tc, q.cands(k).m.composite, s.cands(k).m.composite, 'RelTol', 1e-12);
    verifyEqual(tc, q.cands(k).coms, s.cands(k).coms);
end
end

function testVoltDataAreConvertedNotMisread(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
V = EEG; V.data = V.data * 1e-6;
c = nqc_c();
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {80, 1000});
nqc_setBase(EEG); a = pipecompare.PipeCompare.optimize(p, c);
nqc_setBase(V);   b = pipecompare.PipeCompare.optimize(p, c, struct('dataUnit', 'V'));
verifyEqual(tc, [b.cands.status], [a.cands.status]);
verifyEqual(tc, arrayfun(@(x) x.m.composite, b.cands), arrayfun(@(x) x.m.composite, a.cands), 'RelTol', 1e-4);
verifyTrue(tc, any(contains(b.rootComs, '1e6')));
s = pipecompare.live.DataState.fromEEG(V);
verifyTrue(tc, any(contains(s.warnings, 'volts')));
end

function testTrialRuleExcludesPracticeBlock(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
nqc_setBase(EEG);
c0 = nqc_c();
c1 = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}}, ...
    'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
a = pipecompare.PipeCompare.optimize(p, c0); b = pipecompare.PipeCompare.optimize(p, c1);
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
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}}, ...
    'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', 1000);
r = pipecompare.PipeCompare.optimize(p, c);
verifyLessThan(tc, r.cands(1).signal.amplitudeError, 0.05);
verifyEqual(tc, r.ranking.table.status{1}, 'feasible');
end

function testNoStepPipelineIsEvaluated(tc)
% "Do nothing" is a legitimate option: when every slot chooses 'none' the
% starting copy itself is a candidate.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(nqc_epoched(EEG));
p = pipecompare.plan.Plan(); p = p.addChoice('hp', {'reject_threshold', 'uv', 100}, 'none');
r = pipecompare.PipeCompare.optimize(p, nqc_contract());
verifyEqual(tc, numel(r.leaves), 2);
verifyTrue(tc, all(strcmp({r.cands.status}, 'ok')));
end

function testEveryCatalogStepRunsThroughEeglab(tc)
% Each catalog step executes as a native EEGLAB call, is recorded in the
% candidate's history, and its decisions replay on the injected copy.
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30, 'noisyChannels', {{'T7'}}, 'noisyUv', 200));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.add('linenoise', 'freq', 50);
p = p.add('highpass', 'cutoff', 0.5);
p = p.add('badchannels', 'measure', 'kurt', 'threshold', 5, 'action', 'remove');
p = p.add('restore');
p = p.add('reref', 'mode', 'average');
p = p.add('epoch'); p = p.add('baseline');
p = p.addChoice('rej', {'reject_jointprob', 'sd', 5}, {'reject_kurtosis', 'sd', 5});
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, {r.cands.status}, {'ok', 'ok'});
coms = strjoin(r.cands(1).coms, newline);
for f = {'pop_eegfiltnew', 'revfilt', 'pop_rejchan', 'pop_interp', 'pop_reref', 'pop_epoch', 'pop_rmbase', 'pop_jointprob', 'pop_rejepoch'}
    verifyTrue(tc, contains(coms, f{1}), f{1});
end
verifyTrue(tc, contains(strjoin(r.cands(2).coms, newline), 'pop_rejkurt'));
verifyEmpty(tc, [r.cands.unmatched]);          % every decision was replayed, none re-run
end

function testAsrDecisionsAreReplayedOnTheSignalCopy(tc)
% ASR's window-by-window reconstructions on the real data are recorded
% (verified against EEGLAB's own output) and applied to the injected copy:
% decision-matched, like every other data-driven step.
assumeTrue(tc, exist('pop_clean_rawdata', 'file') == 2, 'clean_rawdata plugin not installed');
assumeTrue(tc, exist('yulewalk', 'file') == 2, 'ASR at 250 Hz needs the Signal Processing Toolbox');
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', 1); p = p.add('asr', 'cutoff', {10, 20});
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
for k = 1:2
    verifyEqual(tc, r.cands(k).status, 'ok');
    verifyEmpty(tc, r.cands(k).unmatched);                     % decision-matched
    verifyTrue(tc, any(contains(r.cands(k).coms, '''MaxMem'',64')));
    verifyTrue(tc, isfinite(r.cands(k).signal.amplitudeError));
end
% the recorded decisions are ASR's: replaying them on the real data gives
% exactly EEGLAB's output, and they are linear in the data
[~, E] = evalc('pop_eegfiltnew(EEG, ''locutoff'', 1, ''plotfreqz'', 0)');
[~, E1] = evalc('pop_clean_rawdata(E, ''FlatlineCriterion'',''off'',''ChannelCriterion'',''off'',''LineNoiseCriterion'',''off'',''Highpass'',''off'',''BurstCriterion'',10,''WindowCriterion'',''off'',''BurstRejection'',''off'',''Distance'',''Euclidian'',''MaxMem'',64)');
rec = pipecompare.run.AsrRecord.record(E, 10);
verifyEqual(tc, pipecompare.run.AsrRecord.apply(rec, E.data), double(E1.data), 'AbsTol', 1e-9);
verifyGreaterThan(tc, sum(~[rec.updates.trivial]), 0);              % ASR did change windows
A = randn(size(E.data)); B = randn(size(E.data));
verifyEqual(tc, pipecompare.run.AsrRecord.apply(rec, A + 2 * B), ...
    pipecompare.run.AsrRecord.apply(rec, A) + 2 * pipecompare.run.AsrRecord.apply(rec, B), 'AbsTol', 1e-8);
end

function testPeakLatencyObjective(tc)
EEG = nqc_synth(struct('seconds', 200, 'nPerCond', 40, 'p3Jitter', 0.03));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'t', {'11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.25 0.6], {'Pz','P3','P4'}, 'peakLatency'});
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', {10, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {75, 1000});
r = pipecompare.PipeCompare.optimize(p, c, struct('objective', {{'P3.peakLatency'}}, 'nBootPeakOuter', 100, 'nBootPeak', 300));
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
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1);
p = p.addChoice('o1o2', {'channels', 'labels', {'O1','O2'}, 'action', 'interpolate'}, ...
    {'channels', 'labels', {'O1','O2'}, 'action', 'remove'}, 'none');
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', 100);
r = pipecompare.PipeCompare.optimize(p, c);
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
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
txt = evalc('pipecompare.PipeCompare.optimize(p, nqc_c());');
verifyTrue(tc, contains(txt, 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5'));
verifyFalse(tc, contains(txt, 'pop_eegfiltnew() - performing'));   % EEGLAB's own progress lines
verifyTrue(tc, contains(txt, 'Recommended'));
end

function testTrialRuleRestrictsTheOutputToo(tc)
% Audit: with a trial rule only the eligible trials were scored, but the
% adopted dataset still held every epoch. Adopted data and the exported
% script must hold exactly the scored trials.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}}, ...
    'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
pipecompare.PipeCompare.adopt(r, 1);
ad = evalin('base', 'EEG');
verifyEqual(tc, ad.trials, sum(r.ref.n));
verifyTrue(tc, contains(ad.history, 'notrial'));
d = tempname; mkdir(d); cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
pipecompare.PipeCompare.writeScript(r, 1, fullfile(d, 'nqc_rule_script.m'));
addpath(d); c2 = onCleanup(@() rmpath(d)); %#ok<NASGU>
out = nqc_rule_script(EEG);
verifyEqual(tc, out.trials, sum(r.ref.n));
end

function testEarlierTrialRuleDoesNotPersist(tc)
% Audit: after switching the rule back to 'all', the earlier restriction
% was still applied (it travelled in EEG.etc of the dataset).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
nqc_setBase(EEG); a = pipecompare.PipeCompare.optimize(p, nqc_c());
E2 = EEG; E2.etc.pipecompare.eligibleUrevents = [EEG.event(1:4).urevent];   % left by an earlier search
nqc_setBase(E2); b = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, b.ref.n, a.ref.n);
verifyTrue(tc, any(contains(b.rootComs, 'rmfield(EEG.etc.pipecompare, ''eligibleUrevents'')')));
end

function testVoltConversionScriptScalesIcaLikeTheSearch(tc)
% Audit: the search scaled ICA weights with the data, the script did not.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
V = EEG; V.data = V.data * 1e-6;
rng(3); V.icaweights = randn(V.nbchan); V.icasphere = eye(V.nbchan); V.icachansind = 1:V.nbchan;
V.icawinv = []; V.icaact = []; V = eeg_checkset(V);
nqc_setBase(V);
% no epoch step: pop_epoch renormalises the components and would hide the scale
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1);
r = pipecompare.PipeCompare.optimize(p, nqc_c(), struct('dataUnit', 'V'));
d = tempname; mkdir(d); cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
pipecompare.PipeCompare.writeScript(r, 1, fullfile(d, 'nqc_volt_script.m'));
addpath(d); c2 = onCleanup(@() rmpath(d)); %#ok<NASGU>
out = nqc_volt_script(V);
ref = pipecompare.run.Executor.replay(r, 1);           % the search's own in-memory path
verifyEqual(tc, out.icaweights, ref.icaweights, 'RelTol', 1e-9);
m = pipecompare.eval.Measure.candidate(out, r.contract, r.ref);
verifyEqual(tc, [m.objectives.agg], [r.cands(1).m.objectives.agg], 'RelTol', 1e-6);
end

function testCheckpointFolderBelongsToOneSearch(tc)
% Audit: an existing root.mat was kept while manifest.mat was replaced, so
% a second search in the same folder could resume on another dataset.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('epoch'); p = p.add('baseline');
d = tempname; cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
nqc_setBase(EEG);
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, nqc_c(), struct('checkpoint', d, 'stopAfter', 1)), 'PipeCompare:Interrupted');
other = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'seed', 99));
nqc_setBase(other);
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, nqc_c(), struct('checkpoint', d)), 'PipeCompare:Checkpoint');
c3 = nqc_c(); c3.baseline = [-0.1 0];
nqc_setBase(EEG);
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, c3, struct('checkpoint', d)), 'PipeCompare:Checkpoint');
% the folder still resumes its own search, and the same search may start over
res = pipecompare.PipeCompare.resume(d);
verifyTrue(tc, all(strcmp({res.cands.status}, 'ok')));
again = pipecompare.PipeCompare.optimize(p, nqc_c(), struct('checkpoint', d));
verifyEqual(tc, again.identity, res.identity);
% a starting dataset from another search is refused on resume
d2 = tempname; c4 = onCleanup(@() rmdir(d2, 's')); %#ok<NASGU>
nqc_setBase(other); pipecompare.PipeCompare.optimize(p, nqc_c(), struct('checkpoint', d2));
copyfile(fullfile(d2, 'root.mat'), fullfile(d, 'root.mat'));
verifyError(tc, @() pipecompare.PipeCompare.resume(d), 'PipeCompare:Checkpoint');
end

function testAdoptRefusesInfeasibleAndNonReproducingCandidates(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c(), struct('minTrials', 1000));
n0 = evalin('base', 'numel(ALLEEG)');
verifyError(tc, @() pipecompare.PipeCompare.adopt(r, 1), 'PipeCompare:Adopt');          % rejected: not adopted silently
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0);
pipecompare.PipeCompare.adopt(r, 1, true);                                          % explicit override
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0 + 1);
nqc_setBase(EEG);
r = pipecompare.PipeCompare.optimize(p, nqc_c());
r.cands(1).m.objectives(1).agg = 2 * r.cands(1).m.objectives(1).agg;      % evaluation no longer matches the data
n0 = evalin('base', 'numel(ALLEEG)');
verifyError(tc, @() pipecompare.PipeCompare.adopt(r, 1), 'PipeCompare:ReplayMismatch');
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0);
end

function testRestoreChannelsRemovedBeforePipeCompare(tc)
% Audit: channels removed in EEGLAB before entering could not be restored
% by the plan (restore demanded a removal inside the plan).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
n = EEG.nbchan;
EEG = pop_select(EEG, 'rmchannel', {'O1', 'O2'});
assert(numel(EEG.chaninfo.removedchans) >= 2);
nqc_setBase(EEG);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('restore'); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, r.cands(1).status, 'ok');
verifyEqual(tc, r.cands(1).interpolatedFraction, 2 / n, 'AbsTol', 1e-12);
verifyTrue(tc, any(contains(r.cands(1).coms, 'preRemoved')));
pipecompare.PipeCompare.adopt(r, 1);
ad = evalin('base', 'EEG');
verifyEqual(tc, ad.nbchan, n);
verifyTrue(tc, all(ismember({'O1', 'O2'}, {ad.chanlocs.labels})));
end

function testNativeRejectionWorkflowKeepsDialogSettingsAndDecisions(tc)
% Mark -> reject captured from EEGLAB's dialogs is one step: every dialog
% setting is kept (asymmetric limits here), both commands are in the
% history, and the signal check applies the epochs the real data rejected
% (decision-matched) instead of re-deciding on the injected copy.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
nqc_setBase(EEG);
wf = sprintf(['EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,0);\n', ...
    'EEG = pop_rejepoch(EEG, EEG.reject.rejthresh, 0);']);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
p = p.addNative(wf, 'reject');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
c = r.cands(1);
verifyEqual(tc, c.status, 'ok');
verifyGreaterThan(tc, c.rejectedEpochs, 0);
verifyEmpty(tc, c.unmatched);                                   % decision-matched
verifyLessThan(tc, c.signal.amplitudeError, 0.05);
verifyTrue(tc, any(contains(c.coms, '-60,120')) && any(contains(c.coms, 'pop_rejepoch')));
% the decision equals what the asymmetric limits mark on the processed data
E = pipecompare.run.Executor.replay(r, 1);
verifyEqual(tc, E.trials, 60 - c.rejectedEpochs);
% legality: a rejection workflow on continuous data is refused with a reason
q = pipecompare.plan.Plan(); q = q.addNative(wf, 'reject'); q = q.add('epoch');
verifyError(tc, @() q.enumerate(pipecompare.live.DataState.fromEEG(EEG), nqc_c()), 'PipeCompare:NoLegalPipeline');
end

function testNativeIcaWorkflowRemovesTheFlaggedComponents(tc)
assumeTrue(tc, exist('pop_iclabel', 'file') == 2, 'ICLabel not installed');
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 30));
nqc_setBase(EEG);
wf = sprintf(['EEG = pop_iclabel(EEG, ''default'');\n', ...
    'EEG = pop_icflag(EEG, [NaN NaN;0.5 1;0.5 1;NaN NaN;NaN NaN;NaN NaN;NaN NaN]);\n', ...
    'EEG = pop_subcomp(EEG, [], 0);']);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('ica', 'fitHighpass', 1);
p = p.addNative(wf, 'icclean'); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
c = r.cands(1);
verifyEqual(tc, c.status, 'ok');
verifyGreaterThan(tc, c.icsRemoved, 0);                        % blinks are flagged as Eye
verifyEmpty(tc, c.unmatched);
verifyEqual(tc, sum(contains(c.coms, {'pop_iclabel', 'pop_icflag', 'pop_subcomp'})), 3);
% without any ICA before it, the workflow is not a legal step
q = pipecompare.plan.Plan(); q = q.addNative(wf, 'icclean');
verifyError(tc, @() q.enumerate(pipecompare.live.DataState.fromEEG(EEG), nqc_c()), 'PipeCompare:NoLegalPipeline');
end

function testEeglabConfigurationsAreSearchedAsCandidates(tc)
% Several configurations of one step from EEGLAB dialogs, plus "skip",
% are the searched alternatives of that step; each stays intact.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''filtorder'',3300,''plotfreqz'',0);', 'filter');
p = p.addAlternative('filter', pipecompare.plan.Plan.nativeAlt('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',20,''plotfreqz'',0);'));
p = p.setSkippable('filter', true);
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, numel(r.leaves), 3);
verifyEqual(tc, sum(contains(r.labels, 'filtorder=3300')), 1);     % the full dialog setting is kept (and shown)
verifyEqual(tc, sum(startsWith(r.labels, 'epoch')), 1);            % the skipped variant
verifyTrue(tc, any(strcmp(r.marginal.parameter, 'filter.(alternative)')));
p = p.setSkippable('filter', false);
verifyEqual(tc, numel(p.Slots(1).alternatives), 2);
end

function testEeglabReferencesAreStrataAndCheckedCorrectly(tc)
% Audit: a reference set in EEGLAB's pop_reref dialog was neither
% stratified nor modelled in the signal check (its channels were ignored).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.addEeglab('EEG = pop_reref(EEG, []);', 'ref', 'arg2', {[], {'P7', 'P8'}});
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, numel(unique({r.leaves.stratum})), 2);          % never ranked against each other
verifyEqual(tc, numel(r.ranking.byStratum), 2);
for k = 1:2
    verifyLessThan(tc, r.cands(k).signal.amplitudeError, 0.01);  % a change of reference is not distortion
    verifyGreaterThan(tc, r.cands(k).signal.waveformCorr, 0.999);
end
end

function testExcludedChannelsAcrossSteps(tc)
% Real-data case: bad-channel detection removed A1/A2, then the average
% reference listed them in 'exclude' and every candidate failed. Channels
% an earlier step removed are skipped; unknown labels are still errors.
% badchannels 'exclude' keeps EOG out of the test, and the channel it
% removes is the right one (pop_rejchan indexes the tested channels).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
rng(1); k = find(strcmp({EEG.chanlocs.labels}, 'PO8'));
EEG.data(k, :) = EEG.data(k, :) + 2000 * (rand(1, EEG.pnts) > 0.999);   % one spiky channel
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
p = pipecompare.plan.Plan();
p = p.add('badchannels', 'measure', 'prob', 'threshold', 5, 'action', 'remove', 'exclude', {{'EOG1', 'EOG2'}});
p = p.add('channels', 'labels', {'EOG1'}, 'action', 'remove');
p = p.add('reref', 'mode', 'average', 'exclude', {{'EOG1', 'EOG2'}});
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
verifyEqual(tc, r.cands(1).status, 'ok');
E = pipecompare.run.Executor.replay(r, 1);
verifyFalse(tc, any(strcmp({E.chanlocs.labels}, 'PO8')));            % the spiky channel, not a neighbour
verifyTrue(tc, any(strcmp({E.chanlocs.labels}, 'EOG2')));            % EOG was not tested
verifyTrue(tc, any(contains(r.cands(1).coms, 'pop_reref')));
q = pipecompare.plan.Plan(); q = q.add('reref', 'mode', 'average', 'exclude', {{'EOGX'}}); q = q.add('epoch'); q = q.add('baseline');
r = pipecompare.PipeCompare.optimize(q, c);
verifyEqual(tc, r.cands(1).status, 'failed');
verifyTrue(tc, contains(r.cands(1).message, 'not in the dataset: EOGX'));
end

function testBadChannelsDetectedOnAHighPassedCopy(tc)
% detectHighpass: pop_rejchan runs on a high-passed copy (slow drifts
% distort kurtosis and probability); the channels are interpolated or
% removed in the data as they are, whose other channels stay unfiltered.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
rng(1); k = find(strcmp({EEG.chanlocs.labels}, 'PO8'));
EEG.data(k, :) = EEG.data(k, :) + 2000 * (rand(1, EEG.pnts) > 0.999);   % one spiky channel
pz = @(E) double(E.data(strcmp({E.chanlocs.labels}, 'Pz'), :));
for action = {'interpolate', 'remove'}
    p = struct('measure', 'prob', 'threshold', 5, 'exclude', {{'EOG1', 'EOG2'}}, ...
        'detectHighpass', 1, 'action', action{1});
    [E, coms, info] = pipecompare.run.Steps.badChannels(EEG, p, struct('highpass', 0));
    verifyTrue(tc, ismember('PO8', info.badChannels));
    verifyFalse(tc, any(ismember({'EOG1', 'EOG2'}, info.badChannels)));
    verifyTrue(tc, contains(coms{1}, 'on a 1 Hz high-passed copy'));
    verifyEqual(tc, pz(E), pz(EEG));                                   % not filtered
    verifyEqual(tc, any(strcmp({E.chanlocs.labels}, 'PO8')), strcmp(action{1}, 'interpolate'));
end
[~, coms] = pipecompare.run.Steps.badChannels(EEG, p, struct('highpass', 1));   % already high-passed: no copy
verifyFalse(tc, any(contains(coms, 'copy')));
end

function testFixedEeglabCommandsAreDecisionMatched(tc)
% A fixed EEGLAB transform re-run on the injected copy is the same
% operation (not flagged); a data-driven one (pop_rejchan) is flagged.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.addEeglab('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''plotfreqz'',0);', 'filter');
p = p.addNative('EEG = pop_reref(EEG, []);', 'ref');
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', 150);
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEmpty(tc, r.cands(1).unmatched);
q = pipecompare.plan.Plan();
q = q.addNative('EEG = pop_rejchan(EEG, ''elec'',[1:32],''threshold'',5,''norm'',''on'',''measure'',''kurt'');', 'bad');
q = q.add('epoch'); q = q.add('baseline');
r = pipecompare.PipeCompare.optimize(q, nqc_c());
verifyEqual(tc, r.cands(1).unmatched, {'native'});
end

function testAdoptAndInspectAfterACheckpointedSearch(tc)
% A checkpointed search does not keep the starting dataset in the result;
% adopt / replay / inspect read it back from the checkpoint folder, also
% after changing folder (the path is stored absolute).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('epoch'); p = p.add('baseline');
base = tempname; mkdir(base); c0 = onCleanup(@() rmdir(base, 's')); %#ok<NASGU>
here = pwd; cd(base); c1 = onCleanup(@() cd(here)); %#ok<NASGU>
r = pipecompare.PipeCompare.optimize(p, nqc_c(), struct('checkpoint', 'nqc_run1'));   % relative, as in the README
cd(here);
verifyEmpty(tc, r.root);                                          % not kept in memory
verifyTrue(tc, isfile(fullfile(r.options.checkpoint, 'root.mat')));
n0 = evalin('base', 'numel(ALLEEG)');
pipecompare.PipeCompare.adopt(r);
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0 + 1);
E = pipecompare.run.Executor.rootOf(r);
verifyEqual(tc, double(E.data), double(EEG.data), 'AbsTol', 1e-4);
r2 = r; r2.identity = 'another search';
verifyError(tc, @() pipecompare.run.Executor.rootOf(r2), 'PipeCompare:Checkpoint');
end

function testRemovedEpochsAreReadNotGuessed(tc)
% pop_rejepoch's epochs are read from its argument before it runs, so an
% epoch that has no events is not mistaken for a removed one; a removal
% that cannot be told apart is re-run (flagged) instead of guessed.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
[~, E] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.2 0.8])');
E.event([E.event.epoch] == 5) = []; E = eeg_checkset(E, 'eventconsistency');   % epoch 5 has no event
[E2, ~, info] = pipecompare.run.Steps.native(E, 'EEG = pop_rejepoch(EEG, [2 3], 0);');
verifyEqual(tc, info.decisions.idx, [2 3]);
verifyEqual(tc, E2.trials, E.trials - 2);
[E3, ~, info] = pipecompare.run.Steps.native(E, 'EEG = pop_eegthresh(EEG,1,[1:32],-150,150,-0.2,0.796,0,1);');
verifyLessThan(tc, E3.trials, E.trials);                          % it did remove epochs
verifyEmpty(tc, info.decisions);                                  % not decision-matched: re-run on the copy
end

function testStrataDoNotDependOnStepOrder(tc)
% The same measure-defining choices in another order are one stratum.
p = pipecompare.plan.Plan();
p = p.add('reref', 'mode', 'average');
p = p.addEeglab('EEG = pop_reref(EEG, {''P7'',''P8''});', 'ref2');
p.OrderMode = 'search';
leaves = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(leaves), 2);
verifyEqual(tc, numel(unique({leaves.stratum})), 1);
q = pipecompare.plan.Plan(); q = q.add('reref', 'mode', 'channels');          % no reference channels
try
    q.enumerate(nqc_fakeState(false, 500), nqc_contract());
    verifyFail(tc, 'reref channels without channels must be refused at plan time');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'needs the reference channels'));
end
end

function testSeveralStrataAskTheUserToChoose(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
nqc_setBase(EEG);
p = pipecompare.plan.Plan();
p = p.addChoice('ref', {'reref', 'mode', 'average'}, {'reref', 'mode', 'channels', 'channels', {'P7', 'P8'}});
p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_c());
verifyEqual(tc, numel(r.ranking.byStratum), 2);
verifyEmpty(tc, r.ranking.recommended);
try
    pipecompare.PipeCompare.adopt(r);
    verifyFail(tc, 'adopt without a choice must explain the strata');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:Adopt');
    verifyTrue(tc, contains(ME.message, 'strata'));
end
pipecompare.PipeCompare.adopt(r, r.ranking.byStratum(1).recommended);   % a chosen stratum's recommendation
end

function testRoiOnAChannelRestoredByThePlan(tc)
% Pz was removed before PipeCompare; the plan restores it and measures there.
% The ROI check must not refuse this, the restored Pz carries the known
% signal, and a pipeline without the restore fails with that reason.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
E = pop_select(EEG, 'rmchannel', {'Pz'});
nqc_setBase(E);
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz'}});
p = pipecompare.plan.Plan(); p = p.addChoice('rest', {'restore'}, 'none'); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
k = find(contains(r.labels, 'restore'));
verifyEqual(tc, r.cands(k).status, 'ok');
% the restored Pz is checked against the true field there: interpolating
% the peak channel of a focal component loses ~28% of it, and that is what
% the check reports (test_signal/testInterpolatingAnRoiChannelIsMeasured)
verifyGreaterThan(tc, r.cands(k).signal.amplitudeError, 0.15);
verifyLessThan(tc, r.cands(k).signal.amplitudeError, 0.45);
verifyGreaterThan(tc, r.cands(k).signal.waveformCorr, 0.95);
j = setdiff(1:2, k);
verifyEqual(tc, r.cands(j).status, 'failed');
verifyTrue(tc, contains(r.cands(j).message, 'ROI channel(s) missing'));
c2 = pipecompare.eval.Contract('conditions', {'t', {'11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'X', [0.3 0.5], {'NoSuchChannel'}});
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, c2), 'PipeCompare:Contract');   % unknown channels still refused
end

% ---------------------------------------------------------------- helpers
function c = nqc_c()
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
end

% ------------------------------------------------------------ band power
function testBandPowerOfContinuousDataEndToEnd(tc)
% Continuous alpha power: a 9 Hz low-pass destroys the band and is
% rejected by the signal check; 30 Hz keeps it. Segments are marked with
% eeg_regepochs and paired across candidates by urevent.
EEG = nqc_synth(struct('seconds', 150, 'nPerCond', 10, 'alphaUv', 10, 'artifactTrials', 0));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, 'bands', {'alpha', [8 12], {'Oz', 'O1', 'O2'}});
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 1); p = p.add('lowpass', 'cutoff', {9, 30});
p = p.add('epoch');
r = pipecompare.PipeCompare.optimize(p, c);
lp9 = contains(r.labels, 'cutoff=9'); lp30 = contains(r.labels, 'cutoff=30');
verifyEqual(tc, r.ranking.table.status{lp9}, 'rejected');
verifyTrue(tc, contains(r.ranking.table.reason{lp9}, 'amplitude'));
verifyEqual(tc, r.ranking.table.status{lp30}, 'feasible');
verifyGreaterThanOrEqual(tc, r.ref.n, 70);                        % 150 s / 2 s, minus edges
verifyEqual(tc, r.ref.units{1}, 'log10(uV^2)');
verifyTrue(tc, r.ref.segmented);
verifyTrue(tc, any(contains(r.rootComs, 'eeg_regepochs')));       % pure EEGLAB, in the script
end

function testBandPowerContractIsValidated(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
st = pipecompare.live.DataState.fromEEG(EEG);
short = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 0.1, 'bands', {'theta', [4 8], {'Fz'}});
verifyError(tc, @() short.validate(st), 'PipeCompare:Contract');      % fewer than two 4 Hz cycles
high = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, 'bands', {'gamma', [100 140], {'Fz'}});
verifyError(tc, @() high.validate(st), 'PipeCompare:Contract');       % above Nyquist (125 Hz)
ok = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, 'bands', {'theta', [4 8], {'Fz'}});
ok.validate(st);
[~, Ep] = evalc('pop_epoch(EEG, {''11''}, [-0.2 0.8])');
verifyError(tc, @() ok.validate(pipecompare.live.DataState.fromEEG(Ep)), 'PipeCompare:Contract');   % segments need continuous data
end

function testEventRelatedBandPower(tc)
% With conditions and epoch instead of segments, each epoch's band power
% is scored; trials are independent (no block resampling).
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'alphaUv', 10));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('analysis', 'bandpower', 'conditions', {'t', {'11'}; 's', {'31'}}, ...
    'epoch', [-0.5 1.5], 'bands', {'alpha', [8 12], {'Oz', 'O1', 'O2'}});
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {0.5, 1}); p = p.add('epoch');
r = pipecompare.PipeCompare.optimize(p, c);
verifyFalse(tc, r.ref.segmented);
verifyEqual(tc, r.ref.n, [30 30]);
verifyTrue(tc, all(strcmp(r.ranking.table.status, 'feasible')));
end
