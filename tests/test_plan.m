function tests = test_plan
%TEST_PLAN Search-space construction: fixed vs searched, order, legality,
%   strata, sampling, exhaustiveness against an independent brute force.
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
end

function testPlanFixedAndSearched(tc)
st = nqc_fakeState(false, 500);
c = nqc_contract();
p = pipecompare.plan.Plan();
p = p.add('highpass');                       % unfixed -> 4 suggestions
p = p.add('lowpass', 'cutoff', 30);          % fixed
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {75 150});
[leaves, tree, rep] = p.enumerate(st, c);
verifyEqual(tc, numel(leaves), 4 * 2);
% prefix sharing: 4 HP + 4 LP + 4 epoch + 4 baseline + 8 reject = 24 nodes
verifyEqual(tc, rep.nNodes, 24);
verifyEqual(tc, rep.nStepsUnshared, 8 * 5);
verifyEqual(tc, numel(tree), 25);
verifyEqual(tc, sort({rep.searched.param}), {'cutoff','uv'});
end

function testPlanLegality(tc)
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('baseline'); p = p.add('epoch');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), c), 'PipeCompare:NoLegalPipeline');
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1);
verifyError(tc, @() p.enumerate(nqc_fakeState(true, 500), c), 'PipeCompare:NoLegalPipeline'); % already epoched
p = pipecompare.plan.Plan(); p = p.add('icremove');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), c), 'PipeCompare:NoLegalPipeline'); % no ICA
end

function testMissingPluginFailsAtPlanTime(tc)
d = fileparts(which('pop_clean_rawdata'));
assumeNotEmpty(tc, d, 'clean_rawdata plugin not installed');
old = path; rmpath(d); restore = onCleanup(@() path(old));
p = pipecompare.plan.Plan(); p = p.add('asr');
try
    p.enumerate(nqc_fakeState(false, 500), nqc_contract());
    verifyFail(tc, 'a plan with ASR and no clean_rawdata enumerated');
catch err
    verifyEqual(tc, err.identifier, 'PipeCompare:NoLegalPipeline');
    verifySubstring(tc, err.message, 'clean_rawdata plugin');
end
end

function testAsrWithoutSignalToolboxFailsAtPlanTime(tc)
% clean_rawdata returns the data unchanged when ASR has no filter for the
% rate, so the plan refuses ASR there instead of comparing a no-op.
assumeTrue(tc, exist('pop_clean_rawdata', 'file') == 2, 'clean_rawdata plugin not installed');
old = path; restore = onCleanup(@() path(old));
d = fileparts(which('yulewalk'));
if ~isempty(d), rmpath(d); end
p = pipecompare.plan.Plan(); p = p.add('asr');
verifyNotEmpty(tc, p.enumerate(nqc_fakeState(false, 500), nqc_contract()));   % filter precomputed for 500 Hz
try
    p.enumerate(nqc_fakeState(false, 250), nqc_contract());
    verifyFail(tc, 'a plan with ASR at 250 Hz and no yulewalk enumerated');
catch err
    verifyEqual(tc, err.identifier, 'PipeCompare:NoLegalPipeline');
    verifySubstring(tc, err.message, 'Signal Processing Toolbox');
end
% the same for clean_rawdata added as an EEGLAB command, unless its ASR is off
asr = 'EEG = pop_clean_rawdata(EEG, ''FlatlineCriterion'',''off'',''ChannelCriterion'',''off'',''LineNoiseCriterion'',''off'',''Highpass'',''off'',''BurstCriterion'',%s,''WindowCriterion'',''off'',''BurstRejection'',''off'',''Distance'',''Euclidian'');';
p = pipecompare.plan.Plan(); p = p.addNative(sprintf(asr, '20'));
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 250), nqc_contract()), 'PipeCompare:NoLegalPipeline');
p = pipecompare.plan.Plan(); p = p.addNative(sprintf(asr, '''off'''));
verifyNotEmpty(tc, p.enumerate(nqc_fakeState(false, 250), nqc_contract()));
end

