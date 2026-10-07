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

function testEpochedDataKeepTheirEpochs(tc)
% Data epoched otherwise than the preset (here -100 to 600 ms) are used as
% they are when the epochs hold the measurement window.
EEG = tc.TestData.EEG;
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.1 0.6])');
c = pipecompare.simple.Presets.contract(Ep, 'P3', {'11', '31'});
verifyEqual(tc, c.epoch, [Ep.xmin Ep.xmax]);
verifyEqual(tc, c.baseline, [Ep.xmin 0]);                        % the preset baseline, from the epoch start
verifyEqual(tc, c.components.window, [0.3 Ep.xmax]);            % 0.596 s: pop_epoch leaves out the last sample
c.validate(pipecompare.live.DataState.fromEEG(Ep));
verifyError(tc, @() pipecompare.simple.Presets.contract(Ep, 'LRP', {'11'}), 'PipeCompare:Simple');   % baseline -800 to -600 ms
[~, Short] = evalc('pop_epoch(EEG, {''11''}, [-0.2 0.4])');
verifyError(tc, @() pipecompare.simple.Presets.contract(Short, 'P3', {'11'}), 'PipeCompare:Simple');  % ends before 600 ms
end

function testBandPowerFiltersStayOutsideTheBand(tc)
% A filter edge inside the band would cut what is measured: such edges are
% not compared, and the reason is given.
EEG = tc.TestData.EEG;
st = pipecompare.live.DataState.fromEEG(EEG);
[p, notes] = pipecompare.simple.Presets.recipe('filters', st, pipecompare.simple.Presets.contract(EEG, 'beta', {}));
verifyEqual(tc, p.Slots(strcmp({p.Slots.id}, 'lowpass')).alternatives{1}.params.cutoff, {30, 40});
verifyTrue(tc, any(contains(notes, 'low-pass 20 Hz (it would cut into the band, which ends at 30 Hz)')));
own = struct('window', [], 'band', [30 45], 'channels', {{}});
[p, notes] = pipecompare.simple.Presets.recipe('filters', st, pipecompare.simple.Presets.contract(EEG, 'band', {}, 2, false, own));
verifyFalse(tc, ismember('lowpass', {p.Slots.id}));
verifyTrue(tc, any(contains(notes, 'low-pass 20, 30, 40 Hz')));
p = pipecompare.simple.Presets.recipe('filters', st, pipecompare.simple.Presets.contract(EEG, 'P3', {'11'}));
verifyEqual(tc, p.Slots(strcmp({p.Slots.id}, 'lowpass')).alternatives{1}.params.cutoff, {20, 30, 40});   % ERP: unchanged
end

function testBandPowerStandardFixesTheFilters(tc)
% Outside the band a filter does not change its power: Standard uses the
% high-pass and low-pass edges nearest the band and compares ICLabel and
% epoch rejection only (9 pipelines instead of 108).
EEG = tc.TestData.EEG;
st = pipecompare.live.DataState.fromEEG(EEG);
[p, notes] = pipecompare.simple.Presets.recipe('standard', st, pipecompare.simple.Presets.contract(EEG, 'alpha', {}));
cut = @(id) p.Slots(strcmp({p.Slots.id}, id)).alternatives{1}.params.cutoff;
verifyEqual(tc, cut('highpass'), {1});
verifyEqual(tc, cut('lowpass'), {20});
verifyTrue(tc, any(contains(notes, 'low-pass 30, 40 Hz (band power')));
if exist('pop_iclabel', 'file') == 2
    verifyEqual(tc, numel(p.enumerate(st, pipecompare.simple.Presets.contract(EEG, 'alpha', {}), struct('maxLeaves', Inf))), 9);
end
p = pipecompare.simple.Presets.recipe('standard', st, pipecompare.simple.Presets.contract(EEG, 'beta', {}));
verifyEqual(tc, p.Slots(strcmp({p.Slots.id}, 'lowpass')).alternatives{1}.params.cutoff, {30});   % the nearest edge outside 13-30 Hz
p = pipecompare.simple.Presets.recipe('filters', st, pipecompare.simple.Presets.contract(EEG, 'alpha', {}));
verifyEqual(tc, p.Slots(strcmp({p.Slots.id}, 'lowpass')).alternatives{1}.params.cutoff, {20, 30, 40});   % Filters only compares them
end

