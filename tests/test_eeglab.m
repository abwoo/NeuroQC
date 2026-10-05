function tests = test_eeglab
%TEST_EEGLAB Integration with the live EEGLAB session: dataset detection,
%   EEGLAB's own command path, adoption into ALLEEG, the panel, and
%   (optionally) a real dataset given by PIPECOMPARE_REAL_SET (never committed;
%   only working copies are processed).
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
assert(exist('pop_epoch', 'file') == 2, 'EEGLAB must be on the path');
tc.TestData.realSet = getenv('PIPECOMPARE_REAL_SET');
end

% ------------------------------------------------------------ live session
function testLiveDetectionAndUnstoredWarning(tc)
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
[cur, info] = pipecompare.live.Session.current();
verifyEqual(tc, cur.setname, 'nqc_synth'); verifyTrue(tc, info.stored);
evalin('base', 'EEG.setname = ''changed on the command line'';');
[cur, info] = pipecompare.live.Session.current();
verifyEqual(tc, cur.setname, 'changed on the command line'); verifyFalse(tc, info.stored);
end

function testDatasetSwitchAndRemovalAreFollowed(tc)
A = nqc_synth(struct('seconds', 60, 'nPerCond', 10)); A.setname = 'A';
B = nqc_synth(struct('seconds', 60, 'nPerCond', 10, 'seed', 3)); B.setname = 'B';
nqc_setBase(A);
assignin('base', 'NQC_TMP', B);
evalin('base', '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, NQC_TMP, 0); clear NQC_TMP');
cur = pipecompare.live.Session.current(); verifyEqual(tc, cur.setname, 'B');
evalin('base', '[ALLEEG, EEG, CURRENTSET] = pop_newset(ALLEEG, EEG, CURRENTSET, ''retrieve'', 1, ''gui'', ''off'');');
cur = pipecompare.live.Session.current(); verifyEqual(tc, cur.setname, 'A');
evalin('base', 'ALLEEG = pop_delset(ALLEEG, [1 2]); EEG = eeg_emptyset(); CURRENTSET = 0;');
verifyEmpty(tc, pipecompare.live.Session.current());
end

% ------------------------------------------------------ EEGLAB code paths
function testApplyThroughEeglabCodePathRecordsHistory(tc)
% "Apply now" wraps the call in EEGLAB's own try/catch + eeglab_new, so
% EEGLAB records it (EEG.history and ALLCOM). DEBUG_EEGLAB_MENUS keeps
% eeglab_new from opening its interactive "new dataset" dialog in a test.
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS')); %#ok<NASGU>
pipecompare.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyTrue(tc, contains(cur.history, 'pop_reref( EEG, [])'));
s = pipecompare.live.DataState.fromEEG(cur);
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
pipecompare.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyEqual(tc, numel(strfind(cur.history, 'pop_reref')), 1);
pipecompare.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyEqual(tc, numel(strfind(cur.history, 'pop_reref')), 2);
end

function testFingerprintSeesEventEdits(tc)
% Audit: changing one event's type (same count, no history entry) gave the
% same fingerprint, so stale-result protection missed it.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
f0 = pipecompare.live.Session.fingerprint(EEG);
E = EEG; E.event(5).type = '99';
verifyNotEqual(tc, pipecompare.live.Session.fingerprint(E), f0);
E = EEG; E.event(5).latency = E.event(5).latency + 1;
verifyNotEqual(tc, pipecompare.live.Session.fingerprint(E), f0);
E = EEG; E.chanlocs(3).labels = 'X3';
verifyNotEqual(tc, pipecompare.live.Session.fingerprint(E), f0);
verifyEqual(tc, pipecompare.live.Session.fingerprint(EEG), f0);
end

function testCapturedNativeStepCanBeAppliedAndReedited(tc)
% Audit: after "Fix via EEGLAB dialog" the step is native and "Apply now"
% failed with "No EEGLAB dialog for native".
nqc_setBase(nqc_synth(struct('seconds', 60, 'nPerCond', 10)));
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS')); %#ok<NASGU>
com = 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''plotfreqz'',0);';
pipecompare.run.Native.applyCommand(com);
cur = evalin('base', 'EEG');
verifyTrue(tc, contains(cur.history, 'pop_eegfiltnew(EEG, ''locutoff'',0.5'));
verifyEqual(tc, evalin('base', 'ALLEEG(CURRENTSET).history'), cur.history);   % stored, not only in base EEG
verifyEqual(tc, pipecompare.run.Native.typeOfCommand(com), 'filter');           % re-edit opens the filter dialog
verifyEqual(tc, pipecompare.run.Native.typeOfCommand('EEG = pop_reref(EEG, []);'), 'reref');
end

