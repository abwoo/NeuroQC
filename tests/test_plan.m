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
p = neuroqc.plan.Plan();
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
p = neuroqc.plan.Plan(); p = p.add('baseline'); p = p.add('epoch');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), c), 'NeuroQC:NoLegalPipeline');
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1);
verifyError(tc, @() p.enumerate(nqc_fakeState(true, 500), c), 'NeuroQC:NoLegalPipeline'); % already epoched
p = neuroqc.plan.Plan(); p = p.add('icremove');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), c), 'NeuroQC:NoLegalPipeline'); % no ICA
end

function testOrderSearchWithPinAndBefore(tc)
c = nqc_contract();
p = neuroqc.plan.Plan();
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
p = neuroqc.plan.Plan(); p = p.add('epoch');
p = p.addChoice('reject', {'reject_threshold', 'uv', 100}, {'reject_jointprob', 'sd', 4}, 'none');
leaves = p.enumerate(nqc_fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 3);
end

function testSearchBudgetRefusesSilently(tc)
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', num2cell(0.1:0.1:2));
p = p.add('lowpass', 'cutoff', num2cell(20:1:45));
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), nqc_contract(), struct('maxLeaves', 100)), 'NeuroQC:SearchTooLarge');
verifyError(tc, @() p.enumerate(nqc_fakeState(false, 500), nqc_contract(), struct('maxLeaves', 1e6, 'maxVisits', 50)), 'NeuroQC:SearchTooLarge');
end

% -------------------------------------------------------------- statistics

function testEnumerationEqualsBruteForce(tc)
% Independent brute force: all permutations x all parameter values.
c = nqc_contract();
p = neuroqc.plan.Plan();
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
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1); p = p.add('baseline'); p = p.add('epoch');
try
    p.enumerate(nqc_fakeState(false, 500), nqc_contract());
    verifyFail(tc, 'an invalid fixed order must be refused');
catch ME
    verifyEqual(tc, ME.identifier, 'NeuroQC:NoLegalPipeline');
    verifyTrue(tc, contains(ME.message, 'nothing was rearranged'));
    verifyTrue(tc, contains(ME.message, 'step 2 "baseline"'));
    verifyTrue(tc, contains(ME.message, 'needs epoched data'));
end
end

function testFixedValuesAreNeverOverwritten(tc)
% Property: in every generated pipeline, each value the user fixed is
% exactly the value given; searched values come only from the given lists.
p = neuroqc.plan.Plan();
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
p = neuroqc.plan.Plan(); p = p.add('icremove'); % threshold unmentioned -> suggestions
st = nqc_fakeState(false, 500); st.ica.present = true;
leaves = p.enumerate(st, nqc_contract());
d = neuroqc.plan.Catalog.get('icremove');
verifyEqual(tc, numel(leaves), numel(d.params(1).suggest));
end

function testReferenceSearchIsStratified(tc)
% The reference may be searched; candidates are labelled with a stratum so
% they are never ranked against a different reference.
p = neuroqc.plan.Plan();
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
p = neuroqc.plan.Plan();
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
        [why, st] = neuroqc.plan.Catalog.apply(a.type, prm, st);
        if ~isempty(why), ok = false; break; end
    end
    legal = legal + ok;
end
verifyEqual(tc, numel(leaves), legal);
verifyEqual(tc, rep.nOrders, factorial(8));
end

function testOrderSamplingIsUniformOverAllowedOrders(tc)
% With a before() constraint the allowed orders are counted, not listed,
% and drawn uniformly.
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30); p = p.add('linenoise');
p.OrderMode = 'search'; p = p.before('highpass', 'lowpass');
[~, nOrders] = p.orderSpace();
verifyEqual(tc, nOrders, 3);
o = struct('searchMode', 'sample', 'sampleSize', 3, 'sampleSeed', 2);
[l, ~, rep] = p.enumerate(nqc_fakeState(false, 500), nqc_contract(), o);
verifyEqual(tc, numel(l), 3);
verifyEqual(tc, rep.estimatedLegalPipelines, 3);
for k = 1:numel(l)
    t = cellfun(@(i) i.type, l(k).path, 'UniformOutput', false);
    verifyLessThan(tc, find(strcmp(t, 'highpass')), find(strcmp(t, 'lowpass')));
end
end

function testSampledSearchIsLabelledDistinctAndLegal(tc)
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', num2cell(0.1:0.1:2));
p = p.add('lowpass', 'cutoff', num2cell(20:1:45));
p = p.add('epoch'); p = p.add('baseline');
o = struct('searchMode', 'sample', 'sampleSize', 40, 'sampleSeed', 3);
[l1, ~, rep] = p.enumerate(nqc_fakeState(false, 500), nqc_contract(), o);
l2 = p.enumerate(nqc_fakeState(false, 500), nqc_contract(), o);
verifyEqual(tc, rep.searchMode, 'sample');
verifyEqual(tc, numel(l1), 40);
verifyEqual(tc, numel(unique({l1.key})), 40);          % distinct
verifyEqual(tc, {l1.key}, {l2.key});                  % reproducible with the seed
verifyEqual(tc, rep.estimatedLegalPipelines, 20 * 26); % every combination is legal here
end

function testSampledSearchFindsLegalOnesAmongIllegal(tc)
% Orders are free; most orders are illegal (baseline before epoch...).
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('epoch'); p = p.add('baseline');
p.OrderMode = 'search';
o = struct('searchMode', 'sample', 'sampleSize', 2, 'sampleSeed', 1);
[l, ~, rep] = p.enumerate(nqc_fakeState(false, 500), nqc_contract(), o);
verifyEqual(tc, numel(l), 2);
exhaustive = p.enumerate(nqc_fakeState(false, 500), nqc_contract());
verifyTrue(tc, all(ismember({l.key}, {exhaustive.key})));
verifyLessThan(tc, rep.legalFraction, 1);
end