function testLateralComponentsScoreContraMinusIpsi(tc)
% N2pc and LRP are measured contralateral minus ipsilateral (ERP CORE):
% one condition per side, each scored as the electrode contralateral to
% it minus the other.
EEG = tc.TestData.EEG;
c = pipecompare.simple.Presets.contract(EEG, 'N2pc', struct('left', {{'11'}}, 'right', {{'31'}}));
verifyEqual(tc, {c.conditions.name}, {'left target', 'right target'});
verifyEqual(tc, c.components.contra, {'PO8', 'PO7'});
c.validate(pipecompare.live.DataState.fromEEG(EEG));
verifyError(tc, @() pipecompare.simple.Presets.contract(EEG, 'N2pc', {'11', '31'}), 'PipeCompare:Simple');
l = pipecompare.simple.Presets.contract(EEG, 'LRP', struct('left', {{'11'}}, 'right', {{}}));
verifyEqual(tc, {l.conditions.name}, {'left hand'});
verifyEqual(tc, l.components.contra, {'C4'});
p3 = pipecompare.simple.Presets.contract(EEG, 'P3', {'11'});
verifyFalse(tc, p3.isLateral(1));
verifyFalse(tc, isfield(p3.components, 'contra'));               % identity unchanged
% a known lateral field: PO8 2 uV above PO7 in the window
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, c.epoch)');
times = Ep.xmin + (0:Ep.pnts-1) / Ep.srate;
w = times >= c.components.window(1) - 1e-9 & times <= c.components.window(2) + 1e-9;
Ep.data(:) = 0;
Ep.data(strcmp({Ep.chanlocs.labels}, 'PO8'), w, :) = 2;
T = pipecompare.eval.Measure.trials(Ep, c);
verifyEqual(tc, T.data{1}(T.cond == 1), repmat(2, sum(T.cond == 1), 1), 'AbsTol', 1e-6);    % target left: PO8 - PO7
verifyEqual(tc, T.data{1}(T.cond == 2), repmat(-2, sum(T.cond == 2), 1), 'AbsTol', 1e-6);   % target right: PO7 - PO8
end

function testNonEegChannelsByTypeOrName(tc)
% Channels such as VEOG are often named but not typed: both count.
EEG = tc.TestData.EEG;
verifyEqual(tc, pipecompare.simple.Presets.nonEegChannels(EEG), {'EOG1', 'EOG2'});   % no type set
E = EEG; E.chanlocs(strcmp({E.chanlocs.labels}, 'Fz')).type = 'ECG';
E.chanlocs(strcmp({E.chanlocs.labels}, 'F3')).labels = 'heog';
verifyEqual(tc, sort(pipecompare.simple.Presets.nonEegChannels(E)), sort({'Fz', 'heog', 'EOG1', 'EOG2'}));
verifyFalse(tc, any(ismember({'EOG1', 'EOG2'}, pipecompare.simple.Presets.eegChannels(EEG))));
C = E; C.chanlocs = C.chanlocs(:);                               % a column, as pop_biosig imports EDF files
verifyEqual(tc, sort(pipecompare.simple.Presets.nonEegChannels(C)), sort({'Fz', 'heog', 'EOG1', 'EOG2'}));
C.chanlocs(1).labels = 'POL EYEL';   % an EDF export's eye channel
verifyTrue(tc, ismember('POL EYEL', pipecompare.simple.Presets.nonEegChannels(C)));
end

function testEarAndMastoidChannelsAreNotScalp(tc)
% Ear and mastoid electrodes (A1, A2, M1, M2; POL prefix of EDF exports;
% any case) or channels typed REF are reference sites, left out like EOG;
% not the letters of a numbered cap (BioSemi A1-A32), not TP9/TP10, and
% not a channel deliberately typed EEG.
EEG = tc.TestData.EEG;
P = pipecompare.simple.Presets;
E = EEG; L = {E.chanlocs.labels};
E.chanlocs(strcmp(L, 'F3')).labels = 'A1';
E.chanlocs(strcmp(L, 'F4')).labels = 'POL A2';
E.chanlocs(strcmp(L, 'C3')).labels = 'm1';
E.chanlocs(strcmp(L, 'C4')).labels = 'TP9';
ex = P.nonEegChannels(E);
verifyTrue(tc, all(ismember({'A1', 'POL A2', 'm1', 'EOG1', 'EOG2'}, ex)), strjoin(ex, ' '));
verifyFalse(tc, ismember('TP9', ex));
verifyFalse(tc, any(ismember({'A1', 'POL A2', 'm1'}, P.eegChannels(E))));
B = E; B.chanlocs(strcmp(L, 'Cz')).labels = 'A3';                 % a numbered cap: A1 is scalp there
verifyFalse(tc, any(P.isRefSite(B.chanlocs)));
T = E; [T.chanlocs.type] = deal('');
T.chanlocs(strcmp(L, 'F3')).type = 'EEG';                        % typed EEG on purpose: scalp
T.chanlocs(strcmp(L, 'Pz')).type = 'REF';                        % typed REF: a reference site
verifyEqual(tc, {T.chanlocs(P.isRefSite(T.chanlocs)).labels}, {'POL A2', 'm1', 'Pz'});
[T.chanlocs.type] = deal('EEG');                                 % EEG on every channel: an importer's default
verifyTrue(tc, all(ismember({'A1', 'POL A2', 'm1'}, {T.chanlocs(P.isRefSite(T.chanlocs)).labels})));
% named in the dialog and the log; left out of the bad channels, the
% average and the epoch threshold
st = pipecompare.live.DataState.fromEEG(E);
verifyEqual(tc, st.refSites, {'A1', 'POL A2', 'm1'});
a = strjoin(P.dataAdvice(st), ' ');
verifyTrue(tc, contains(a, 'Ear/mastoid channels left out: A1, POL A2, m1'), a);
verifyFalse(tc, contains(strjoin(P.dataAdvice(pipecompare.live.DataState.fromEEG(EEG)), ' '), 'Ear/mastoid'));
c = P.contract(E, 'P3', {'11'});
p = P.recipe('standard', st, c, 'average', ex);
for k = [1 2 numel(p.Slots)]   % badchannels, reref, reject_threshold
    verifyTrue(tc, all(ismember({'A1', 'POL A2', 'm1'}, p.Slots(k).alternatives{1}.params.exclude)), p.Slots(k).id);