function testPanelClearsResultsWhenThePlanChanges(tc)
% Audit: after removing a plan step the old results stayed visible and
% could be adopted as if they belonged to the new plan.
nqc_setBase(nqc_synth(struct('seconds', 90, 'nPerCond', 20)));
app = pipecompare.gui.Panel();
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
a = pipecompare.run.Native.argsOf('EEG = pop_epoch( EEG, {  ''11''  ''S  1''  }, [-0.2           1], ''newname'', ''x'', ''epochinfo'', ''yes'');', 'pop_epoch');
verifyEqual(tc, a{1}, {'11', 'S  1'});
verifyEqual(tc, a{2}, [-0.2 1]);
verifyEqual(tc, a(3:6), {'newname', 'x', 'epochinfo', 'yes'});
a = pipecompare.run.Native.argsOf('EEG = pop_rmbase( EEG, [-200 0] ,[]);', 'pop_rmbase');
verifyEqual(tc, a, {[-200 0], []});
a = pipecompare.run.Native.argsOf('[EEG, ~, LASTCOM] = pop_epoch(EEG);', 'pop_epoch');
verifyEmpty(tc, a);
verifyError(tc, @() pipecompare.run.Native.argsOf('EEG = pop_reref(EEG, []);', 'pop_epoch'), 'PipeCompare:Native');
end

function testPanelContractFromEeglabDialogs(tc)
% Conditions picked from the events, epoch and baseline from EEGLAB's own
% dialogs (their commands), ROI from the channel list, trials from an
% EEGLAB event selection: nothing is retyped, and the search uses exactly
% what the panel shows.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
nqc_setBase(EEG);
app = pipecompare.gui.Panel();
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
app = pipecompare.gui.Panel();
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
verifyEqual(tc, pipecompare.run.Native.typeOfCommand(sprintf('EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,0);\nEEG = pop_rejepoch(EEG, EEG.reject.rejthresh, 0);')), 'reject_threshold');
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
app = pipecompare.gui.Panel();
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
V = @(t, com, E) pipecompare.run.Native.catalogValues(t, com, E);
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
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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
verifyError(tc, @() pipecompare.PipeCompare.optimize(app.Plan, app.contract(), struct('checkpoint', d, 'stopAfter', 1)), 'PipeCompare:Interrupted');
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
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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
g = app.Fig.Children(1);
app.Fig.Position = [60 60 1000 640]; settle(g, 'on');            % the resize callback runs asynchronously
verifyEqual(tc, char(g.Scrollable), 'on');                                         % parts keep their size, window scrolls
verifyEqual(tc, g.RowHeight{3}, 470);
app.Fig.Position = [60 60 1380 860];
% the window manager may shrink a window to the screen: the layout must
% follow the size the window really has
big = @() app.Fig.Position(4) >= 840 && app.Fig.Position(3) >= 1300;
settle(g, pipecompare.utils.ternary(big(), 'off', 'on'));
verifyEqual(tc, char(g.Scrollable), pipecompare.utils.ternary(big(), 'off', 'on'));
end

function testNothingIsPrefilledAndDefaultsComeFromTheData(tc)
% A general tool: the analysis fields start empty (no example events,
% channels or windows); defaults that are used come from the data or are
% stated: baseline = pre-stimulus, epochs of epoched data, line frequency
% and data unit from the recording.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
nqc_setBase(EEG);
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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
s = pipecompare.live.DataState.fromEEG(EEG);
verifyEqual(tc, s.lineFreq, 50); verifyEqual(tc, s.unitGuess, 'uV');
E60 = EEG; t = (0:E60.pnts-1) / E60.srate;
E60.data = E60.data - 4 * sin(2*pi*50*t) + 6 * sin(2*pi*60*t);            % a 60 Hz recording
s = pipecompare.live.DataState.fromEEG(E60); verifyEqual(tc, s.lineFreq, 60);
EV = EEG; EV.data = EV.data * 1e-6;
s = pipecompare.live.DataState.fromEEG(EV); verifyEqual(tc, s.unitGuess, 'V');
p = pipecompare.plan.Plan(); p = p.add('linenoise');
leaves = p.enumerate(pipecompare.live.DataState.fromEEG(E60), nqc_contract());
verifyEqual(tc, leaves(1).path{1}.params.freq, 60);
EF = EEG; EF.data = EF.data - 4 * sin(2*pi*50*t);                          % no mains peak
verifyError(tc, @() p.enumerate(pipecompare.live.DataState.fromEEG(EF), nqc_contract()), 'PipeCompare:NoLegalPipeline');
q = pipecompare.plan.Plan(); q = q.add('resample');                            % no default target rate
verifyError(tc, @() q.enumerate(s, nqc_contract()), 'PipeCompare:NoLegalPipeline');
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
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
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

