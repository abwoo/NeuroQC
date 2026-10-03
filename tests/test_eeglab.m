function tests = test_eeglab
%TEST_EEGLAB Integration with the live EEGLAB session: dataset detection,
%   EEGLAB's own command path, adoption into ALLEEG, the panel, and
%   (optionally) a real dataset given by NEUROQC_REAL_SET (never committed;
%   only working copies are processed).
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
assert(exist('pop_epoch', 'file') == 2, 'EEGLAB must be on the path');
tc.TestData.realSet = getenv('NEUROQC_REAL_SET');
end

% ------------------------------------------------------------ live session
function testLiveDetectionAndUnstoredWarning(tc)
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
[cur, info] = neuroqc.live.Session.current();
verifyEqual(tc, cur.setname, 'nqc_synth'); verifyTrue(tc, info.stored);
evalin('base', 'EEG.setname = ''changed on the command line'';');
[cur, info] = neuroqc.live.Session.current();
verifyEqual(tc, cur.setname, 'changed on the command line'); verifyFalse(tc, info.stored);
end

function testDatasetSwitchAndRemovalAreFollowed(tc)
A = nqc_synth(struct('seconds', 60, 'nPerCond', 10)); A.setname = 'A';
B = nqc_synth(struct('seconds', 60, 'nPerCond', 10, 'seed', 3)); B.setname = 'B';
nqc_setBase(A);
assignin('base', 'NQC_TMP', B);
evalin('base', '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, NQC_TMP, 0); clear NQC_TMP');
cur = neuroqc.live.Session.current(); verifyEqual(tc, cur.setname, 'B');
evalin('base', '[ALLEEG, EEG, CURRENTSET] = pop_newset(ALLEEG, EEG, CURRENTSET, ''retrieve'', 1, ''gui'', ''off'');');
cur = neuroqc.live.Session.current(); verifyEqual(tc, cur.setname, 'A');
evalin('base', 'ALLEEG = pop_delset(ALLEEG, [1 2]); EEG = eeg_emptyset(); CURRENTSET = 0;');
verifyEmpty(tc, neuroqc.live.Session.current());
end

% ------------------------------------------------------ EEGLAB code paths
function testApplyThroughEeglabCodePathRecordsHistory(tc)
% "Apply now" wraps the call in EEGLAB's own try/catch + eeglab_new, so
% EEGLAB records it (EEG.history and ALLCOM). DEBUG_EEGLAB_MENUS keeps
% eeglab_new from opening its interactive "new dataset" dialog in a test.
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS')); %#ok<NASGU>
neuroqc.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyTrue(tc, contains(cur.history, 'pop_reref( EEG, [])'));
s = neuroqc.live.DataState.fromEEG(cur);
verifyEqual(tc, s.process(end).step, 'reref');
global ALLCOM %#ok<GVMIS>
verifyTrue(tc, any(contains(ALLCOM, 'pop_reref')));
end

function testRepeatedCommandStaysInDatasetHistory(tc)
% EEGLAB's eegh skips a command equal to the previous session command; the
% dataset history must still list it (applied twice -> listed twice).
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS')); %#ok<NASGU>
EEG = evalin('base', 'EEG'); [~, com] = pop_reref(EEG, []);
eegh(com);                                   % the previous session command is the same call
neuroqc.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyEqual(tc, numel(strfind(cur.history, 'pop_reref')), 1);
neuroqc.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyEqual(tc, numel(strfind(cur.history, 'pop_reref')), 2);
end

function testFingerprintSeesEventEdits(tc)
% Audit: changing one event's type (same count, no history entry) gave the
% same fingerprint, so stale-result protection missed it.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
f0 = neuroqc.live.Session.fingerprint(EEG);
E = EEG; E.event(5).type = '99';
verifyNotEqual(tc, neuroqc.live.Session.fingerprint(E), f0);
E = EEG; E.event(5).latency = E.event(5).latency + 1;
verifyNotEqual(tc, neuroqc.live.Session.fingerprint(E), f0);
E = EEG; E.chanlocs(3).labels = 'X3';
verifyNotEqual(tc, neuroqc.live.Session.fingerprint(E), f0);
verifyEqual(tc, neuroqc.live.Session.fingerprint(EEG), f0);
end

