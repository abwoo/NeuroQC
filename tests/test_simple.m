function tests = test_simple
%TEST_SIMPLE Simple mode: presets (ERP CORE values), recipes adapted to the
%   data, the dialog (nothing preselected, live count), pop_pipecompare
%   from a script, and the results window.
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
tc.TestData.EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'alphaUv', 10));
end

function testComponentPresetsAreErpCoreValues(tc)
% Kappenman et al. (2021), NeuroImage 225, 117465: Table 1 (site,
% time-locking, epoch, baseline) and Table 2 (measurement window), in ms.
E = {
    'N170', 'stimulus', [-200 800], [-200 0],    {'PO8'},        [110 150]
    'MMN',  'stimulus', [-200 800], [-200 0],    {'FCz'},        [125 225]
    'N2pc', 'stimulus', [-200 800], [-200 0],    {'PO7', 'PO8'}, [200 275]
    'N400', 'stimulus', [-200 800], [-200 0],    {'CPz'},        [300 500]
    'P3',   'stimulus', [-200 800], [-200 0],    {'Pz'},         [300 600]
    'LRP',  'response', [-800 200], [-800 -600], {'C3', 'C4'},   [-100 0]
    'ERN',  'response', [-600 400], [-400 -200], {'FCz'},        [0 100]};