function testNoDialogSettingIsDroppedSilently(tc)
% Every dialog setting a catalog step does not reproduce is reported, so
% the user decides (keep the whole EEGLAB command or the step's values).
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
[~, Ep] = evalc('pop_epoch(EEG, {''11'',''31''}, [-0.2 1])');
V = @(t, com, E) pipecompare.run.Native.catalogValues(t, com, E);
has = @(notes, txt) any(contains(notes, txt));
[~, n] = V('ica', 'EEG = pop_runica(EEG, ''icatype'',''runica'',''extended'',1,''pca'',20);', EEG);
verifyTrue(tc, has(n, 'pca = 20'));
[~, n] = V('ica', 'EEG = pop_runica(EEG, ''icatype'',''runica'',''extended'',1,''chanind'',[1:20]);', EEG);
verifyTrue(tc, has(n, 'ICA on 20 of 32 channels'));
[~, n] = V('ica', 'EEG = pop_runica(EEG, ''icatype'',''jader'');', EEG);
verifyTrue(tc, has(n, 'icatype'));
[~, n] = V('ica', 'EEG = pop_runica(EEG, ''icatype'',''runica'',''extended'',1,''interrupt'',''on'');', EEG);
verifyEmpty(tc, n);                                            % display-only option: nothing lost
[~, n] = V('badchannels', 'EEG = pop_rejchan(EEG, ''elec'',[1:32],''threshold'',5,''norm'',''off'',''measure'',''kurt'');', EEG);
verifyTrue(tc, has(n, 'norm'));
[~, n] = V('badchannels', 'EEG = pop_rejchan(EEG, ''elec'',[1:32],''threshold'',5,''norm'',''on'',''measure'',''spec'',''freqrange'',[1 30]);', EEG);
verifyTrue(tc, has(n, 'freqrange'));
[~, n] = V('reject_threshold', 'EEG = pop_eegthresh(EEG,1,[1:32],-100,100,0,0.5,0,0);', Ep);
verifyTrue(tc, has(n, 'time range [0 0.5] s'));
[~, n] = V('reject_threshold', 'EEG = pop_eegthresh(EEG,0,[1:10],-100,100,-0.2,0.996,0,0);', Ep);
verifyTrue(tc, has(n, 'ICA components'));
[~, n] = V('reject_threshold', sprintf('EEG = pop_eegthresh(EEG,1,[1:32],-100,100,%.15g,%.15g,0,0);', Ep.xmin, Ep.xmax), Ep);
verifyEmpty(tc, n);                                            % the whole epoch: as the step does
[~, n] = V('asr', 'EEG = pop_clean_rawdata(EEG, ''FlatlineCriterion'',''off'',''ChannelCriterion'',''off'',''LineNoiseCriterion'',''off'',''Highpass'',''off'',''BurstCriterion'',20,''WindowCriterion'',''off'',''BurstRejection'',''on'',''Distance'',''Riemannian'');', EEG);
verifyTrue(tc, has(n, 'BurstRejection') && has(n, 'Distance'));
[~, n] = V('resample', 'EEG = pop_resample( EEG, 125, 0.8, 0.4);', EEG);
verifyTrue(tc, has(n, 'anti-aliasing'));
end

function testDialogsSeeTheDataAtTheirPlanStep(tc)
% A step's EEGLAB dialog opens on the data as the plan has them at that
% step: after ICA (for the ICLabel dialogs), after channel removal (for
% channel lists), epoched (for epoch rejection).
EEG = nqc_synth(struct('seconds', 200, 'nPerCond', 30));
nqc_setBase(EEG);
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.EpochField.Value = '-0.2 1';
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
app.TypeDrop.Value = 'channels'; app.addStep(); app.PlanTable.Selection = [1 1];
app.setValues('labels', {{'O1'}}); app.setValues('action', {'remove'});
app.TypeDrop.Value = 'ica'; app.addStep(); app.PlanTable.Selection = [2 1]; app.setValues('fitHighpass', {1});
app.TypeDrop.Value = 'icremove'; app.addStep();
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'reject_threshold'; app.addStep();
verifyEmpty(tc, EEG.icaweights);                                  % the dataset itself has no ICA
P3 = app.previewAt(3);
verifyNotEmpty(tc, P3.icaweights);                                % ...the icremove dialog sees one
verifyFalse(tc, any(strcmp({P3.chanlocs.labels}, 'O1')));        % ...and O1 already removed
verifyLessThan(tc, P3.pnts / P3.srate, 121);                       % a short copy (first 120 s)
P5 = app.previewAt(5);
verifyGreaterThan(tc, P5.trials, 1);                              % the rejection dialog sees epochs
P1 = app.previewAt(1);
verifyTrue(tc, any(strcmp({P1.chanlocs.labels}, 'O1')));          % the first step sees the dataset
end

function testTrialRuleFollowsItsRecording(tc)
% A trial rule of event ids belongs to its recording: it survives
% processing of that recording (e.g. a filter) but is reset, with a
% message, when another recording becomes current.
A = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
B = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'seed', 3));
nqc_setBase(A);
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.addCondition('target', {'11'}); app.addCondition('standard', {'31'});
app.setTrialRule(struct('mode', 'urevents', 'ids', [A.event(1:10).urevent]));
[~, A2] = evalc('pop_eegfiltnew(A, ''locutoff'', 0.5, ''plotfreqz'', 0)');
nqc_setBase(A2); app.refreshLive(false);
verifyEqual(tc, app.TrialRule.mode, 'urevents');                  % same recording, processed: kept
nqc_setBase(B); app.refreshLive(false);
verifyEqual(tc, app.TrialRule.mode, 'all');                       % another recording: reset
verifyTrue(tc, contains(app.StatusLabel.Text, 'reset to all trials'));
app.setTrialRule(struct('mode', 'time_ranges', 'ranges', [30 Inf]));
nqc_setBase(A); app.refreshLive(false);
verifyEqual(tc, app.TrialRule.mode, 'time_ranges');               % a time range is kept...
verifyTrue(tc, contains(app.TrialLabel.Text, 'set on another recording'));   % ...and shown as such
end