function testCapturedNativeStepCanBeAppliedAndReedited(tc)
% Audit: after "Fix via EEGLAB dialog" the step is native and "Apply now"
% failed with "No EEGLAB dialog for native".
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS')); %#ok<NASGU>
com = 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''plotfreqz'',0);';
neuroqc.run.Native.applyCommand(com);
cur = evalin('base', 'EEG');
verifyTrue(tc, contains(cur.history, 'pop_eegfiltnew(EEG, ''locutoff'',0.5'));
verifyEqual(tc, evalin('base', 'ALLEEG(CURRENTSET).history'), cur.history);   % stored, not only in base EEG
verifyEqual(tc, neuroqc.run.Native.typeOfCommand(com), 'filter');           % re-edit opens the filter dialog
verifyEqual(tc, neuroqc.run.Native.typeOfCommand('EEG = pop_reref(EEG, []);'), 'reref');
end

function testPanelClearsResultsWhenThePlanChanges(tc)
% Audit: after removing a plan step the old results stayed visible and
% could be adopted as if they belonged to the new plan.
nqc_setBase(nqc_synth(struct('seconds', 90, 'nPerCond', 20)));
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.TypeDrop.Value = 'highpass'; app.addStep();
app.planEdited(struct('Indices', [1 3], 'NewData', 'cutoff = 0.1'));
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'baseline'; app.addStep();
app.CondField.Value = 'target: 11; standard: 31';
app.CompField.Value = 'P3: 0.3 0.5 @ Pz P3 P4';
app.run(false);
verifyNotEmpty(tc, app.Result);
app.PlanTable.Selection = [1 1];
app.removeStep();
verifyEmpty(tc, app.Result);
verifyEmpty(tc, app.ResultTable.Data);
verifyTrue(tc, contains(app.StatusLabel.Text, 'cleared'));
app.TypeDrop.Value = 'reject_threshold'; app.addStep(); app.run(false);
verifyNotEmpty(tc, app.Result);
app.invalidate('Settings changed');      % what every contract/limit field calls on edit
verifyEmpty(tc, app.Result);
end

function testNativeCommandArgumentsAreRead(tc)
% Settings come back from EEGLAB dialogs as commands; their arguments are
% evaluated, not pattern-matched.
a = neuroqc.run.Native.argsOf('EEG = pop_epoch( EEG, {  ''11''  ''S  1''  }, [-0.2           1], ''newname'', ''x'', ''epochinfo'', ''yes'');', 'pop_epoch');
verifyEqual(tc, a{1}, {'11', 'S  1'});
verifyEqual(tc, a{2}, [-0.2 1]);
verifyEqual(tc, a(3:6), {'newname', 'x', 'epochinfo', 'yes'});
a = neuroqc.run.Native.argsOf('EEG = pop_rmbase( EEG, [-200 0] ,[]);', 'pop_rmbase');
verifyEqual(tc, a, {[-200 0], []});
a = neuroqc.run.Native.argsOf('[EEG, ~, LASTCOM] = pop_epoch(EEG);', 'pop_epoch');
verifyEmpty(tc, a);
verifyError(tc, @() neuroqc.run.Native.argsOf('EEG = pop_reref(EEG, []);', 'pop_epoch'), 'NeuroQC:Native');
end

