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
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.TypeDrop.Value = 'highpass'; app.addStep();
app.PlanTable.Selection = [1 1]; app.setValues('cutoff', {0.1});
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
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
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
app.PlanTable.Selection = [1 1]; app.setValues('cutoff', {0.1});
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
% One way to configure a step: its EEGLAB dialog. Each configuration
% adds the values that differ; settings the step cannot hold are kept as
% the whole EEGLAB command when chosen; "skip" and order rules.
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.TypeDrop.Value = 'lowpass'; app.addStep();
app.TypeDrop.Value = 'highpass'; app.addStep();
app.PlanTable.Selection = [1 1];
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',30,''plotfreqz'',1);');   % what the dialog returns
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.params.cutoff, 30);
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''plotfreqz'',1);');
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''plotfreqz'',1);');   % already there
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.params.cutoff, {30, 40});
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.type, 'lowpass');                 % still one step, two values
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'cutoff = {30, 40}'));
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''filtorder'',200,''plotfreqz'',0);', [], false);
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.params.cutoff, {30, 40});         % only the step's values used
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''filtorder'',200,''plotfreqz'',0);', [], true);
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.type, 'eeglab');                  % whole command kept
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'filtorder = 200'));
app.toggleSkip();
verifyEqual(tc, numel(app.Plan.Slots(1).alternatives), 2);
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'none (skip)'));
app.PlanTable.Selection = [2 1];
app.mustBefore('lowpass');
verifyEqual(tc, app.Plan.Precedence, {'highpass', 'lowpass'});
verifyTrue(tc, contains(app.ConstraintLabel.Text, 'highpass before lowpass'));
verifyEqual(tc, neuroqc.run.Native.typeOfCommand(sprintf('EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,0);\nEEG = pop_rejepoch(EEG, EEG.reject.rejthresh, 0);')), 'reject_threshold');
app.clearOrderRules();
verifyEmpty(tc, app.Plan.Precedence);
% the values editor: numbers and channel lists, nothing evaluated as code
app.PlanTable.Selection = [2 1];
app.setValues('cutoff', {0.1, 0.5});
verifyEqual(tc, app.Plan.Slots(2).alternatives{1}.params.cutoff, {0.1, 0.5});
app.setValues('cutoff', {});
verifyFalse(tc, isfield(app.Plan.Slots(2).alternatives{1}.params, 'cutoff'));       % back to the default search
end