function testEpochAndBaselineConflictsAreDecidedByTheUser(tc)
% Events of the epoch dialog that differ from the conditions, and a
% baseline on a channel subset, are resolved by the user's choice.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
nqc_setBase(EEG);
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
app.addCondition('target', {'11'});
[~, ~, com] = pop_epoch(EEG, {'11', '31'}, [-0.3 0.9], 'epochinfo', 'yes');
app.epochFromEEGLAB(com, 'keep');
verifyEqual(tc, app.CondField.Value, 'target: 11');              % kept
verifyEqual(tc, str2num(app.EpochField.Value), [-0.3 0.9]); %#ok<ST2NM>
app.epochFromEEGLAB(com, 'replace');
verifyEqual(tc, app.CondField.Value, '11: 11; 31: 31');          % replaced by the dialog's events
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.3 0.9])');
[~, com] = pop_rmbase(Ep, [-300 0], [], 1:5);                     % 5 channels only
app.BaseField.Value = '';
app.baselineFromEEGLAB(com, 'cancel');
verifyEmpty(tc, app.BaseField.Value);                            % cancelled: unchanged
app.baselineFromEEGLAB(com, 'all');
verifyEqual(tc, str2num(app.BaseField.Value), [-0.3 0]); %#ok<ST2NM>
end