function testPanelContractFromEeglabDialogs(tc)
% Conditions picked from the events, epoch and baseline from EEGLAB's own
% dialogs (their commands), ROI from the channel list, trials from an
% EEGLAB event selection: nothing is retyped, and the search uses exactly
% what the panel shows.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.addCondition('target', {'11'});
app.addCondition('standard', {'31'});
verifyEqual(tc, app.CondField.Value, 'target: 11; standard: 31');
[~, ~, com] = pop_epoch(EEG, {'11', '31'}, [-0.3 0.9], 'epochinfo', 'yes');   % what the dialog returns
app.epochFromEEGLAB(com);
verifyEqual(tc, str2num(app.EpochField.Value), [-0.3 0.9]); %#ok<ST2NM>
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.3 0.9])');
[~, com] = pop_rmbase(Ep, [-300 0]);
app.baselineFromEEGLAB(com);
verifyEqual(tc, str2num(app.BaseField.Value), [-0.3 0]); %#ok<ST2NM>   ms -> s
app.addComponent('P3', [0.3 0.5], {'Pz', 'P3'}, 'mean', 'positive');
app.setRoi(1, {'Pz', 'P3', 'P4'});
verifyEqual(tc, app.CompField.Value, 'P3: 0.3 0.5 @ Pz P3 P4');
verifyTrue(tc, contains(app.SummaryLabel.Text, 'target 30'));
% trials: the condition events an EEGLAB event selection keeps
[~, E] = evalc('eeg_checkset(EEG, ''makeur'')');
late = find(([E.event.latency] - 1) / E.srate >= 30);
[sel, ~, com] = pop_selectevent(E, 'event', late, 'deleteevents', 'on');
app.trialRuleFromSelection(sel, com);
verifyEqual(tc, app.TrialRule.mode, 'urevents');
verifyTrue(tc, contains(app.SummaryLabel.Text, ' of 30'));
c = app.contract();
verifyEqual(tc, c.epoch, [-0.3 0.9]); verifyEqual(tc, c.baseline, [-0.3 0]);
verifyEqual(tc, c.components(1).roi, {'Pz', 'P3', 'P4'});
app.TypeDrop.Value = 'highpass'; app.addStep();
app.planEdited(struct('Indices', [1 3], 'NewData', 'cutoff = 0.1'));
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'baseline'; app.addStep();
app.run(false);
verifyEqual(tc, app.Result.ref.n(1), sum(strcmp({sel.event.type}, '11')));
verifyEqual(tc, app.Result.contract.trials.mode, 'urevents');
app.setTrialRule(struct('mode', 'all'));            % a rule change clears the results
verifyEmpty(tc, app.Result);
% codes with spaces survive the text round trip
app.setField(app.CondField, '');
app.addCondition('s1', {'S  1'});
verifyEqual(tc, app.CondField.Value, 's1: "S  1"');
c = app.contract(); verifyEqual(tc, c.conditions(1).events, {'S  1'});
end

function testPanelCandidateConfigsSkipAndOrderRules(tc)
% Plan editing that used to need the command line: candidate
% configurations from EEGLAB dialogs, "skip" as an option, order rules.
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.TypeDrop.Value = 'lowpass'; app.addStep();
app.TypeDrop.Value = 'highpass'; app.addStep();
app.PlanTable.Selection = [1 1];
app.captureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',30,''plotfreqz'',0);');   % what the dialog returns
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.type, 'native');
app.addCandidateConfig('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''filtorder'',200,''plotfreqz'',0);');
app.addCandidateConfig('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''filtorder'',200,''plotfreqz'',0);');   % duplicate ignored
verifyEqual(tc, numel(app.Plan.Slots(1).alternatives), 2);
app.toggleSkip();
verifyEqual(tc, numel(app.Plan.Slots(1).alternatives), 3);
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'none (skip)'));
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'EEGLAB: EEG = pop_eegfiltnew'));
app.PlanTable.Selection = [2 1];
app.mustBefore('lowpass_native');
verifyEqual(tc, app.Plan.Precedence, {'highpass', 'lowpass_native'});
verifyTrue(tc, contains(app.ConstraintLabel.Text, 'highpass before lowpass_native'));
verifyEqual(tc, neuroqc.run.Native.typeOfCommand(sprintf('EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,0);\nEEG = pop_rejepoch(EEG, EEG.reject.rejthresh, 0);')), 'reject_threshold');
app.clearOrderRules();
verifyEmpty(tc, app.Plan.Precedence);
end

