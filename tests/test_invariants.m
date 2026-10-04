function tests = test_invariants
%TEST_INVARIANTS Behaviour that must hold whatever else changes: explicit
%   values are never replaced by defaults, missing events fail before any
%   processing, detection does not imply removal, and similar guarantees.
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
end

function testInvalidExplicitValueIsRefusedNotDefaulted(tc)
% 0.6 test_scope_integrity/testInvalidExplicitThresholdNeverDefaults
st = nqc_fakeState(false, 250);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', {-1, 0.5});
[leaves, ~, rep] = p.enumerate(st, nqc_contract());
verifyEqual(tc, numel(leaves), 1);
verifyEqual(tc, leaves(1).path{1}.params.cutoff, 0.5);
verifyTrue(tc, any(contains({rep.rejected.reason}, 'positive')));
p = pipecompare.plan.Plan(); p = p.add('reject_threshold', 'uv', 0);
p = p.add('epoch'); p.OrderMode = 'search';
verifyError(tc, @() p.enumerate(st, nqc_contract()), 'PipeCompare:NoLegalPipeline');
p = pipecompare.plan.Plan(); p = p.add('ica'); p = p.add('icremove', 'threshold', 1.5);
verifyError(tc, @() p.enumerate(st, nqc_contract()), 'PipeCompare:NoLegalPipeline');
end

function testNoneOnlyChoiceNeverBecomesRunAll(tc)
% 0.6 test_order_search/testAllOffNeverBecomesRunAll
st = nqc_fakeState(true, 250);
p = pipecompare.plan.Plan(); p = p.addChoice('rej', 'none');
leaves = p.enumerate(st, nqc_contract());
verifyEqual(tc, numel(leaves), 1);
verifyEmpty(tc, leaves(1).path);
end

function testFixedValueIsNotReplacedBySuggestions(tc)
% 0.6 test_order_search/testFixedModeDoesNotSilentlyPickFirst
st = nqc_fakeState(false, 250);
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.3);
leaves = p.enumerate(st, nqc_contract());
verifyEqual(tc, numel(leaves), 1);
verifyEqual(tc, leaves(1).path{1}.params.cutoff, 0.3);
end

function testMissingEventTypeFailsBeforeProcessing(tc)
% 0.6 test_action_gate/testEmptyEventsBlocksGenerate, test_algo_fixes/testTimeLockingEventFailClosed
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
nqc_setBase(EEG);
c = pipecompare.eval.Contract('conditions', {'x', {'999'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.3 0.5], {'Pz'}});
p = pipecompare.plan.Plan(); p = p.add('highpass', 'cutoff', 0.5); p = p.add('epoch'); p = p.add('baseline');
verifyError(tc, @() pipecompare.PipeCompare.optimize(p, c), 'PipeCompare:Contract');
end

function testEveryCatalogStepHasANativeDialog(tc)
% 0.6 test_capture_inventory/testStepPopFunctionCoversAllCanonicalSteps
for t = setdiff(pipecompare.plan.Catalog.types(), {'native', 'channels'})
    call = pipecompare.run.Native.menuCall(t{1});
    verifyTrue(tc, contains(call, 'pop_'), t{1});
end
end

function testDetectingBadChannelsNeverImpliesRemovalByItself(tc)
% 0.6 test_handoff_regression/testBadDetectionDoesNotImplyRemoval: the action is explicit
d = pipecompare.plan.Catalog.get('badchannels');
a = d.params(strcmp({d.params.name}, 'action'));
verifyEqual(tc, a.default, 'interpolate');
st = nqc_fakeState(false, 250);
p = pipecompare.plan.Plan(); p = p.add('badchannels', 'measure', 'kurt', 'threshold', 5);
leaves = p.enumerate(st, nqc_contract());
verifyTrue(tc, all(arrayfun(@(l) strcmp(l.path{1}.params.action, 'interpolate'), leaves)));
end