function testAnyEeglabMenuOperationIsAPlanStep(tc)
% GUI users add operations outside the catalog (any EEGLAB menu item,
% plugins included) as plan steps; their arguments can be searched and the
% step's own dialog reopens for Configure in EEGLAB.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
app = pipecompare.gui.Panel(); cleanup = onCleanup(@() delete(app)); %#ok<NASGU>
evalc('[~, com] = pop_firma(EEG, ''forder'', 4);');            % what the dialog returns
app.addEeglabStep('', com);
s = app.Plan.Slots(end);
verifyEqual(tc, s.id, 'firma');
verifyEqual(tc, s.alternatives{1}.type, 'eeglab');
app.PlanTable.Selection = [numel(app.Plan.Slots) 1];
app.setValues('forder', {4, 8});                                 % searched like any argument
c = nqc_contract();
p = app.Plan; p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
verifyEqual(tc, numel(r.cands), 2);
verifyTrue(tc, all(arrayfun(@(x) any(contains(x.coms, 'pop_firma')), r.cands)));
verifyEqual(tc, sort(cellfun(@(x) sum(contains(x, '''forder'',8')), {r.cands.coms})), [0 1]);
if ~isempty(pipecompare.run.Native.menuSteps())                      % EEGLAB's main window is open
    verifyEqual(tc, app.dialogType(s), 'call:[EEG LASTCOM] = pop_firma(EEG);');
    verifyTrue(tc, any(strcmp({pipecompare.run.Native.menuSteps().label}, 'Tools > Filter the data > Moving average FIR filter')));
end
end

function testEventTypesAreMatchedExactly(tc)
% Event types are case-sensitive, as in pop_epoch and the scoring; a type
% that differs only in case is refused with the near match named.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
for k = find(strcmp(cellfun(@(x) char(string(x)), {EEG.event.type}, 'UniformOutput', false), '11'))
    EEG.event(k).type = 'S 11';
end
st = pipecompare.live.DataState.fromEEG(EEG);
c = pipecompare.eval.Contract('conditions', {'t', {'s 11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.3 0.5], {'Pz'}});
try
    c.validate(st); verifyFail(tc, 'expected PipeCompare:Contract');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:Contract');
    verifyTrue(tc, contains(ME.message, 'did you mean ''S 11'''));
end
end

function testInterpolationNeedsPositionsOfTheChannelsItFills(tc)
% EEGLAB's eeg_interp leaves a channel without a position untouched; the
% step refuses instead of reporting it interpolated.
EEG = nqc_synth(struct('seconds', 30, 'nPerCond', 5));
k = find(strcmpi({EEG.chanlocs.labels}, 'Pz'));
EEG.chanlocs(k).X = []; EEG.chanlocs(k).Y = []; EEG.chanlocs(k).Z = [];
st = pipecompare.live.DataState.fromEEG(EEG);
verifyEqual(tc, st.nLocated, EEG.nbchan - 1);
verifyEqual(tc, lower(st.unlocated), {'pz'});
in = struct('type', 'channels', 'params', struct('labels', {{'Pz'}}, 'action', 'interpolate'));
verifyError(tc, @() pipecompare.run.Steps.run(in, EEG, struct()), 'PipeCompare:Chanlocs');
end

function testEpochsMarkedButNotRemovedAreReported(tc)
% A step that only marks epochs (EEGLAB's pop_eegthresh with reject = 0,
% ERPLAB's artifact detection) removes nothing; the candidate says so.
% A rejection step that removes what it marks leaves no such note.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('epoch'); p = p.add('baseline');
p = p.addNative('EEG = pop_eegthresh(EEG, 1, 1:32, -20, 20, -0.2, 0.996, 0, 0);');
r = pipecompare.PipeCompare.optimize(p, c);
verifyTrue(tc, contains(r.ranking.table.note{1}, 'marked for rejection'));
q = pipecompare.plan.Plan(); q = q.add('epoch'); q = q.add('baseline'); q = q.add('reject_threshold', 'uv', 20);
r = pipecompare.PipeCompare.optimize(q, c);
verifyEmpty(tc, r.ranking.table.note{1});
end

function testScriptRefusesWhenThereIsNoSingleRecommendation(tc)
% With several strata (or nothing feasible) there is no recommendation:
% writeScript(r, [], f) must say so and write nothing, like adopt.
r = struct('ranking', struct('recommended', [], 'byStratum', struct('recommended', {3, 5})), ...
    'labels', {{}}, 'rootComs', {{}}, 'cands', []);
f = [tempname '.m'];
verifyError(tc, @() pipecompare.PipeCompare.writeScript(r, [], f), 'PipeCompare:Adopt');
verifyFalse(tc, isfile(f));
verifyError(tc, @() pipecompare.PipeCompare.script(r), 'PipeCompare:Adopt');
r.ranking.byStratum = r.ranking.byStratum([]);
verifyError(tc, @() pipecompare.PipeCompare.writeScript(r, [], f), 'PipeCompare:Adopt');
verifyFalse(tc, isfile(f));
end

function testScriptIncludesThePreparationLines(tc)
% script() must rebuild the candidate from the starting dataset as it is
% in EEGLAB, so it carries PipeCompare's preparation (here volts -> uV).
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
EEG.data = EEG.data * 1e-6;                                % stored in volts
nqc_setBase(EEG);
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c, struct('dataUnit', 'V'));
txt = pipecompare.PipeCompare.script(r, 1);
verifyTrue(tc, contains(txt, 'volts -> microvolts'));
[~, out] = evalc('runScript(EEG, txt)');
m = pipecompare.eval.Measure.candidate(out, c, r.ref);
verifyEqual(tc, [m.objectives.agg], [r.cands(1).m.objectives.agg], 'RelTol', 1e-9);
end

function testCheckpointIdentityFollowsTheData(tc)
% The identity hash is the same for the same search and changes with one
% sample of the data (it is computed block by block).
EEG = nqc_synth(struct('seconds', 30, 'nPerCond', 5));
r = struct('root', EEG, 'rootComs', {{}}, 'contract', nqc_contract(), 'labels', {{'a'}}, 'options', struct());
a = pipecompare.run.Executor.identity(r);
verifyEqual(tc, pipecompare.run.Executor.identity(r), a);
r.root.data(3, 100) = r.root.data(3, 100) + 1e-3;
verifyNotEqual(tc, pipecompare.run.Executor.identity(r), a);
end

function testScoredTrialsAreTheOutputTrials(tc)
% The trials that are scored (Measure.trials) and the trials a candidate
% hands on (Executor.selectEligible) come from one time-locking rule.
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.3 0.5], {'Pz'}}, 'trials', struct('mode', 'time_ranges', 'ranges', [30 Inf]));
[~, root] = evalc('pipecompare.run.Executor.prepareRoot(EEG, c)');
[~, E] = evalc('pop_epoch(root, c.allEvents(), c.epoch, ''epochinfo'', ''yes'')');
T = pipecompare.eval.Measure.trials(E, c, true);
[~, out] = evalc('pipecompare.run.Executor.selectEligible(E, c)');
lock = pipecompare.eval.Measure.lockingEvents(out, c.allEvents());
verifyEqual(tc, sort(arrayfun(@(k) double(out.event(k).urevent), lock)), sort(T.id'));
verifyLessThan(tc, out.trials, E.trials);                       % the rule did remove trials
end

function testPluginMenusUseEeglabErrorHandling(tc)
% Menu callbacks are wrapped like EEGLAB's own (try ... catch,
% eeglab_error; end), so an error shows EEGLAB's error window.
f = figure('Visible', 'off'); cleanup = onCleanup(@() delete(f)); %#ok<NASGU>
saved = getappdata(0, 'pipecompare_eeglab_strings');                 % EEGLAB's real strings, put back after
restore = onCleanup(@() setappdata(0, 'pipecompare_eeglab_strings', saved)); %#ok<NASGU>
uimenu(f, 'Label', 'Tools', 'Tag', 'tools');
ts = struct('no_check', 'try,'); cs = struct('add_to_hist', '');
evalc('eegplugin_pipecompare(f, ts, cs)');
items = findobj(findobj(f, 'Tag', 'pipecompare_menu'), 'Type', 'uimenu', '-not', 'Tag', 'pipecompare_menu');
verifyNumElements(tc, items, 2);                                  % simple mode, panel
for k = 1:numel(items)
    cb = items(k).MenuSelectedFcn;
    verifyTrue(tc, startsWith(cb, 'try,') && contains(cb, 'catch, eeglab_error; end'));
end
evalc('eegplugin_pipecompare(f, ts, cs)');                            % a second call adds nothing
verifyNumElements(tc, findobj(f, 'Tag', 'pipecompare_menu'), 1);
end

function testQuickSignatureAndFullFingerprint(tc)
% The panel's per-second check (quickPrint) does not depend on the event
% contents; the full fingerprint (at least every 5 s, and before a search
% or Adopt) does. Its cost does not grow with the events.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
q = pipecompare.live.Session.quickPrint(EEG); f = pipecompare.live.Session.fingerprint(EEG);
E = EEG; E.event(3).type = 'edited';                               % same count, other content
verifyEqual(tc, pipecompare.live.Session.quickPrint(E), q);
verifyNotEqual(tc, pipecompare.live.Session.fingerprint(E), f);
E = EEG; E.event(end) = [];                                        % a count changes
verifyNotEqual(tc, pipecompare.live.Session.quickPrint(E), q);
E = EEG; E.data(1) = E.data(1) + 1;                                % a sampled data value changes
verifyNotEqual(tc, pipecompare.live.Session.quickPrint(E), q);
n = 20000; E = EEG;
E.event = struct('type', repmat({'x'}, 1, n), 'latency', num2cell(sort(randi(E.pnts, 1, n))), 'urevent', num2cell(1:n));
t0 = tic; for k = 1:5, pipecompare.live.Session.quickPrint(E); end; tq = toc(t0);
t0 = tic; for k = 1:5, pipecompare.live.Session.fingerprint(E); end; tf = toc(t0);
verifyLessThan(tc, tq, tf / 5);                                    % measured: ~1 ms vs ~55 ms
end

function testMultiverseSummaryNamesTheInfluentialChoice(tc)
% Every allowed pipeline is run, so the spread of each measure over the
% feasible pipelines and the choice behind it are known: here the
% high-pass edge (0.1 vs 1.5 Hz) moves the P3 mean amplitude far more
% than the low-pass edge (30 vs 40 Hz).
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
nqc_setBase(EEG);
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {0.1, 1.5}); p = p.add('lowpass', 'cutoff', {30, 40});
p = p.add('epoch'); p = p.add('baseline');
lim = struct('maxAmplitudeError', 1, 'minWaveformCorr', 0, 'minTopoCorr', 0, 'maxLatencyShiftMs', 1000, 'maxArtifactPct', 1);
r = pipecompare.PipeCompare.optimize(p, c, lim);
T = r.robustness;
verifyEqual(tc, height(T), 1);                                     % one measure, one condition
verifyEqual(tc, T.nPipelines, 4);
verifyEqual(tc, T.mostInfluentialChoice{1}, 'highpass.cutoff');
verifyGreaterThan(tc, T.share, 0.9);
verifyEqual(tc, T.range, T.max - T.min);
end