function testOrderSearchWithPinAndBefore(tc)
c = nqc_contract();
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('linenoise'); p = p.add('epoch'); p = p.add('baseline');
p.OrderMode = 'search';
p = p.pin('epoch'); p = p.pin('baseline');
leaves = p.enumerate(nqc_fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 6); % 3! orders of the filters, epoch/baseline pinned
p = p.before('highpass', 'lowpass');
leaves = p.enumerate(nqc_fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 3);
end

function testChoiceWithNone(tc)
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('epoch');
p = p.addChoice('reject', {'reject_threshold', 'uv', 100}, {'reject_jointprob', 'sd', 4}, 'none');
leaves = p.enumerate(nqc_fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 3);
end

function testSearchBudgetRefusesSilently(tc)
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', num2cell(0.1:0.1:2));
p = p.add('lowpass', 'cutoff', num2cell(20:1:45));
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), nqc_contract(), struct('maxLeaves', 100)), 'PipeCompare:SearchTooLarge');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), nqc_contract(), struct('maxLeaves', 1e6, 'maxVisits', 50)), 'PipeCompare:SearchTooLarge');
end

% -------------------------------------------------------------- statistics

function testEnumerationEqualsBruteForce(tc)
% Independent brute force: all permutations x all parameter values.
c = nqc_contract();
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30, 40});
p = p.add('linenoise', 'freq', {50, 60}); p.OrderMode = 'search';
leaves = p.enumerate(nqc_fakeState(false, 500), c);
vals = {{0.1, 0.5}, {20, 30, 40}, {50, 60}}; types = {'highpass','lowpass','linenoise'};
keys = {};
P = perms(1:3);
for r = 1:size(P, 1)
    for i = 1:2, for j = 1:3, for k = 1:2
        v = {vals{1}{i}, vals{2}{j}, vals{3}{k}};
        parts = cell(1, 3);
        for q = 1:3
            t = P(r, q);
            if t == 3, parts{q} = sprintf('linenoise(freq=%g,halfwidth=2)', v{3});
            else, parts{q} = sprintf('%s(cutoff=%g)', types{t}, v{t}); end
        end
        keys{end+1} = strjoin(parts, ' > '); %#ok<AGROW>
    end, end, end
end
verifyEqual(tc, sort({leaves.key})', sort(unique(keys))');
end

function testFixedOrderConflictIsExplainedNotRearranged(tc)
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('baseline'); p = p.add('epoch');
try
    p.enumerate(nqc_fakeState(false, 500), nqc_contract());
    verifyFail(tc, 'an invalid fixed order must be refused');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'nothing was rearranged'));
    verifyTrue(tc, contains(ME.message, 'step 2 "baseline"'));
    verifyTrue(tc, contains(ME.message, 'needs epoched data'));
end
end

function testFixedValuesAreNeverOverwritten(tc)
% Property: in every generated pipeline, each value the user fixed is
% exactly the value given; searched values come only from the given lists.
p = pipecompare.plan.Plan();
p = p.add('resample', 'fs', 250);
p = p.add('highpass', 'cutoff', {0.1, 0.3});
p = p.add('lowpass', 'cutoff', 30);
p = p.add('badchannels', 'measure', 'prob', 'threshold', {3, 4}, 'action', 'interpolate');
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', 120, 'exclude', {'VEOG'});
leaves = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(leaves), 4);
for l = leaves
    P = containers.Map(cellfun(@(i) i.type, l.path, 'UniformOutput', false), l.path);
    verifyEqual(tc, P('resample').params.fs, 250);
    verifyTrue(tc, ismember(P('highpass').params.cutoff, [0.1 0.3]));
    verifyEqual(tc, P('lowpass').params.cutoff, 30);
    verifyEqual(tc, P('badchannels').params.measure, 'prob');
    verifyEqual(tc, P('badchannels').params.action, 'interpolate');
    verifyEqual(tc, P('reject_threshold').params.uv, 120);
    verifyEqual(tc, P('reject_threshold').params.exclude, {'VEOG'});
    verifyEqual(tc, cellfun(@(i) i.type, l.path, 'UniformOutput', false), ...
        {'resample','highpass','lowpass','badchannels','epoch','baseline','reject_threshold'});
