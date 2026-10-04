function tests = test_simple
%TEST_SIMPLE Simple mode: presets (ERP CORE values), recipes adapted to the
%   data, the dialog (what to measure, live count), pop_pipecompare
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
verifyEqual(tc, pipecompare.simple.Presets.componentNames(), E(:, 1)');
for k = 1:size(E, 1)
    p = pipecompare.simple.Presets.component(E{k, 1});
    verifyEqual(tc, p.lockedTo, E{k, 2});
    verifyEqual(tc, 1000 * p.epoch, E{k, 3}, 'AbsTol', 1e-9);
    verifyEqual(tc, 1000 * p.baseline, E{k, 4}, 'AbsTol', 1e-9);
    verifyEqual(tc, p.sites, E{k, 5});
    verifyEqual(tc, 1000 * p.window, E{k, 6}, 'AbsTol', 1e-9);
end
end

function testContractsFromPresets(tc)
EEG = tc.TestData.EEG;
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11', '31'});
verifyEqual(tc, {c.conditions.name}, {'11', '31'});
verifyEqual(tc, c.components.roi, {'Pz'});                     % the dataset's own spelling
verifyEqual(tc, c.components.window, [0.3 0.6]);
[~, noPz] = evalc('pop_select(EEG, ''rmchannel'', {''Pz''})');
verifyError(tc, @() pipecompare.simple.Presets.contract(noPz, 'P3', {'11'}), 'PipeCompare:Simple');     % P3 is measured at Pz
verifyError(tc, @() pipecompare.simple.Presets.contract(EEG, 'P3', {}), 'PipeCompare:Simple');         % events must be chosen
b = pipecompare.simple.Presets.contract(EEG, 'alpha', {});
verifyTrue(tc, b.isSegmented());
verifyEqual(tc, b.bands.freq, [8 13]);
verifyEqual(tc, b.segment, 2);
own = struct('window', [0.25 0.9], 'band', [], 'channels', {{'pz'}});
w = pipecompare.simple.Presets.contract(EEG, 'custom', {'11'}, 2, false, own);
verifyEqual(tc, w.components.roi, {'Pz'});
verifyEqual(tc, w.components.window, [0.25 0.9]);
verifyEqual(tc, w.epoch, [-0.2 1.1], 'AbsTol', 1e-12);          % the epoch holds the window
own.channels = {};
verifyError(tc, @() pipecompare.simple.Presets.contract(EEG, 'custom', {'11'}, 2, false, own), 'PipeCompare:Simple');
own = struct('window', [], 'band', [0.5 3], 'channels', {{}});
f = pipecompare.simple.Presets.contract(EEG, 'band', {}, 2, false, own);
verifyEqual(tc, f.bands.roi, pipecompare.simple.Presets.eegChannels(EEG));
verifyEqual(tc, f.segment, 4);                                  % two cycles of 0.5 Hz
own.band = [8 EEG.srate];
verifyError(tc, @() pipecompare.simple.Presets.contract(EEG, 'band', {}, 2, false, own), 'PipeCompare:Simple');
end

function testRecipesAdaptToTheData(tc)
EEG = tc.TestData.EEG;
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11'});
ids = @(p) {p.Slots.id};
st = pipecompare.live.DataState.fromEEG(EEG);
p = pipecompare.simple.Presets.recipe('filters', st, c);
verifyEqual(tc, ids(p), {'highpass', 'lowpass', 'epoch', 'baseline'});
[p, notes] = pipecompare.simple.Presets.recipe('standard', st, c);
verifyEqual(tc, ids(p), {'badchannels', 'ica', 'highpass', 'lowpass', 'icremove', 'epoch', 'baseline', 'reject_threshold'});
verifyEmpty(tc, notes);                                          % ICA first: one decomposition for every filter choice
noloc = st; noloc.nLocated = 0;
[p, notes] = pipecompare.simple.Presets.recipe('standard', noloc, c);
verifyFalse(tc, any(ismember({'badchannels', 'ica', 'icremove'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'no channel locations')));
[~, Ep] = evalc('pop_epoch(EEG, {''11''}, [-0.2 0.8])');
[p, notes] = pipecompare.simple.Presets.recipe('standard', pipecompare.live.DataState.fromEEG(Ep), c);
verifyFalse(tc, any(ismember({'highpass', 'lowpass', 'epoch'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'already epoched')));
verifyError(tc, @() pipecompare.simple.Presets.recipe('full', st, c), 'PipeCompare:Simple');   % ASR: panel or script
% filter edges the data already have are not compared: they would leave
% the data unchanged but filter the known signal
H = EEG; H.history = sprintf('%s\nEEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''plotfreqz'',0);', EEG.history);
[p, notes] = pipecompare.simple.Presets.recipe('filters', pipecompare.live.DataState.fromEEG(H), c);
verifyEqual(tc, p.Slots(1).alternatives{1}.params.cutoff, {1});
verifyTrue(tc, any(contains(notes, 'high-pass 0.1, 0.3, 0.5 Hz (the data are already high-pass-filtered at 0.5 Hz)')));
end

function testPooledEventTypesAreOneCondition(tc)
c = pipecompare.simple.Presets.contract(tc.TestData.EEG, 'P3', {'11', '31'}, 2, true);
verifyEqual(tc, {c.conditions.name}, {'11+31'});
verifyEqual(tc, c.conditions.events, {'11', '31'});
end

function testDialogAsksOnlyWhatToMeasure(tc)
EEG = tc.TestData.EEG;
d = pipecompare.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>
verifyTrue(tc, contains(d.TypeWhy.Text, 'ERP measures or band power'));   % read from the data, not asked
verifyEqual(tc, d.MeasureDrop.Value, d.Choose);
verifyTrue(tc, all(ismember({'P3', 'custom', 'alpha', 'band'}, d.MeasureDrop.ItemsData)));
verifyTrue(tc, ismember('ERP: P3 (Pz, 300-600 ms)', d.MeasureDrop.Items));
verifyEmpty(tc, d.EventList.Value);
verifyEqual(tc, d.RecipeDrop.Value, 'standard');                % preselected
verifyEqual(tc, char(d.RunButton.Enable), 'off');
verifyEqual(tc, d.Grid.RowHeight{3}, 0);                        % no custom row for a preset
d.EventList.Value = {'11', '31'}; d.MeasureDrop.Value = 'P3'; d.measureChanged();
[n, msg] = d.update();
verifyEqual(tc, n, 4 * 3 * 3 * 3);                              % filters x ICLabel threshold x rejection threshold
verifyTrue(tc, contains(msg, '(1 ICA decomposition)'));
verifyEqual(tc, char(d.RunButton.Enable), 'on');
d.RecipeDrop.Value = 'filters';
[n, msg] = d.update();
verifyEqual(tc, n, 12);                                         % 4 high-pass x 3 low-pass edges
verifyTrue(tc, startsWith(msg, '12 pipelines'));
d.MeasureDrop.Value = 'alpha'; d.measureChanged();
verifyEqual(tc, char(d.EventList.Enable), 'off');               % band power needs no events
o = d.options();
verifyEmpty(tc, o.events);
% epoched data: ERP only; filters cannot be compared after epoching
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.2 0.8])');
d3 = pipecompare.gui.SimpleDialog(Ep); c3 = onCleanup(@() delete(d3)); %#ok<NASGU>
verifyFalse(tc, any(ismember({'alpha', 'band'}, d3.MeasureDrop.ItemsData)));
verifyEqual(tc, sort(d3.EventList.Value), {'11', '31'});        % the time-locking types
d3.MeasureDrop.Value = 'P3'; d3.RecipeDrop.Value = 'filters'; d3.measureChanged();
[n, msg] = d3.update();
verifyEqual(tc, n, 1);
verifyTrue(tc, startsWith(msg, 'Only 1 pipeline: nothing to compare.'));
verifyEqual(tc, char(d3.RunButton.Enable), 'off');
% continuous, boundary markers only: band power
E2 = EEG; E2.event = E2.event([]); E2.urevent = [];
E2.event = struct('type', 'boundary', 'latency', 100, 'duration', 0);
d2 = pipecompare.gui.SimpleDialog(E2); c2 = onCleanup(@() delete(d2)); %#ok<NASGU>
verifyFalse(tc, ismember('P3', d2.MeasureDrop.ItemsData));
verifyTrue(tc, ismember('alpha', d2.MeasureDrop.ItemsData));
verifyEmpty(tc, d2.EventList.Items);
end

function testDialogOwnWindowAndBand(tc)
EEG = tc.TestData.EEG;
d = pipecompare.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>
d.EventList.Value = {'11', '31'}; d.RecipeDrop.Value = 'filters';
d.MeasureDrop.Value = 'custom'; d.measureChanged();
verifyEqual(tc, d.Grid.RowHeight{3}, 22);                       % window and electrodes row shown
verifyEqual(tc, d.CustomLabel.Text, 'Window (ms)');
verifyEqual(tc, d.update(), 0);                                 % nothing entered yet
d.WindowField.Value = '250 500'; d.Channels = {'pz', 'CPz'};
n = d.update();
verifyEqual(tc, n, 12);
o = d.options();
verifyEqual(tc, o.window, [0.25 0.5], 'AbsTol', 1e-12);
k = d.contract(o);
verifyEqual(tc, k.components.roi, {'Pz', 'CPz'});               % the dataset's own spelling
d.MeasureDrop.Value = 'band'; d.measureChanged();
verifyEqual(tc, d.CustomLabel.Text, 'Band (Hz)');
verifyEqual(tc, d.Channels, pipecompare.simple.Presets.eegChannels(EEG));   % all EEG channels, as the preset bands
d.WindowField.Value = '8 12';
verifyGreaterThan(tc, d.update(), 1);
k = d.contract(d.options());
verifyEqual(tc, k.bands.freq, [8 12]);
d.MeasureDrop.Value = 'custom'; d.measureChanged();
verifyEmpty(tc, d.Channels);                                    % a window starts with no electrodes
end

function testAdvancedTakesTheChoicesOrSaysWhyNot(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
d = pipecompare.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>
d.MeasureDrop.Value = 'alpha'; d.measureChanged();
verifyEqual(tc, char(d.AdvancedButton.Enable), 'off');          % the panel defines ERP measures only
d.EventList.Value = {'11', '31'}; d.MeasureDrop.Value = 'P3'; d.measureChanged();
verifyEqual(tc, char(d.AdvancedButton.Enable), 'on');
app = d.advanced(); ca = onCleanup(@() delete(app)); %#ok<NASGU>
verifyTrue(tc, ismember('ica', {app.Plan.Slots.id}));           % the Standard recipe
[~, noPz] = evalc('pop_select(EEG, ''rmchannel'', {''Pz''})');
d2 = pipecompare.gui.SimpleDialog(noPz); c2 = onCleanup(@() delete(d2)); %#ok<NASGU>
d2.EventList.Value = {'11'}; d2.MeasureDrop.Value = 'P3'; d2.measureChanged();
verifyEmpty(tc, d2.advanced());                                 % no empty panel: the reason is shown
verifyTrue(tc, isvalid(d2.Fig) && strcmp(char(d2.Fig.Visible), 'on'));  % and the dialog stays open
end

function testTooFewEventsAreFlaggedBeforeRun(tc)
EEG = tc.TestData.EEG;
is11 = find(arrayfun(@(e) strcmp(strtrim(char(string(e.type))), '11'), EEG.event));
F = EEG; F.event(is11(6:end)) = []; F.urevent = [];
d = pipecompare.gui.SimpleDialog(F); c = onCleanup(@() delete(d)); %#ok<NASGU>
d.EventList.Value = {'11'}; d.MeasureDrop.Value = 'P3'; d.RecipeDrop.Value = 'filters';
d.update();
verifyEqual(tc, char(d.RunButton.Enable), 'off');               % every pipeline would be excluded
verifyTrue(tc, startsWith(d.NotesLabel.Text, '11 has 5 events; each condition needs at least 10.'));
d.EventList.Value = {'11', '31'}; d.update();
verifyTrue(tc, contains(d.NotesLabel.Text, 'Score the selected event types as one condition'));
d.PoolBox.Value = true; d.update();
verifyEqual(tc, char(d.RunButton.Enable), 'on');                % 35 events in one condition
o = d.options();
verifyTrue(tc, o.pool);
end

function testPopFunctionFromAScript(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[out, com, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
verifyEqual(tc, out, EEG);                                      % the dataset is not modified
verifyEqual(tc, numel(r.cands), 12);
verifyEqual(tc, com, 'EEG = pop_pipecompare(EEG, ''measure'',''P3'',''events'',{''11'',''31''},''recipe'',''filters'');');
evalin('base', 'clear pipecompare_result');
evalc(com);                                                     % the command repeats the comparison
delete(findall(groot, 'Type', 'figure', 'Name', 'Pipeline comparison'));
verifyEqual(tc, evalin('base', 'pipecompare_result.labels'), r.labels);
verifyEqual(tc, evalin('base', 'pipecompare_result.labels'), r.labels);
[~, ~, rb] = pop_pipecompare(EEG, 'measure', 'alpha', 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, rb.ref.segmented);
[~, com] = pop_pipecompare(EEG, 'measure', 'custom', 'window', [0.25 0.5], 'channels', {'Pz'}, ...
    'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, startsWith(com, 'EEG = pop_pipecompare(EEG, ''measure'',''custom'',''window'',[0.25'));
verifyTrue(tc, contains(com, '''channels'',{''Pz''},''events'',{''11'',''31''}'));
other = EEG; other.data(1) = other.data(1) + 1;
verifyError(tc, @() pop_pipecompare(other, 'measure', 'P3', 'events', {'11'}, 'recipe', 'filters', 'show', 'off'), ...
    'PipeCompare:Simple');                                          % only the current dataset
end

function testResultsWindow(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[~, ~, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
w = pipecompare.gui.SimpleResults(r); c = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
verifyTrue(tc, startsWith(w.Headline.Text, sprintf('Use pipeline %d: high-pass ', r.ranking.recommended)));
verifyFalse(tc, contains(w.Headline.Text, 'cutoff='));          % the settings in words, not the internal key
verifyTrue(tc, startsWith(w.Table.Data{1, 6}, 'high-pass '));
verifyEqual(tc, size(w.Table.Data, 1), 5);
verifyEqual(tc, w.Table.Data{1, 1}, sprintf('%d*', r.ranking.recommended));   % always shown, first
f = [tempname '.m']; c2 = onCleanup(@() delete(f)); %#ok<NASGU>
w.saveScript(f);
verifyTrue(tc, isfile(f));
verifyTrue(tc, contains(fileread(f), 'pop_eegfiltnew'));
end

function testProgressReportsAndStopKeepsTheFinished(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11', '31'});
plan = pipecompare.simple.Presets.recipe('filters', pipecompare.live.DataState.fromEEG(EEG), c);
m = containers.Map({'n'}, {0});
r = pipecompare.PipeCompare.optimize(plan, c, struct('progress', @(n) countTo(m, n, 3)));
verifyEqual(tc, m('n'), 3);                                     % the 3 low-pass edges under the first high-pass
verifyEqual(tc, r.notRun, 12 - 3);
notRun = startsWith({r.cands.message}, 'not run');
verifyEqual(tc, sum(notRun), 9);
verifyTrue(tc, all(strcmp(r.ranking.table.status(notRun), 'failed')));
verifyNotEmpty(tc, r.ranking.recommended);                      % the finished ones are ranked
verifyEmpty(tc, r.options.progress);                            % the caller's callback is not kept
w = pipecompare.gui.SimpleResults(r); cw = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
verifyTrue(tc, startsWith(w.Headline.Text, 'Stopped after 3 of 12 pipelines'));
end

function stop = countTo(m, n, limit)
m('n') = m('n') + n;
stop = m('n') >= limit;
end