function testDatasetsFromNeuroQCStillWork(tc)
% Datasets adopted with NeuroQC (<= 0.7) carry EEG.etc.neuroqc and
% '% NeuroQC' history lines: an old trial rule is cleared before a search,
% and the tagged lines are still recognized as the tool's own.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
EEG.etc.neuroqc.eligibleUrevents = [1 2 3];
EEG.history = sprintf('%s\nEEG = pop_interp(EEG, EEG.etc.neuroqc.preRemoved([1]), ''spherical''); %% NeuroQC: channels removed before the plan', EEG.history);
[~, root, coms] = evalc('pipecompare.run.Executor.prepareRoot(EEG, nqc_contract())');
verifyFalse(tc, isfield(root.etc.neuroqc, 'eligibleUrevents'));
verifyTrue(tc, any(contains(coms, 'EEG.etc.neuroqc = rmfield(EEG.etc.neuroqc, ''eligibleUrevents'')')));
st = pipecompare.live.DataState.fromEEG(EEG);
verifyTrue(tc, any(strcmp({st.provenance.category}, 'executed by PipeCompare')));
end

function testCaptureReturnsCommandWithoutTouchingData(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
com = pipecompare.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_eegfiltnew(EEG, ''locutoff'', 0.5);');
verifyTrue(tc, startsWith(com, 'EEG = pop_eegfiltnew('));
p = pipecompare.plan.Plan(); p = p.addNative(com);     % becomes a fixed step
verifyEqual(tc, p.Slots(1).alternatives{1}.type, 'eeglab');   % one call: its arguments are step parameters
end

function testScoresIgnoreChannelOffsets(tc)
% 0.6 split-half metrics were driven by per-channel DC offsets
% (v06_reproductions R2). Scores here are baseline-corrected per trial.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
c = pipecompare.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4','POz'}});
ref = pipecompare.eval.Measure.reference(EEG, c);
off = EEG; off.data = off.data + single((1:off.nbchan)' * 50);
a = pipecompare.eval.Measure.candidate(EEG, c, ref); b = pipecompare.eval.Measure.candidate(off, c, ref);
verifyEqual(tc, b.objectives(1).agg, a.objectives(1).agg, 'AbsTol', 1e-3);
end

% ------------------------------------------------------------------ adopt
function testAdoptRefusesStaleStartingDataset(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, nqc_contract());
% the starting dataset is changed in place and the old copy is gone
evalin('base', ['[EEG, LASTCOM] = pop_reref(EEG, []); EEG = eegh(LASTCOM, EEG); ', ...
    '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, EEG, CURRENTSET);']);
n0 = evalin('base', 'numel(ALLEEG)');
verifyError(tc, @() pipecompare.PipeCompare.adopt(r, 1), 'PipeCompare:StaleState');
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0);           % nothing stored
pipecompare.PipeCompare.adopt(r, 1, true);                               % explicit override
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0 + 1);
ad = evalin('base', 'EEG');
verifyTrue(tc, contains(ad.history, 'pop_eegfiltnew'));
verifyFalse(tc, contains(ad.history, 'pop_reref'));              % built from the stored start
end