end
end

function testUnmentionedParametersAreSearched(tc)
p = pipecompare.plan.Plan(); p = p.add('icremove'); % threshold unmentioned -> suggestions
st = nqc_fakeState(false, 500); st.ica.present = true;
leaves = p.enumerate(st, nqc_contract());
d = pipecompare.plan.Catalog.get('icremove');
verifyEqual(tc, numel(leaves), numel(d.params(1).suggest));
end

function testReferenceSearchIsStratified(tc)
% The reference may be searched; candidates are labelled with a stratum so
% they are never ranked against a different reference.
p = pipecompare.plan.Plan();
p = p.addChoice('ref', {'reref', 'mode', 'average'}, {'reref', 'mode', 'channels', 'channels', {'TP9','TP10'}});
p = p.add('highpass', 'cutoff', {0.1, 0.5});
leaves = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(leaves), 4);
verifyEqual(tc, numel(unique({leaves.stratum})), 2);
verifyTrue(tc, all(contains({leaves.stratum}, 'reref.mode=')));
end

function testManyFreeStepsAreNotBlockedByOrderListing(tc)
% Audit: 8 unfixed steps have 40320 orders; listing orders first (limit
% 5000) blocked the search before legality was checked. Illegal prefixes
% are now cut while walking, so the legal pipelines are found.
p = pipecompare.plan.Plan();
p = p.add('resample', 'fs', 250); p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('linenoise'); p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', 100); p = p.add('reject_jointprob', 'sd', 4);
p.OrderMode = 'search';
[nextOf, nOrders] = p.orderSpace(); %#ok<ASGLU>
verifyEqual(tc, nOrders, factorial(8));
[leaves, ~, rep] = p.enumerate(nqc_fakeState(false, 500), nqc_contract(), struct('maxLeaves', 5000));
% brute force over all 40320 orders with the catalog rules
P = perms(1:8); legal = 0; S = p.Slots;
for r = 1:size(P, 1)
    st = struct('epoched', false, 'srate', 500, 'hasICA', false, 'icRemoved', false, 'removed', false, 'highpass', 0);
    ok = true;
    for q = P(r, :)
        a = S(q).alternatives{1}; prm = a.params;
        if strcmp(a.type, 'linenoise'), prm = struct('freq', 50, 'halfwidth', 2); end
        [why, st] = pipecompare.plan.Catalog.apply(a.type, prm, st);
        if ~isempty(why), ok = false; break; end
    end
    legal = legal + ok;
end
verifyEqual(tc, numel(leaves), legal);
verifyEqual(tc, rep.nOrders, factorial(8));
end

function testAllowedOrdersAreCountedAndAllRun(tc)
% With a before() constraint the allowed orders are counted (not listed)
% and every one of them is generated - nothing is sampled or dropped.
p = pipecompare.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30); p = p.add('linenoise');
p.OrderMode = 'search'; p = p.before('highpass', 'lowpass');
[~, nOrders] = p.orderSpace();
verifyEqual(tc, nOrders, 3);
[l, ~, rep] = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(l), 3);
verifyEqual(tc, rep.nOrders, 3);
for k = 1:numel(l)
    t = cellfun(@(i) i.type, l(k).path, 'UniformOutput', false);
    verifyLessThan(tc, find(strcmp(t, 'highpass')), find(strcmp(t, 'lowpass')));
end
end

function testStepsThatNeedLocationsAreExcludedWithoutThem(tc)
% Without any channel location, interpolation and ICLabel cannot run: such
% pipelines are excluded before anything runs, with the reason, instead of
% failing one by one in the middle of the search.
st = nqc_fakeState(false, 250); st.nLocated = 0;
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('badchannels', 'measure', 'kurt', 'threshold', 5);   % interpolate (default)
try
    p.enumerate(st, c); verifyFail(tc, 'expected PipeCompare:NoLegalPipeline');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'needs channel locations'));