function testCaptureReturnsCommandWithoutTouchingData(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
com = neuroqc.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_eegfiltnew(EEG, ''locutoff'', 0.5);');
verifyTrue(tc, startsWith(com, 'EEG = pop_eegfiltnew('));
p = neuroqc.plan.Plan(); p = p.addNative(com);     % becomes a fixed step
verifyEqual(tc, p.Slots(1).alternatives{1}.type, 'native');
end

function testScoresIgnoreChannelOffsets(tc)
% 0.6 split-half metrics were driven by per-channel DC offsets
% (v06_reproductions R2). Scores here are baseline-corrected per trial.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4','POz'}});
ref = neuroqc.eval.Measure.reference(EEG, c);
off = EEG; off.data = off.data + single((1:off.nbchan)' * 50);
a = neuroqc.eval.Measure.candidate(EEG, c, ref); b = neuroqc.eval.Measure.candidate(off, c, ref);
verifyEqual(tc, b.objectives(1).agg, a.objectives(1).agg, 'AbsTol', 1e-3);
end

% ------------------------------------------------------------------ adopt
function testAdoptRefusesStaleStartingDataset(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, nqc_contract());
% the starting dataset is changed in place and the old copy is gone
evalin('base', ['[EEG, LASTCOM] = pop_reref(EEG, []); EEG = eegh(LASTCOM, EEG); ', ...
    '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, EEG, CURRENTSET);']);
n0 = evalin('base', 'numel(ALLEEG)');
verifyError(tc, @() neuroqc.NeuroQC.adopt(r, 1), 'NeuroQC:StaleState');
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0);           % nothing stored
neuroqc.NeuroQC.adopt(r, 1, true);                               % explicit override
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0 + 1);
ad = evalin('base', 'EEG');
verifyTrue(tc, contains(ad.history, 'pop_eegfiltnew'));
verifyFalse(tc, contains(ad.history, 'pop_reref'));              % built from the stored start
end

function testWriteScriptReproducesCandidate(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
c = nqc_contract();
r = neuroqc.NeuroQC.optimize(p, c);
d = tempname; mkdir(d); cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
f = fullfile(d, 'nqc_pipeline_test.m');
neuroqc.NeuroQC.writeScript(r, 1, f);
addpath(d); c2 = onCleanup(@() rmpath(d)); %#ok<NASGU>
out = nqc_pipeline_test(EEG);
m = neuroqc.eval.Measure.candidate(out, c, r.ref);
verifyEqual(tc, [m.objectives.agg], [r.cands(1).m.objectives.agg], 'RelTol', 1e-9);
end

% -------------------------------------------------------------------- GUI
function testPanelFollowsLiveDatasetAndRuns(tc)
nqc_setBase(nqc_synth(struct('seconds', 120, 'nPerCond', 30)));
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
verifyEqual(tc, size(app.HistTable.Data, 1), 1);
% an EEGLAB operation on the live dataset (as a menu would do) appears in the panel
evalin('base', ['[EEG, LASTCOM] = pop_reref(EEG, []); EEG = eegh(LASTCOM, EEG); ', ...
    '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, EEG, CURRENTSET);']);
app.refreshLive(false);
verifyEqual(tc, size(app.HistTable.Data, 1), 2);
verifyEqual(tc, app.HistTable.Data{2, 3}, 'reref');
% build a plan through the panel and run it
app.TypeDrop.Value = 'highpass'; app.addStep();
app.planEdited(struct('Indices', [1 3], 'NewData', 'cutoff = {0.1, 0.5}'));
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'baseline'; app.addStep();
app.CondField.Value = 'target: 11; standard: 31';
app.CompField.Value = 'P3: 0.3 0.5 @ Pz P3 P4';
app.ObjectiveField.Value = 'composite';
app.run(false);
verifyEqual(tc, size(app.ResultTable.Data, 1), 2);
verifyEqual(tc, size(app.ResultTable.Data, 2), 11);
verifyTrue(tc, evalin('base', 'exist(''neuroqc_result'', ''var'')') == 1);
% a latency objective through the panel syntax
app.CompField.Value = 'P3: 0.3 0.5 @ Pz # peakLatency positive';
app.ObjectiveField.Value = 'P3.peakLatency';
app.run(false);
r = evalin('base', 'neuroqc_result');
verifyEqual(tc, r.ranking.units, {'ms'});
end

% ------------------------------------------------------------- real data
function testRealDatasetStateOnWorkingCopy(tc)
% Reads the real dataset's history and state; the file on disk must not change.
f = tc.TestData.realSet;
assumeTrue(tc, ~isempty(f) && isfile(f), 'NEUROQC_REAL_SET not set');
before = dir(f);
[p, n, e] = fileparts(f);
EEG = pop_loadset('filename', [n e], 'filepath', p);
nqc_setBase(EEG);
txt = evalc('s = neuroqc.NeuroQC.state();');
verifyNotEmpty(tc, s.history);
verifyNotEmpty(tc, s.provenance);
verifyTrue(tc, contains(txt, 'recorded in EEG.history'));
after = dir(f);
verifyEqual(tc, [after.datenum after.bytes], [before.datenum before.bytes]);
end