function testWriteScriptReproducesCandidate(tc)
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20));
nqc_setBase(EEG);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', 100);
c = nqc_contract();
r = pipecompare.PipeCompare.optimize(p, c);
d = tempname; mkdir(d); cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
f = fullfile(d, 'nqc_pipeline_test.m');
pipecompare.PipeCompare.writeScript(r, 1, f);
addpath(d); c2 = onCleanup(@() rmpath(d)); %#ok<NASGU>
out = nqc_pipeline_test(EEG);
m = pipecompare.eval.Measure.candidate(out, c, r.ref);
verifyEqual(tc, [m.objectives.agg], [r.cands(1).m.objectives.agg], 'RelTol', 1e-9);
% another recording: its own epochs are rejected, not this one's
code = regexprep(fileread(f), '\n%[^\n]*', '');                % without the comments
verifyFalse(tc, contains(code, 'pop_rejepoch'));
B = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'seed', 8));
outB = nqc_pipeline_test(B);
verifyTrue(tc, contains(outB.history, 'pop_eegthresh'));
[~, Be] = evalc('pop_eegfiltnew(B, ''locutoff'', 0.5, ''plotfreqz'', 0)');
[~, Be] = evalc('pop_epoch(Be, c.allEvents(), c.epoch)');
[~, Be] = evalc('pop_rmbase(Be, 1000 * c.baseline, [])');
over = squeeze(max(max(abs(Be.data), [], 1), [], 2)) > 100;
verifyGreaterThan(tc, sum(over), 0);
verifyEqual(tc, outB.trials, Be.trials - sum(over));
end