end
p2 = pipecompare.plan.Plan(); p2 = p2.add('badchannels', 'measure', 'kurt', 'threshold', 5, 'action', 'remove');
verifyNumElements(tc, p2.enumerate(st, c), 1);
p3 = pipecompare.plan.Plan(); p3 = p3.add('ica'); p3 = p3.add('icremove', 'threshold', 0.9);
verifyError(tc, @() p3.enumerate(st, c), 'PipeCompare:NoLegalPipeline');
st.nLocated = 30;
verifyNumElements(tc, p.enumerate(st, c), 1);
verifyNumElements(tc, p3.enumerate(st, c), 1);
end

function testRepairingEpochsNeedsLocationsAndABalancedAverage(tc)
% Interpolating channels within epochs needs channel locations, and after
% an average reference the data must be averaged again (the interpolated
% channels' old values are still in the average); a bad count is refused.
st = nqc_fakeState(true, 250); st.nLocated = 30;
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('reject_threshold', 'uv', 100, 'interpolate', 3);
verifyNumElements(tc, p.enumerate(st, c), 1);
noloc = st; noloc.nLocated = 0;
try
    p.enumerate(noloc, c); verifyFail(tc, 'expected PipeCompare:NoLegalPipeline');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'within epochs') && contains(ME.message, 'channel locations'), ME.message);
end
p0 = pipecompare.plan.Plan(); p0 = p0.add('reject_threshold', 'uv', 100);
verifyNumElements(tc, p0.enumerate(noloc, c), 1);                % off (0): no locations needed
a = pipecompare.plan.Plan(); a = a.add('reref', 'mode', 'average'); a = a.add('reject_threshold', 'uv', 100, 'interpolate', 3);
try
    a.enumerate(st, c); verifyFail(tc, 'expected PipeCompare:NoLegalPipeline');
catch ME
    verifyTrue(tc, contains(ME.message, 'average'), ME.message);
end
a = a.add('reref', 'mode', 'average');
verifyNumElements(tc, a.enumerate(st, c), 1);
b = pipecompare.plan.Plan(); b = b.add('reject_jointprob', 'sd', 5, 'interpolate', {0, 2, 1.5});
verifyNumElements(tc, b.enumerate(st, c), 2);                   % 1.5 channels is not a count
end

function testBadChannelMeasuresCanBeCombined(tc)
% 'kurt+prob' flags a channel when either measure does; an unknown
% measure makes the pipeline illegal, with the reason.
st = nqc_fakeState(false, 250); st.nLocated = 30;
c = nqc_contract();
p = pipecompare.plan.Plan(); p = p.add('badchannels', 'measure', 'kurt+prob', 'threshold', 5);
verifyNumElements(tc, p.enumerate(st, c), 1);
q = pipecompare.plan.Plan(); q = q.add('badchannels', 'measure', 'kurt+corr', 'threshold', 5);
try
    q.enumerate(st, c); verifyFail(tc, 'expected PipeCompare:NoLegalPipeline');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'kurt, prob or spec'));
end
end

function testAverageReferenceComesAfterTheBadChannels(tc)
% Channels interpolated after an average reference leave their share of
% that average in every channel unless the data are averaged again: an
% order search never tries it, a fixed order is refused with the reason,
% and data already average-referenced are averaged again after them.
st = nqc_fakeState(false, 250); st.nLocated = 30;
c = nqc_contract();
p = pipecompare.plan.Plan();
p = p.add('reref', 'mode', 'average'); p = p.add('badchannels', 'measure', 'kurt', 'threshold', 5);
try
    p.enumerate(st, c); verifyFail(tc, 'average reference before the bad channels must be refused');