end
% data already referenced to linked ears: A1 and A2 near flat and mirrored,
% which a bad-channel test could flag; they are not tested and kept as they are
F = E; a1 = strcmp({F.chanlocs.labels}, 'A1'); a2 = strcmp({F.chanlocs.labels}, 'POL A2');
F.data(a1, :) = 0.01 * randn(1, F.pnts); F.data(a2, :) = -F.data(a1, :);
q = struct('measure', 'kurt+prob', 'threshold', 5, 'exclude', {P.nonEegChannels(F)}, 'detectHighpass', 1, 'action', 'interpolate');
[G, ~, info] = pipecompare.run.Steps.badChannels(F, q, struct('highpass', 0));
verifyFalse(tc, any(ismember({'A1', 'POL A2', 'm1'}, info.badChannels)));
verifyEqual(tc, G.data(a1 | a2, :), F.data(a1 | a2, :));
% removed before PipeCompare: not interpolated back for the average
R = pop_select(E, 'rmchannel', {'A1'});
verifyEmpty(tc, pipecompare.live.DataState.fromEEG(R).restorableChannels);
end

function testDetectableDifferenceIsSaid(tc)
% The smallest difference these data can show: 2.8 x the standard error of
% the difference (80% power, two-sided alpha .05), from the recommended
% pipeline's own SME; with several conditions the pair with the largest
% error, with one condition its value against 0.
P = pipecompare.simple.Presets;
o = struct('name', 'P3.mean', 'unit', 'uV', 'sme', [3 4 4], 'estimate', [5 6 7]);
r.ranking.byStratum = struct('recommended', 2);
r.cands = struct('m', {[], struct('objectives', o)});
t = P.detectableText(r);                                         % 2.8 * sqrt(4^2 + 4^2) = 15.8
verifyTrue(tc, contains(t, 'two conditions must differ in P3 by about 16 uV'), t);
verifyTrue(tc, contains(t, 'largest difference seen here (2 uV) is smaller') && contains(t, 'more trials'), t);
o.estimate = [5 30 7];                                           % a difference the data can show
r.cands(2).m.objectives = o;
verifyFalse(tc, contains(P.detectableText(r), 'smaller than that'));
b = struct('name', 'alpha.logpower', 'unit', 'log10(uV^2)', 'sme', 0.05, 'estimate', 1.2);
r.cands(2).m.objectives = b;                                     % one condition: against 0
t = P.detectableText(r);
verifyTrue(tc, contains(t, 'alpha must differ from 0 by about 0.14 log10(uV^2)') && ~contains(t, 'smaller than that'), t);
r.ranking.byStratum = struct('recommended', {});                 % nothing recommended: nothing said
verifyEmpty(tc, P.detectableText(r));
end

function testStepsInWords(tc)
% What a pipeline did, in order, with its decisions on the data.
P = pipecompare.simple.Presets;
f = @(type, params, varargin) struct('type', type, 'params', params, 'interpolated', {{}}, 'removed', {{}}, ...
    'icsRemoved', NaN, 'icsTotal', NaN, 'rejected', NaN, 'epochsBefore', NaN);
s1 = f('badchannels', struct('measure', 'kurt+prob', 'threshold', 5, 'exclude', {{'EOG1'}}, 'detectHighpass', 1, 'action', 'interpolate'));
s1.interpolated = {'O1', 'O2'};
s2 = f('reref', struct('mode', 'average', 'channels', {{}}, 'exclude', {{'EOG1'}}));
s3 = f('ica', struct('fitHighpass', 1, 'extended', 1));
s4 = f('icremove', struct('threshold', 0.8, 'classes', {{'Eye', 'Muscle'}})); s4.icsRemoved = 3; s4.icsTotal = 30;
s5 = f('epoch', struct());
s6 = f('reject_threshold', struct('uv', 150, 'exclude', {{}})); s6.rejected = 5; s6.epochsBefore = 60;
r.contract = P.contract(tc.TestData.EEG, 'P3', {'11', '31'});
r.ref = struct('names', {{'11', '31'}}, 'n', [30 30]);
r.cands = struct('steps', {{s1, s2, s3, s4, s5, s6}}, 'm', struct('kept', [28 27]));
L = P.stepsText(r, 1);
verifyEqual(tc, L{1}, ['1. Bad channels (kurtosis or joint probability over 5 SD, found on a 1 Hz high-passed copy): ', ...
    'O1, O2 interpolated (not tested: EOG1)']);
verifyEqual(tc, L{2}, '2. Average reference (left out: EOG1)');
verifyTrue(tc, startsWith(L{3}, '3. ICA (extended runica), fitted on a 1 Hz high-passed copy'));
verifyEqual(tc, L{4}, '4. ICLabel: 3 of 30 components removed (Eye, Muscle with probability 0.8 or more)');
verifyEqual(tc, L{5}, '5. Epochs -200 to 800 ms around event type(s) 11, 31');
verifyEqual(tc, L{6}, '6. Epochs beyond +/-150 uV on any channel rejected: 5 of 60');
verifyEqual(tc, L{7}, 'Trials kept per condition: 11: 28 of 30; 31: 27 of 30');
s1.interpolated = {}; r.cands.steps = {s1};
L = P.stepsText(r, 1);
verifyTrue(tc, contains(L{1}, 'none found'), L{1});
end