verifyEqual(tc, neuroqc.simple.Presets.componentNames(), E(:, 1)');
for k = 1:size(E, 1)
    p = neuroqc.simple.Presets.component(E{k, 1});
    verifyEqual(tc, p.lockedTo, E{k, 2});
    verifyEqual(tc, 1000 * p.epoch, E{k, 3}, 'AbsTol', 1e-9);
    verifyEqual(tc, 1000 * p.baseline, E{k, 4}, 'AbsTol', 1e-9);
    verifyEqual(tc, p.sites, E{k, 5});
    verifyEqual(tc, 1000 * p.window, E{k, 6}, 'AbsTol', 1e-9);
end
end

function testContractsFromPresets(tc)
EEG = tc.TestData.EEG;
c = neuroqc.simple.Presets.contract(EEG, 'P3', {'11', '31'});
verifyEqual(tc, {c.conditions.name}, {'11', '31'});
verifyEqual(tc, c.components.roi, {'Pz'});                     % the dataset's own spelling
verifyEqual(tc, c.components.window, [0.3 0.6]);
[~, noPz] = evalc('pop_select(EEG, ''rmchannel'', {''Pz''})');
verifyError(tc, @() neuroqc.simple.Presets.contract(noPz, 'P3', {'11'}), 'NeuroQC:Simple');     % P3 is measured at Pz
verifyError(tc, @() neuroqc.simple.Presets.contract(EEG, 'P3', {}), 'NeuroQC:Simple');         % events must be chosen
b = neuroqc.simple.Presets.contract(EEG, 'alpha', {});
verifyTrue(tc, b.isSegmented());
verifyEqual(tc, b.bands.freq, [8 13]);
verifyEqual(tc, b.segment, 2);
end

function testRecipesAdaptToTheData(tc)
EEG = tc.TestData.EEG;
c = neuroqc.simple.Presets.contract(EEG, 'P3', {'11'});
ids = @(p) {p.Slots.id};
st = neuroqc.live.DataState.fromEEG(EEG);
p = neuroqc.simple.Presets.recipe('filters', st, c);
verifyEqual(tc, ids(p), {'highpass', 'lowpass', 'epoch', 'baseline'});
[p, notes] = neuroqc.simple.Presets.recipe('standard', st, c);
verifyEqual(tc, ids(p), {'highpass', 'lowpass', 'badchannels', 'ica', 'icremove', 'epoch', 'baseline', 'reject_threshold'});
verifyEmpty(tc, notes);
noloc = st; noloc.nLocated = 0;
[p, notes] = neuroqc.simple.Presets.recipe('standard', noloc, c);
verifyFalse(tc, any(ismember({'badchannels', 'ica', 'icremove'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'no channel locations')));
[~, Ep] = evalc('pop_epoch(EEG, {''11''}, [-0.2 0.8])');
[p, notes] = neuroqc.simple.Presets.recipe('full', neuroqc.live.DataState.fromEEG(Ep), c);
verifyFalse(tc, any(ismember({'highpass', 'lowpass', 'epoch', 'asr'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'already epoched')) && any(contains(notes, 'ASR')));
end

function testDialogPreselectsNothingAndCountsLive(tc)
EEG = tc.TestData.EEG;
d = neuroqc.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>
verifyEqual(tc, d.TypeDrop.Value, d.ErpType);                   % the data have events
verifyTrue(tc, contains(d.TypeWhy.Text, '11 (30)'));
verifyEqual(tc, d.MeasureDrop.Value, d.Choose);
verifyEmpty(tc, d.EventList.Value);
verifyEqual(tc, d.RecipeDrop.Value, '');
verifyEqual(tc, char(d.RunButton.Enable), 'off');
d.EventList.Value = {'11', '31'}; d.MeasureDrop.Value = 'P3'; d.RecipeDrop.Value = 'filters';
[n, msg] = d.update();
verifyEqual(tc, n, 12);                                         % 4 high-pass x 3 low-pass edges
verifyTrue(tc, startsWith(msg, '12 pipelines'));
verifyEqual(tc, char(d.RunButton.Enable), 'on');
d.RecipeDrop.Value = 'full';
[n, msg] = d.update();
verifyGreaterThan(tc, n, 500);
verifyTrue(tc, contains(msg, 'above the limit') && contains(msg, 'ICA decompositions'));
verifyEqual(tc, char(d.RunButton.Enable), 'off');
d.TypeDrop.Value = d.BandType; d.typeChanged();
verifyEqual(tc, d.MeasureDrop.Value, d.Choose);                 % changing the type clears the measure
verifyTrue(tc, ismember('alpha', d.MeasureDrop.Items));
E2 = EEG; E2.event = E2.event([]); E2.urevent = [];
d2 = neuroqc.gui.SimpleDialog(E2); c2 = onCleanup(@() delete(d2)); %#ok<NASGU>
verifyEqual(tc, d2.TypeDrop.Value, d2.BandType);                % continuous, no events
end

function testPopFunctionFromAScript(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[out, com, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
verifyEqual(tc, out, EEG);                                      % the dataset is not modified
verifyEqual(tc, numel(r.cands), 12);
verifyEqual(tc, com, 'EEG = pop_pipecompare(EEG, ''measure'',''P3'',''events'',{''11'',''31''},''recipe'',''filters'');');
evalin('base', 'clear neuroqc_result');
evalc(com);                                                     % the command repeats the comparison
delete(findall(groot, 'Type', 'figure', 'Name', 'Pipeline comparison'));
verifyEqual(tc, evalin('base', 'neuroqc_result.labels'), r.labels);
verifyEqual(tc, evalin('base', 'neuroqc_result.labels'), r.labels);
[~, ~, rb] = pop_pipecompare(EEG, 'measure', 'alpha', 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, rb.ref.segmented);
other = EEG; other.data(1) = other.data(1) + 1;
verifyError(tc, @() pop_pipecompare(other, 'measure', 'P3', 'events', {'11'}, 'recipe', 'filters', 'show', 'off'), ...
    'NeuroQC:Simple');                                          % only the current dataset
end

function testResultsWindow(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[~, ~, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
w = neuroqc.gui.SimpleResults(r); c = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
verifyTrue(tc, startsWith(w.Headline.Text, sprintf('Recommended: candidate %d', r.ranking.recommended)));
verifyEqual(tc, size(w.Table.Data, 1), 5);
verifyEqual(tc, w.Table.Data{1, 1}, sprintf('%d*', r.ranking.recommended));   % always shown, first
f = [tempname '.m']; c2 = onCleanup(@() delete(f)); %#ok<NASGU>
w.saveScript(f);
verifyTrue(tc, isfile(f));
verifyTrue(tc, contains(fileread(f), 'pop_eegfiltnew'));
end