catch ME
    verifyEqual(tc, ME.identifier, 'PipeCompare:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'after the average reference'));
end
p.OrderMode = 'search';
leaves = p.enumerate(st, c);
verifyNumElements(tc, leaves, 1);                                  % only bad channels first
verifyEqual(tc, leaves(1).path{1}.type, 'badchannels');
q = p; q.OrderMode = 'fixed'; q = q.add('reref', 'mode', 'average');   % averaged again: fine
verifyNumElements(tc, q.enumerate(st, c), 1);
r = pipecompare.plan.Plan(); r = r.add('reref', 'mode', 'average');
r = r.add('channels', 'labels', {{'O1'}}, 'action', 'remove');
verifyError(tc, @() r.enumerate(st, c), 'PipeCompare:NoLegalPipeline');   % removed after it: also
% data already average-referenced before PipeCompare
avg = st; avg.reference = 'average';
b = pipecompare.plan.Plan(); b = b.add('badchannels', 'measure', 'kurt', 'threshold', 5);
verifyNumElements(tc, b.enumerate(st, c), 1);
verifyError(tc, @() b.enumerate(avg, c), 'PipeCompare:NoLegalPipeline');
b = b.add('reref', 'mode', 'average');
verifyNumElements(tc, b.enumerate(avg, c), 1);
end

function testDifferentFixedArgumentsAreDifferentPipelines(tc)
% Two configurations that differ only in a fixed argument (high-pass 0.1
% vs 0.5, both searching the low-pass) are four pipelines, none dropped.
p = pipecompare.plan.Plan();
p = p.addEeglab('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',20);', 'filt', 'hicutoff', {20, 30});
alt = pipecompare.run.Native.eeglabAlt('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''hicutoff'',20);');
alt.params.args(2).values = {20, 30};
p = p.addAlternative('filt', alt);
leaves = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(leaves), 4);
verifyEqual(tc, numel(unique({leaves.key})), 4);
end

function testEeglabCommandArgumentsAreSearchParameters(tc)
% A command from an EEGLAB dialog keeps every argument; named and
% positional arguments can be searched; values are written back exactly.
p = pipecompare.plan.Plan();
p = p.addEeglab('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''filtorder'',3300,''plotfreqz'',0);', 'filter', ...
    'hicutoff', {20, 30}, 'locutoff', {0.1, 1/3});
p = p.add('epoch'); p = p.add('baseline');
p = p.addEeglab('EEG = pop_eegthresh(EEG,1,[1:32],-60,120,-0.2,0.996,0,1);', 'reject', 'arg5', {100, 120});
leaves = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyEqual(tc, numel(leaves), 8);
cmds = arrayfun(@(l) l.path{1}.params.command, leaves, 'UniformOutput', false);
verifyTrue(tc, all(contains(cmds, '''filtorder'',3300')));          % unsearched dialog settings kept
verifyTrue(tc, any(contains(cmds, '0.3333333333333333')));          % exact value written back
e = pipecompare.run.Native.argsOf(cmds{find(contains(cmds, '0.33333'), 1)}, 'pop_eegfiltnew');
verifyEqual(tc, e{2}, 1/3);                                         % bit-identical
verifyTrue(tc, any(contains(cmds, '''locutoff'',0.1,')));           % and short when it can be
rej = arrayfun(@(l) l.path{4}.params.command, leaves, 'UniformOutput', false);
verifyEqual(tc, numel(unique(rej)), 2);
verifyTrue(tc, all(contains(rej, ',-60,')));                        % the other positional limit kept
a = pipecompare.run.Native.eeglabAlt('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30);');
[m, changed] = pipecompare.run.Native.mergeEeglab(a, pipecompare.run.Native.eeglabAlt('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.5,''hicutoff'',40);'));
verifyEqual(tc, changed, {'locutoff', 'hicutoff'});
verifyEqual(tc, m.params.args(1).values, {0.1, 0.5});
[~, changed] = pipecompare.run.Native.mergeEeglab(a, pipecompare.run.Native.eeglabAlt('EEG = pop_reref(EEG, []);'));
verifyEmpty(tc, changed);                                            % another call: not merged
verifyEmpty(tc, pipecompare.run.Native.eeglabAlt(sprintf('EEG = pop_iclabel(EEG, ''default'');\nEEG = pop_subcomp(EEG, [], 0);')));
z = pipecompare.run.Native.eeglabAlt('EEG = pop_rmbase(EEG);');            % no argument after EEG
verifyEqual(tc, pipecompare.run.Native.eeglabCommand(z.params.fn, z.params.args, {}), 'EEG = pop_rmbase(EEG);');
end