function testNextStepWhenRejectionRemovesTooMuch(tc)
% Every pipeline lost too many epochs and the data keep their recorded
% reference: the average reference is suggested.
r.ranking = struct('byStratum', [], 'whyList', {{{'retention 0% (every epoch would be rejected)'}; {'retention 3% (< 50%)'}}});
r.leaves = struct('path', {{struct('type', 'highpass')}});
r.state = struct('reference', 'common');
verifyTrue(tc, contains(pipecompare.simple.Presets.nextStep(r), 'average reference'));
r.leaves = struct('path', {{struct('type', 'reref'), struct('type', 'highpass')}});
verifyEmpty(tc, pipecompare.simple.Presets.nextStep(r));        % already re-referenced
r.leaves = struct('path', {{struct('type', 'highpass')}});
r.state.reference = 'averef';                                   % what pop_averef writes
verifyEmpty(tc, pipecompare.simple.Presets.nextStep(r));        % already average
r.state.reference = 'common';
r.ranking.whyList = {{'signal: amplitude changed by 17%'}; {'signal: amplitude changed by 20%'}};
verifyEmpty(tc, pipecompare.simple.Presets.nextStep(r));        % excluded for another reason
% the channels most often over the limit are named (likely bad channels
% the detection missed), summed over the pipelines; rare ones are not
r.ranking.whyList = {{'retention 20% (< 50%)'}; {'retention 30% (< 50%)'}};
r.leaves = struct('path', {{struct('type', 'reref')}});
r.cands = struct('overLimit', {struct('labels', {{'O1', 'O2', 'Fz'}}, 'counts', [40 30 2]), ...
    struct('labels', {{'O1', 'T7'}}, 'counts', [20 8])});
t = pipecompare.simple.Presets.nextStep(r);
verifyTrue(tc, contains(t, 'O1 (60%), O2 (30%)'), t);
verifyFalse(tc, contains(t, 'Fz') || contains(t, 'T7') || contains(t, 'average reference'), t);
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
% the average reference: fixed, after the bad channels (a bad channel
% would spread into every channel) and before ICA
p = pipecompare.simple.Presets.recipe('standard', st, c, 'average', {'VEOG'});
verifyEqual(tc, ids(p), {'badchannels', 'reref', 'ica', 'highpass', 'lowpass', 'icremove', 'epoch', 'baseline', 'reject_threshold'});
verifyEqual(tc, p.Slots(2).alternatives{1}.params.exclude, {'VEOG'});   % non-EEG channels left out of the average
verifyEqual(tc, p.Slots(1).alternatives{1}.params.exclude, {'VEOG'});   % nor tested for bad channels
verifyEqual(tc, p.Slots(end).alternatives{1}.params.exclude, {'VEOG'}); % nor for the epoch threshold
verifyEqual(tc, p.Slots(1).alternatives{1}.params.detectHighpass, 1);  % bad channels found on a 1 Hz high-passed copy
verifyEqual(tc, p.Slots(1).alternatives{1}.params.measure, 'kurt+prob');  % spiky or noisy
% in Filters only too: the bad channels are interpolated before the average
p = pipecompare.simple.Presets.recipe('filters', st, c, 'average');
verifyEqual(tc, ids(p), {'badchannels', 'reref', 'highpass', 'lowpass', 'epoch', 'baseline'});
% data already average-referenced: averaged again after the interpolation,
% which removes a bad channel's share of the earlier average
avg = st; avg.reference = 'average';
verifyEqual(tc, ids(pipecompare.simple.Presets.recipe('standard', avg, c)), ...
    {'badchannels', 'reref', 'ica', 'highpass', 'lowpass', 'icremove', 'epoch', 'baseline', 'reject_threshold'});
verifyEqual(tc, ids(pipecompare.simple.Presets.recipe('filters', avg, c)), ...
    {'badchannels', 'reref', 'highpass', 'lowpass', 'epoch', 'baseline'});