function testDialogArgumentsAreSearchedOneByOne(tc)
% A step kept as its whole EEGLAB command: configuring it again in the
% dialog turns the arguments that differ into searched lists (combined),
% the others stay as set; each argument is in the per-parameter summary.
nqc_setBase(nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0)));
app = neuroqc.gui.Panel();
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
app.addComponent('P3', [0.3 0.5], {'Pz', 'P3', 'P4'}, 'mean', 'positive');
app.TypeDrop.Value = 'lowpass'; app.addStep();
app.TypeDrop.Value = 'epoch'; app.addStep(); app.TypeDrop.Value = 'baseline'; app.addStep();
app.PlanTable.Selection = [1 1];
app.configureStep('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''plotfreqz'',1);', [], true);   % a band-pass: keep it whole
app.configureStep('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',40,''plotfreqz'',1);');
app.configureStep('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.3,''hicutoff'',40,''plotfreqz'',1);');
alt = app.Plan.Slots(1).alternatives;
verifyEqual(tc, numel(alt), 1);                                    % one step, searched arguments
A = alt{1}.params.args;
verifyEqual(tc, A(strcmp({A.name}, 'hicutoff')).values, {30, 40});
verifyEqual(tc, A(strcmp({A.name}, 'locutoff')).values, {0.1, 0.3});
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, '[4 combinations]'));
app.setValues('hicutoff', {30, 40, 45});                           % the values editor's effect
app.run(false);
r = app.Result;
verifyEqual(tc, numel(r.leaves), 6);
verifyTrue(tc, all(contains(r.labels, 'pop_eegfiltnew(locutoff=')));
verifyTrue(tc, all(arrayfun(@(c) strcmp(c.signal.source, 'injection'), r.cands)));
m = r.marginal;
verifyEqual(tc, sort(unique(m.parameter))', {'lowpass.hicutoff', 'lowpass.locutoff'});
verifyEqual(tc, sum(strcmp(m.parameter, 'lowpass.hicutoff')), 3);
first = cellfun(@(c) c{1}, {r.cands.coms}, 'UniformOutput', false);
verifyTrue(tc, all(contains(first, '''plotfreqz'',0')));           % no filter plot window during the search
end

function testCatalogValuesFromEeglabDialogCommands(tc)
% Every catalog step with an EEGLAB dialog takes its values from what the
% dialog returns; settings the step cannot express are reported.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
[~, Ep] = evalc('pop_epoch(EEG, {''11'',''31''}, [-0.2 1])');
L = {EEG.chanlocs.labels};
V = @(t, com, E) neuroqc.run.Native.catalogValues(t, com, E);
[~, com] = pop_eegfiltnew(EEG, 'locutoff', 0.5, 'plotfreqz', 0);
verifyEqual(tc, V('highpass', com, EEG), struct('cutoff', 0.5));
[~, com] = pop_eegfiltnew(EEG, 'hicutoff', 30, 'plotfreqz', 0);
verifyEqual(tc, V('lowpass', com, EEG), struct('cutoff', 30));
[~, com] = pop_eegfiltnew(EEG, 'locutoff', 48, 'hicutoff', 52, 'revfilt', 1, 'plotfreqz', 0);
verifyEqual(tc, V('linenoise', com, EEG), struct('freq', 50, 'halfwidth', 2));
[v, notes] = V('lowpass', 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''filtorder'',800);', EEG);
verifyEqual(tc, v.cutoff, 30); verifyNumElements(tc, notes, 2);    % band edge and filtorder reported
[~, com] = pop_resample(EEG, 125);
verifyEqual(tc, V('resample', com, EEG), struct('fs', 125));
[~, com] = pop_reref(EEG, [5 6], 'exclude', 1);
verifyEqual(tc, V('reref', com, EEG), struct('mode', 'channels', 'channels', {L(5:6)}, 'exclude', {L(1)}));
[~, com] = pop_reref(EEG, []);
verifyEqual(tc, V('reref', com, EEG), struct('mode', 'average'));
[~, com] = pop_select(EEG, 'rmchannel', {'O1', 'O2'});
verifyEqual(tc, V('channels', com, EEG), struct('labels', {{'O1', 'O2'}}, 'action', 'remove'));
[~, ~, com] = pop_eegthresh(Ep, 1, 1:30, -80, 80, -0.2, 0.996, 0, 0);
verifyEqual(tc, V('reject_threshold', com, Ep), struct('exclude', {L(31:32)}, 'uv', 80));
[v, notes] = V('reject_threshold', 'EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,0);', Ep);
verifyEqual(tc, v.uv, 120); verifyTrue(tc, contains(notes{1}, 'asymmetric'));
[~, ~, ~, ~, com] = pop_jointprob(Ep, 1, 1:32, 4, 4, 0, 0, 0);
verifyEqual(tc, V('reject_jointprob', com, Ep), struct('sd', 4));
Eb = EEG; rng(1); Eb.data(30, :) = Eb.data(30, :) + 2000 * (rand(1, Eb.pnts) > 0.999);   % EEGLAB returns a command only when it flags a channel
[~, ~, ~, com] = pop_rejchan(Eb, 'elec', 1:32, 'threshold', 4, 'norm', 'on', 'measure', 'prob');
verifyEqual(tc, V('badchannels', com, EEG), struct('measure', 'prob', 'threshold', 4));
verifyEqual(tc, V('icremove', 'EEG = pop_icflag(EEG, [NaN NaN;0.8 1;0.8 1;NaN NaN;NaN NaN;NaN NaN;NaN NaN]);', EEG), ...
    struct('classes', {{'Muscle', 'Eye'}}, 'threshold', 0.8));
v = V('asr', 'EEG = pop_clean_rawdata(EEG, ''FlatlineCriterion'',''off'',''ChannelCriterion'',''off'',''LineNoiseCriterion'',''off'',''Highpass'',''off'',''BurstCriterion'',15,''WindowCriterion'',''off'',''BurstRejection'',''off'',''Distance'',''Euclidian'');', EEG);
verifyEqual(tc, v.cutoff, 15);
% in the panel: each dialog adds its value to the catalog step's search
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
app.TypeDrop.Value = 'lowpass'; app.addStep(); app.PlanTable.Selection = [1 1];
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',30,''plotfreqz'',1);', EEG);
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.params.cutoff, 30);
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''plotfreqz'',1);', EEG);
app.configureStep('EEG = pop_eegfiltnew(EEG, ''hicutoff'',40,''plotfreqz'',1);', EEG);   % already there
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.params.cutoff, {30, 40});
verifyEqual(tc, app.Plan.Slots(1).alternatives{1}.type, 'lowpass');   % still the catalog step
app.TypeDrop.Value = 'reref'; app.addStep(); app.PlanTable.Selection = [2 1];
[~, com] = pop_reref(EEG, {'P7', 'P8'});
app.configureStep(com, EEG);
verifyEqual(tc, app.Plan.Slots(2).alternatives{1}.params.channels, {'P7', 'P8'});
end

function testPanelOptionsResumeAndInspect(tc)
% Options that used to need the command line (checkpoint,
% resume), the objective list, and EEGLAB viewers on a candidate.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
app.addComponent('P3', [0.3 0.5], {'Pz', 'P3', 'P4'}, 'mean', 'positive');
verifyEqual(tc, app.ObjectiveField.Items, {'composite', 'P3.mean'});
app.TypeDrop.Value = 'highpass'; app.addStep();
app.PlanTable.Selection = [1 1]; app.setValues('cutoff', {0.1, 0.3, 0.5});
app.TypeDrop.Value = 'epoch'; app.addStep(); app.TypeDrop.Value = 'baseline'; app.addStep();
% checkpoint + resume from the panel
o = app.Options;
d = tempname; c2 = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
o.checkpoint = d; app.setOptions(o);
verifyError(tc, @() neuroqc.NeuroQC.optimize(app.Plan, app.contract(), struct('checkpoint', d, 'stopAfter', 1)), 'NeuroQC:Interrupted');
app.resume(d);
verifyEqual(tc, numel(app.Result.cands), 3);
verifyTrue(tc, all(strcmp({app.Result.cands.status}, 'ok')));
% a candidate in EEGLAB's data viewer, labelled as not adopted
n0 = numel(findall(groot, 'Type', 'figure'));
app.inspect(2, 1);
new = findall(groot, 'Type', 'figure');
verifyEqual(tc, numel(new), n0 + 1);
verifyTrue(tc, any(contains(get(new, 'Name'), 'candidate 2 (not adopted)')));
delete(new(contains(get(new, 'Name'), 'candidate 2')));
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), 1);              % inspecting stores nothing
end

function testTrialTimeRangesFromEeglabSelection(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
[~, com] = pop_select(EEG, 'time', [30 120]);          % what EEGLAB's data selection returns
app.trialRuleFromTimeSelection(com, 120);
verifyEqual(tc, app.TrialRule.ranges, [30 120]);
[~, com] = pop_select(EEG, 'notime', [0 30; 100 110]);  % removed ranges -> kept complement
app.trialRuleFromTimeSelection(com, 120);
verifyEqual(tc, app.TrialRule.ranges, [30 100; 110 120]);
verifyTrue(tc, contains(app.TrialLabel.Text, 'pop_select'));
lat = ([EEG.event.latency] - 1) / EEG.srate;
n = sum(strcmp({EEG.event.type}, '11') & ((lat >= 30 & lat < 100) | (lat >= 110 & lat < 120)));
verifyTrue(tc, contains(app.SummaryLabel.Text, sprintf('target %d of 30', n)));
end

function testEveryPartShowsItsFullContent(tc)
% Effective values (also the defaults that will be searched), the full
% text of any selected row, and a usable layout at a small window size.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
app.addComponent('P3', [0.3 0.5], {'Pz', 'P3', 'P4'}, 'mean', 'positive');
app.TypeDrop.Value = 'highpass'; app.addStep();
app.TypeDrop.Value = 'epoch'; app.addStep(); app.TypeDrop.Value = 'baseline'; app.addStep();
verifyTrue(tc, contains(app.PlanTable.Data{1, 3}, 'cutoff = {0.1, 0.3, 0.5, 1} (default search)'));
verifyTrue(tc, contains(app.PlanTable.Data{2, 3}, '[-0.2 1] s'));
verifyTrue(tc, contains(app.PlanTable.Data{3, 3}, 'from the analysis contract'));
app.PlanTable.Selection = [1 1]; app.showDetails('plan', app.PlanTable);
verifyTrue(tc, any(contains(app.DetailArea.Value, 'Values: cutoff = {0.1, 0.3, 0.5, 1} (default search)')));
app.run(false);
T = app.ResultTable.Data;
verifyTrue(tc, all(endsWith(T(:, 7), '%')));                                       % retention as percent text
app.ResultTable.Selection = [1 1]; app.showDetails('result', app.ResultTable);
k = str2double(strrep(T{1, 1}, '*', ''));
verifyTrue(tc, any(contains(app.DetailArea.Value, app.Result.labels{k})));         % full pipeline
verifyTrue(tc, any(contains(app.DetailArea.Value, 'pop_eegfiltnew')));             % full commands
app.HistTable.Selection = [1 1]; app.showDetails('history', app.HistTable);
verifyTrue(tc, any(contains(app.DetailArea.Value, 'pop_loadset')));
app.Fig.Position = [60 60 1000 640]; drawnow;
g = app.Fig.Children(1);
verifyEqual(tc, char(g.Scrollable), 'on');                                         % parts keep their size, window scrolls
verifyEqual(tc, g.RowHeight{3}, 470);
app.Fig.Position = [60 60 1380 860]; drawnow;
verifyEqual(tc, char(g.Scrollable), 'off');
end

function testNothingIsPrefilledAndDefaultsComeFromTheData(tc)
% A general tool: the analysis fields start empty (no example events,
% channels or windows); defaults that are used come from the data or are
% stated: baseline = pre-stimulus, epochs of epoched data, line frequency
% and data unit from the recording.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
verifyEmpty(tc, app.CondField.Value); verifyEmpty(tc, app.CompField.Value);
verifyEmpty(tc, app.EpochField.Value); verifyEmpty(tc, app.BaseField.Value);
verifyFalse(tc, any(contains({app.CondField.Placeholder, app.CompField.Placeholder}, {'11', '31', 'P3', 'Pz'})));
app.EpochField.Value = '-0.3 0.8';
[ep, bl] = app.windows();
verifyEqual(tc, ep, [-0.3 0.8]); verifyEqual(tc, bl, [-0.3 0]);          % pre-stimulus baseline by default
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.25 0.9])');
nqc_setBase(Ep); app.refreshLive(true); app.EpochField.Value = '';
[ep, bl] = app.windows();
verifyEqual(tc, ep, [Ep.xmin Ep.xmax], 'AbsTol', 1e-9);                   % the data's own epochs
verifyEqual(tc, bl, [Ep.xmin 0], 'AbsTol', 1e-9);
verifyTrue(tc, contains(app.EpochField.Placeholder, 'the data''s epochs'));
% line frequency and unit from the recording, not a fixed 50 Hz / uV
s = neuroqc.live.DataState.fromEEG(EEG);
verifyEqual(tc, s.lineFreq, 50); verifyEqual(tc, s.unitGuess, 'uV');
E60 = EEG; t = (0:E60.pnts-1) / E60.srate;
E60.data = E60.data - 4 * sin(2*pi*50*t) + 6 * sin(2*pi*60*t);            % a 60 Hz recording
s = neuroqc.live.DataState.fromEEG(E60); verifyEqual(tc, s.lineFreq, 60);
EV = EEG; EV.data = EV.data * 1e-6;
s = neuroqc.live.DataState.fromEEG(EV); verifyEqual(tc, s.unitGuess, 'V');
p = neuroqc.plan.Plan(); p = p.add('linenoise');
leaves = p.enumerate(neuroqc.live.DataState.fromEEG(E60), nqc_contract());
verifyEqual(tc, leaves(1).path{1}.params.freq, 60);
EF = EEG; EF.data = EF.data - 4 * sin(2*pi*50*t);                          % no mains peak
verifyError(tc, @() p.enumerate(neuroqc.live.DataState.fromEEG(EF), nqc_contract()), 'NeuroQC:NoLegalPipeline');
q = neuroqc.plan.Plan(); q = q.add('resample');                            % no default target rate
verifyError(tc, @() q.enumerate(s, nqc_contract()), 'NeuroQC:NoLegalPipeline');
end

function testFieldsAreFilledFromTheDatasetItself(tc)
% Epoched data say their epoch window, the events they are time-locked to
% and (from EEG.history) the baseline already removed; empty fields take
% them, typed fields are never overwritten, and an earlier automatic
% value follows the dataset when it changes.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.25 0.9], ''epochinfo'', ''yes'')');
[Ep, com] = pop_rmbase(Ep, [-250 0]); Ep = eegh(com, Ep);
nqc_setBase(EEG);
app = neuroqc.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
verifyEmpty(tc, app.CondField.Value); verifyEmpty(tc, app.EpochField.Value);   % continuous: nothing to say
nqc_setBase(Ep); app.refreshLive(false);
verifyEqual(tc, app.CondField.Value, '11: 11; 31: 31');                         % time-locking events
verifyEqual(tc, str2num(app.EpochField.Value), [Ep.xmin Ep.xmax], 'AbsTol', 1e-3); %#ok<ST2NM>
verifyEqual(tc, str2num(app.BaseField.Value), [-0.25 0]); %#ok<ST2NM>         % from pop_rmbase in the history
verifyTrue(tc, contains(app.DatasetLabel.Text, 'channel locations: yes'));
app.CondField.Value = 'target: 11; standard: 31';                               % the user's grouping
Ep2 = Ep; Ep2.setname = 'other'; Ep2 = pop_select(Ep2, 'trial', 1:20);
nqc_setBase(Ep2); app.refreshLive(false);
verifyEqual(tc, app.CondField.Value, 'target: 11; standard: 31');              % typed: kept
verifyEqual(tc, str2num(app.EpochField.Value), [Ep2.xmin Ep2.xmax], 'AbsTol', 1e-3); %#ok<ST2NM>
NL = EEG; NL.chanlocs = rmfield(NL.chanlocs, {'X', 'Y', 'Z'});
nqc_setBase(NL); app.refreshLive(false);
verifyTrue(tc, contains(app.DatasetLabel.Text, 'channel locations: NONE'));
end

function testCaptureReturnsCommandWithoutTouchingData(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
com = neuroqc.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_eegfiltnew(EEG, ''locutoff'', 0.5);');
verifyTrue(tc, startsWith(com, 'EEG = pop_eegfiltnew('));
p = neuroqc.plan.Plan(); p = p.addNative(com);     % becomes a fixed step
verifyEqual(tc, p.Slots(1).alternatives{1}.type, 'eeglab');   % one call: its arguments are step parameters
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
app.EpochField.Value = '-0.2 1';   % set by the user (nothing is prefilled)
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
app.PlanTable.Selection = [1 1]; app.setValues('cutoff', {0.1, 0.5});
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'baseline'; app.addStep();
app.CondField.Value = 'target: 11; standard: 31';
app.CompField.Value = 'P3: 0.3 0.5 @ Pz P3 P4';
app.ObjectiveField.Value = 'composite';
app.run(false);
verifyEqual(tc, size(app.ResultTable.Data, 1), 2);
verifyEqual(tc, size(app.ResultTable.Data, 2), 10);
verifyTrue(tc, evalin('base', 'exist(''neuroqc_result'', ''var'')') == 1);
% a latency objective through the panel syntax
app.CompField.Value = 'P3: 0.3 0.5 @ Pz # peakLatency positive';
app.settingsChanged();                               % what editing the field triggers
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