% -------------------------------------------------------------------- GUI
function testPanelFollowsLiveDatasetAndRuns(tc)
nqc_setBase(nqc_synth(struct('seconds', 120, 'nPerCond', 30)));
app = pipecompare.gui.Panel();
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
verifyTrue(tc, evalin('base', 'exist(''pipecompare_result'', ''var'')') == 1);
verifyEmpty(tc, findall(groot, 'Type', 'figure', 'Name', 'PipeCompare'));   % its progress window is closed
% the selected pipeline as a function for any recording, as in the simple mode
app.ResultTable.Selection = [2 1];
f = [tempname '.m']; c2 = onCleanup(@() delete(f)); %#ok<NASGU>
app.saveScript(f);
verifyTrue(tc, contains(fileread(f), 'pipecompare.PipeCompare.apply(EEG, steps, contract)'));
% a latency objective through the panel syntax
app.CompField.Value = 'P3: 0.3 0.5 @ Pz # peakLatency positive';
app.settingsChanged();                               % what editing the field triggers
app.ObjectiveField.Value = 'P3.peakLatency';
app.run(false);
r = evalin('base', 'pipecompare_result');
verifyEqual(tc, r.ranking.units, {'ms'});
end

% ------------------------------------------------------------- real data
function testRealDatasetStateOnWorkingCopy(tc)
% Reads the real dataset's history and state; the file on disk must not change.
f = tc.TestData.realSet;
assumeTrue(tc, ~isempty(f) && isfile(f), 'PIPECOMPARE_REAL_SET not set');
before = dir(f);
[p, n, e] = fileparts(f);
EEG = pop_loadset('filename', [n e], 'filepath', p);
nqc_setBase(EEG);
txt = evalc('s = pipecompare.PipeCompare.state();');
verifyNotEmpty(tc, s.history);
verifyNotEmpty(tc, s.provenance);
verifyTrue(tc, contains(txt, 'recorded in EEG.history'));
after = dir(f);
verifyEqual(tc, [after.datenum after.bytes], [before.datenum before.bytes]);
end

function settle(g, state)
% wait (at most 5 s) until the layout has followed a window resize
for k = 1:50
    drawnow;
    if strcmp(char(g.Scrollable), state), return; end
    pause(0.1);
end
end

function EEG = runScript(EEG, NQC_TXT__)
% run script() output on EEG, as a user would paste it
eval(NQC_TXT__);
end