noloc = st; noloc.nLocated = 0;
[p, notes] = pipecompare.simple.Presets.recipe('standard', noloc, c);
verifyFalse(tc, any(ismember({'badchannels', 'ica', 'icremove'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'no channel locations')));
[p, notes] = pipecompare.simple.Presets.recipe('filters', noloc, c, 'average');
verifyEqual(tc, ids(p), {'reref', 'highpass', 'lowpass', 'epoch', 'baseline'});
verifyTrue(tc, any(contains(notes, 'a bad channel spreads into every channel')));
[~, Ep] = evalc('pop_epoch(EEG, {''11''}, [-0.2 0.8])');
[p, notes] = pipecompare.simple.Presets.recipe('standard', pipecompare.live.DataState.fromEEG(Ep), c);
verifyFalse(tc, any(ismember({'highpass', 'lowpass', 'epoch'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'already epoched')));
verifyEqual(tc, p.Slots(1).alternatives{1}.params.detectHighpass, 0);  % no high-pass on short epochs
verifyError(tc, @() pipecompare.simple.Presets.recipe('full', st, c), 'PipeCompare:Simple');   % ASR: panel or script
% ICA already run and components removed (history): not compared again
done = st; done.process = struct('step', {'highpass', 'ica', 'icremove'});
[p, notes] = pipecompare.simple.Presets.recipe('standard', done, c);
verifyFalse(tc, any(ismember({'ica', 'icremove'}, ids(p))));
verifyTrue(tc, any(contains(notes, 'ICA was already run')));
% filter edges the data already have are not compared: they would leave
% the data unchanged but filter the known signal; keeping the data's own
% filter (no further filter) is compared with the stricter edges
H = EEG; H.history = sprintf('%s\nEEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''plotfreqz'',0);', EEG.history);
[p, notes] = pipecompare.simple.Presets.recipe('filters', pipecompare.live.DataState.fromEEG(H), c);
verifyEqual(tc, p.Slots(1).alternatives{1}.params.cutoff, {1});
verifyEqual(tc, p.Slots(1).alternatives{2}.type, 'none');
verifyEqual(tc, numel(p.Slots(2).alternatives), 1);                  % no low-pass in the data: one is always applied
verifyTrue(tc, any(contains(notes, 'high-pass 0.1, 0.3, 0.5 Hz (the data are already high-pass-filtered at 0.5 Hz)')));
end

function testChannelsRemovedBeforeAreRestoredForTheAverage(tc)
% EEG channels removed before PipeCompare are interpolated back before an
% average reference (an average over fewer channels is another reference);
% non-EEG channels (e.g. VEOG) are never interpolated from the scalp.
EEG = tc.TestData.EEG;
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11'});
ids = @(p) {p.Slots.id};
R = pop_select(EEG, 'rmchannel', {'O1', 'O2'});
st = pipecompare.live.DataState.fromEEG(R);
verifyTrue(tc, all(ismember({'O1', 'O2'}, st.removedChannels(st.restorableChannels))));
verifyEqual(tc, ids(pipecompare.simple.Presets.recipe('standard', st, c, 'average')), ...
    {'restore', 'badchannels', 'reref', 'ica', 'highpass', 'lowpass', 'icremove', 'epoch', 'baseline', 'reject_threshold'});
verifyFalse(tc, ismember('restore', ids(pipecompare.simple.Presets.recipe('standard', st, c))));   % as recorded
V = EEG; V.chanlocs(1).labels = 'VEOG';
V = pop_select(V, 'rmchannel', {'VEOG'});
verifyEmpty(tc, pipecompare.live.DataState.fromEEG(V).restorableChannels);
end

function testDataAdviceSaysWhereToStart(tc)
% The dialog says where PipeCompare starts, what was done before it, and
% that Standard fits an ICA in the data again.
EEG = tc.TestData.EEG;
a = pipecompare.simple.Presets.dataAdvice(pipecompare.live.DataState.fromEEG(EEG));
verifyTrue(tc, startsWith(a{1}, 'Start from the raw continuous data'), a{1});
H = EEG; H.history = sprintf(['%s\nEEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''plotfreqz'',0);', ...
    '\nEEG = pop_reref(EEG, []);'], EEG.history);
a = pipecompare.simple.Presets.dataAdvice(pipecompare.live.DataState.fromEEG(H));
verifyTrue(tc, contains(a{1}, 'Already done to these data: filtered, re-referenced'), a{1});
st = pipecompare.live.DataState.fromEEG(EEG);
st.ica.present = true; st.ica.flagged = [1 2];
a = strjoin(pipecompare.simple.Presets.dataAdvice(st), ' ');
verifyTrue(tc, contains(a, 'Standard fits ICA again') && contains(a, 'the 2 component(s) marked') && ...
    contains(a, 'choose Filters only'), a);
end

function testFiltersBeforePipeCompareAreChecked(tc)
% Filters applied before PipeCompare are outside the pipelines' signal
% check; the same known signal is filtered at the history's edges and a
% loss beyond a pipeline's limit is said.
EEG = tc.TestData.EEG;
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11'});
verifyEmpty(tc, pipecompare.eval.Injection.priorFilters(EEG, c, pipecompare.live.DataState.fromEEG(EEG)));
H = EEG; H.history = sprintf('%s\nEEG = pop_eegfiltnew(EEG, ''locutoff'',2,''plotfreqz'',0);', EEG.history);
r = pipecompare.eval.Injection.priorFilters(H, c, pipecompare.live.DataState.fromEEG(H));
verifyEqual(tc, r.highpass, 2); verifyEmpty(tc, r.lowpass);
verifyGreaterThan(tc, r.signal.amplitudeError, 0.1);            % a 2 Hz high-pass shrinks a P3
t = pipecompare.simple.Presets.priorFilterText(struct('priorFilters', r, 'options', struct()));
verifyTrue(tc, contains(t, 'high-pass 2 Hz') && contains(t, 'start from the unfiltered data'), t);
L = EEG; L.history = sprintf('%s\nEEG = pop_eegfiltnew(EEG, ''hicutoff'',30,''plotfreqz'',0);', EEG.history);
r = pipecompare.eval.Injection.priorFilters(L, c, pipecompare.live.DataState.fromEEG(L));
verifyLessThan(tc, r.signal.amplitudeError, 0.1);               % a 30 Hz low-pass leaves it
verifyEmpty(tc, pipecompare.simple.Presets.priorFilterText(struct('priorFilters', r, 'options', struct())));
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
verifyEqual(tc, d.RefDrop.Value, 'asis');                       % the reference as recorded unless chosen
d.RefDrop.Value = 'average';
verifyEqual(tc, d.update(), 4 * 3 * 3 * 3);                     % fixed: no more pipelines
o = d.options();
verifyEqual(tc, o.reference, 'average');
d.RefDrop.Value = 'asis';
d.RecipeDrop.Value = 'filters';
[n, msg] = d.update();
verifyEqual(tc, n, 12);                                         % 4 high-pass x 3 low-pass edges
verifyTrue(tc, startsWith(msg, '12 pipelines'));
d.MeasureDrop.Value = 'alpha'; d.measureChanged();
verifyEqual(tc, char(d.EventList.Enable), 'off');               % band power needs no events
o = d.options();
verifyEmpty(tc, o.events);
d.RecipeDrop.Value = 'standard';
verifyEqual(tc, d.update(), 3 * 3);                             % band power: one high-pass, one low-pass
d.MeasureDrop.Value = 'N2pc'; d.measureChanged();
verifyEqual(tc, d.EventGrid.ColumnWidth{2}, '1x');              % one list per side
verifyEqual(tc, char(d.PoolBox.Enable), 'off');
d.EventList.Value = {'11'}; d.RightList.Value = {'31'}; d.RecipeDrop.Value = 'filters';
verifyEqual(tc, d.update(), 12);
o = d.options();
verifyEqual(tc, [o.left o.right], {'11', '31'});
verifyEmpty(tc, o.events);
d.MeasureDrop.Value = 'P3'; d.measureChanged();
verifyEqual(tc, d.EventGrid.ColumnWidth{2}, 0);
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
d.WindowField.Value = '250 500'; d.Channels = {'pz', 'Cz'};
n = d.update();
verifyEqual(tc, n, 12);
o = d.options();
verifyEqual(tc, o.window, [0.25 0.5], 'AbsTol', 1e-12);
k = d.contract(o);
verifyEqual(tc, k.components.roi, {'Pz', 'Cz'});               % the dataset's own spelling
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
d.MeasureDrop.Value = 'N2pc'; d.measureChanged();
d.EventList.Value = {'11'}; d.RightList.Value = {'31'};
appL = d.advanced(); cl = onCleanup(@() delete(appL)); %#ok<NASGU>
verifyTrue(tc, endsWith(appL.CompField.Value, '# contra PO8 PO7'));   % contralateral minus ipsilateral
k = appL.contract();
verifyEqual(tc, {k.conditions.name}, {'left target', 'right target'});
verifyTrue(tc, k.isLateral(1));
d = pipecompare.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>
d.MeasureDrop.Value = 'alpha'; d.measureChanged();
verifyEqual(tc, char(d.AdvancedButton.Enable), 'on');           % band power: the panel takes it
appB = d.advanced(); cb = onCleanup(@() delete(appB)); %#ok<NASGU>
verifyEqual(tc, appB.AnalysisDrop.Value, 'bandpower');
verifyTrue(tc, startsWith(appB.BandField.Value, 'alpha: 8 13 @ '));
k = appB.contract();
verifyTrue(tc, k.isSegmented()); verifyEqual(tc, k.segment, 2);
verifyEqual(tc, k.bands.roi, pipecompare.simple.Presets.eegChannels(EEG));
verifyTrue(tc, ismember('epoch', {appB.Plan.Slots.id}));
d = pipecompare.gui.SimpleDialog(EEG); c = onCleanup(@() delete(d)); %#ok<NASGU>   % (advanced closed the first)
d.EventList.Value = {'11', '31'}; d.MeasureDrop.Value = 'P3'; d.measureChanged();
verifyEqual(tc, char(d.AdvancedButton.Enable), 'on');
app = d.advanced(); ca = onCleanup(@() delete(app)); %#ok<NASGU>
verifyTrue(tc, ismember('ica', {app.Plan.Slots.id}));           % the Standard recipe
plan = app.PlanTable.Data(:, 3);                                % the epoch row shows the epoch set above it
verifyFalse(tc, any(cellfun(@(s) contains(char(s), 'not set yet'), plan)));
verifyTrue(tc, any(cellfun(@(s) contains(char(s), sprintf('window [%s] s', app.EpochField.Value)), plan)));
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
logText = fileread(fullfile(tempdir, 'pipecompare_last_run.log'));   % what the Command Window showed as it ran
verifyTrue(tc, contains(logText, 'pop_eegfiltnew'));            % every command
verifyTrue(tc, contains(logText, 'candidate 12'));              % every pipeline
verifyFalse(tc, contains(logText, 'pipelines compared'));       % not the summary after it
verifyEqual(tc, char(get(0, 'Diary')), 'off');                  % the diary is off again
verifyEqual(tc, out, EEG);                                      % the dataset is not modified
verifyEqual(tc, numel(r.cands), 12);
verifyEqual(tc, com, ['EEG = pop_pipecompare(EEG, ''measure'',''P3'',''events'',{''11'',''31''},''recipe'',''filters'',', ...
    '''show'',''off'');']);                                      % 'show','off' is repeated too
evalin('base', 'clear pipecompare_result');
nFig = numel(findall(groot, 'Type', 'figure'));
evalc(com);                                                     % the command repeats the comparison
verifyEqual(tc, numel(findall(groot, 'Type', 'figure')), nFig); % without opening windows
verifyEqual(tc, evalin('base', 'pipecompare_result.labels'), r.labels);
verifyEqual(tc, evalin('base', 'pipecompare_result.labels'), r.labels);
[~, ~, rb] = pop_pipecompare(EEG, 'measure', 'alpha', 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, rb.ref.segmented);
[~, com] = pop_pipecompare(EEG, 'measure', 'custom', 'window', [0.25 0.5], 'channels', {'Pz'}, ...
    'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, startsWith(com, 'EEG = pop_pipecompare(EEG, ''measure'',''custom'',''window'',[0.25'));
verifyTrue(tc, contains(com, '''channels'',{''Pz''},''events'',{''11'',''31''}'));
[~, ~, rn] = pop_pipecompare(EEG, 'measure', 'P3', 'events', [11 31], 'recipe', 'filters', 'show', 'off');
verifyEqual(tc, {rn.contract.conditions.name}, {'11', '31'});    % numeric event types
[~, com, rl] = pop_pipecompare(EEG, 'measure', 'N2pc', 'left', {'11'}, 'right', 31, 'recipe', 'filters', 'show', 'off');
verifyTrue(tc, contains(com, '''measure'',''N2pc'',''left'',{''11''},''right'',{''31''},'));
verifyTrue(tc, rl.contract.isLateral(1));
ok = strcmp({rl.cands.status}, 'ok');
verifyNotEmpty(tc, find(ok));
verifyTrue(tc, all(arrayfun(@(k) abs(rl.cands(k).signal.gain - 1) < 0.5, find(ok))));   % the lateral signal check
verifyError(tc, @() pop_pipecompare(EEG, 'measure', 'N2pc', 'events', {'11'}, 'show', 'off'), 'PipeCompare:Simple');
% an error during the search: the log so far is still written
is11 = find(arrayfun(@(e) strcmp(strtrim(char(string(e.type))), '11'), EEG.event));
F = EEG; F.event(is11(2:end)) = []; F.urevent = []; F = eeg_checkset(F, 'makeur');
nqc_setBase(F);
delete(fullfile(tempdir, 'pipecompare_last_run.log'));
verifyError(tc, @() pop_pipecompare(F, 'measure', 'P3', 'events', {'11'}, 'recipe', 'filters', 'show', 'off'), ...
    'PipeCompare:Contract');                                        % one trial of 11
verifyTrue(tc, contains(fileread(fullfile(tempdir, 'pipecompare_last_run.log')), 'Exhaustive search'));
nqc_setBase(EEG);
other = EEG; other.data(1) = other.data(1) + 1;
verifyError(tc, @() pop_pipecompare(other, 'measure', 'P3', 'events', {'11'}, 'recipe', 'filters', 'show', 'off'), ...
    'PipeCompare:Simple');                                          % only the current dataset
% epoched data: band power and the filters say why before any search
[~, Ep] = evalc('pop_epoch(EEG, {''11'', ''31''}, [-0.2 0.8])');
nqc_setBase(Ep);
try
    pop_pipecompare(Ep, 'measure', 'alpha', 'show', 'off'); verifyFail(tc, 'band power on epoched data ran');
catch ME
    verifyTrue(tc, contains(ME.message, 'already cut into epochs'), ME.message);
end
try
    pop_pipecompare(Ep, 'measure', 'P3', 'events', {'11'}, 'recipe', 'filters', 'show', 'off'); verifyFail(tc, 'one pipeline ran');
catch ME
    verifyTrue(tc, contains(ME.message, 'nothing to compare') && contains(ME.message, 'already epoched'), ME.message);
end
nqc_setBase(EEG);
end

function testResultsWindow(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[~, ~, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
w = pipecompare.gui.SimpleResults(r); c = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
verifyTrue(tc, startsWith(w.Headline.Text, sprintf('Use pipeline %d: high-pass ', r.ranking.recommended)));
verifyFalse(tc, contains(w.Headline.Text, 'cutoff='));          % the settings in words, not the internal key
verifyTrue(tc, contains(w.Headline.Text, 'to be told apart'), w.Headline.Text);   % how large a difference shows
s = strjoin(w.Steps.Value, ' ');                                % the recommended pipeline, step by step
verifyTrue(tc, startsWith(s, sprintf('Pipeline %d, step by step: 1. High-pass filter', r.ranking.recommended)), s);
verifyTrue(tc, contains(s, 'Epochs -200 to 800 ms around event type(s) 11, 31') && contains(s, 'Trials kept per condition: 11: '), s);
verifyTrue(tc, startsWith(w.Table.Data{1, 6}, 'high-pass '));
verifyEqual(tc, size(w.Table.Data, 1), 5);
verifyEqual(tc, w.Table.Data{1, 1}, sprintf('%d*', r.ranking.recommended));   % always shown, first
w.AllBox.Value = true; w.showRows();
verifyEqual(tc, size(w.Table.Data), [12 7]);                   % every pipeline, with why it was excluded
i = find(strcmp(w.Table.Data(:, 2), 'passed') & ~endsWith(w.Table.Data(:, 1), '*'), 1);
w.Table.Selection = [i 1]; k = str2double(w.Table.Data{i, 1});
w.adopt();
verifyEqual(tc, evalin('base', 'EEG.setname'), sprintf('%s PipeCompare#%d', EEG.setname, k));   % the selected one
f = [tempname '.m']; c2 = onCleanup(@() delete(f)); %#ok<NASGU>
w.saveScript(f);
verifyTrue(tc, isfile(f));
verifyTrue(tc, contains(fileread(f), 'pop_eegfiltnew'));
end

function testSkippedStepIsNamed(tc)
% NQC-027: a step some pipelines skip was missing from their names, so a
% pipeline with the step and one without it could read the same.
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11', '31'});
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.setSkippable('highpass', true);
p = p.add('lowpass', 'cutoff', {30, 40}); p = p.add('epoch'); p = p.add('baseline');
r = pipecompare.PipeCompare.optimize(p, c);
w = pipecompare.gui.SimpleResults(r); cw = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
names = arrayfun(@(k) w.name(k), 1:numel(r.cands), 'UniformOutput', false);
verifyEqual(tc, numel(unique(names)), 4);
verifyEqual(tc, sum(contains(names, 'high-pass 0.5 Hz')), 2);
verifyEqual(tc, sum(contains(names, 'no high-pass')), 2);
verifyFalse(tc, contains(w.shared(), 'high-pass'));             % not a step every pipeline has
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

function testProgressIsToldEachStep(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
c = pipecompare.simple.Presets.contract(EEG, 'P3', {'11', '31'});
plan = pipecompare.simple.Presets.recipe('filters', pipecompare.live.DataState.fromEEG(EEG), c);
m = containers.Map({'types'}, {{}});
r = pipecompare.PipeCompare.optimize(plan, c, struct('progress', @(n, varargin) noteStep(m, varargin{:})));
verifyTrue(tc, any(strcmp(m('types'), 'highpass')));          % a callback of two arguments hears of each step
verifyTrue(tc, any(strcmp(m('types'), 'lowpass')));
verifyEqual(tc, r.notRun, 0);
end

function testProgressWindowShowsTheStepAndTheTime(tc)
p = pipecompare.gui.Progress(10, true); c = onCleanup(@() delete(p)); %#ok<NASGU>
verifyEqual(tc, char(p.Dlg.Indeterminate), 'on');               % moving, with no fill level before the first pipeline
verifyFalse(tc, p.step(0, struct('type', 'ica', 'params', struct(), 'label', 'ica')));
msg = @() strjoin(cellstr(p.Dlg.Message), ' ');
verifyTrue(tc, contains(msg(), 'Now: fitting ICA'));
t1 = regexp(msg(), 'Time so far: [^.]*', 'match', 'once');
pause(2.5);                                                     % the time moves while a step runs
verifyNotEqual(tc, regexp(msg(), 'Time so far: [^.]*', 'match', 'once'), t1);
verifyFalse(tc, p.step(1));
verifyEqual(tc, char(p.Dlg.Indeterminate), 'off');
verifyEqual(tc, p.Dlg.Value, 0.1, 'AbsTol', 1e-12);
delete(p);
verifyEmpty(tc, timerfind('Name', 'PipeCompare progress'));     % its clock is gone with it
end

function testProgressWindowStopsWhenClosed(tc)
p = pipecompare.gui.Progress(10, false); c = onCleanup(@() delete(p)); %#ok<NASGU>
verifyFalse(tc, p.step(0));
verifyFalse(tc, p.step(3));
verifyEqual(tc, p.Dlg.Value, 0.3, 'AbsTol', 1e-12);
delete(p.Fig);                                                  % closing the window stops the search
verifyTrue(tc, p.step(1));
end

function testExcludedPipelineIsUsedOnlyAfterConfirmation(tc)
EEG = tc.TestData.EEG;
nqc_setBase(EEG);
[~, ~, r] = pop_pipecompare(EEG, 'measure', 'P3', 'events', {'11', '31'}, 'recipe', 'filters', 'show', 'off');
k = find(~strcmp(r.ranking.table.status, 'feasible'), 1);
if isempty(k)                                                   % every pipeline passed here: exclude one
    k = find(r.ranking.order ~= r.ranking.recommended, 1);
    k = r.ranking.order(k);
    r.ranking.table.status{k} = 'rejected'; r.ranking.table.reason{k} = 'for this test';
end
w = pipecompare.gui.SimpleResults(r); c = onCleanup(@() delete(w.Fig)); %#ok<NASGU>
w.AllBox.Value = true; w.showRows();
w.Table.Selection = [find(strcmp(strrep(w.Table.Data(:, 1), '*', ''), sprintf('%d', k))) 1];
f = [tempname '.m']; cf = onCleanup(@() delete([f '*'])); %#ok<NASGU>
w.saveScript(f, 'Cancel');
verifyFalse(tc, isfile(f));                                     % Save script asks as well
w.saveScript(f, 'Save anyway');
verifyTrue(tc, isfile(f));
n0 = evalin('base', 'numel(ALLEEG)');
w.adopt('Cancel');
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), n0);           % nothing stored
w.adopt('Use anyway');
verifyEqual(tc, evalin('base', 'EEG.setname'), sprintf('%s PipeCompare#%d', EEG.setname, k));
nqc_setBase(EEG);
end

function stop = noteStep(m, in)
if nargin > 1, m('types') = [m('types') {in.type}]; end
stop = false;
end

function stop = countTo(m, n, limit)
m('n') = m('n') + n;
stop = m('n') >= limit;
end
