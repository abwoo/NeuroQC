function tests = test_panel_text
%TEST_PANEL_TEXT The panel's text fields without the panel: conditions,
%   components and step values are read and written back without loss,
%   and nothing typed is evaluated as code.
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
end

function testConditionsRoundTrip(tc)
T = pipecompare.gui.PanelText;
c = T.parseConditions('target: 11 21; standard: "S 31"');
verifyEqual(tc, c, {'target', {'11', '21'}; 'standard', {'S 31'}});
verifyEqual(tc, T.parseConditions(T.conditionsText(c)), c);        % spaces in a code survive
verifyError(tc, @() T.parseConditions('target 11'), 'PipeCompare:Contract');
verifyError(tc, @() T.parseConditions('target:'), 'PipeCompare:Contract');
end

function testComponentsRoundTrip(tc)
T = pipecompare.gui.PanelText;
c = T.parseComponents('P3: 0.3 0.6 @ Pz CPz; N1: 0.08 0.14 @ Cz # peakAmplitude negative');
verifyEqual(tc, c(1, :), {'P3', [0.3 0.6], {'Pz', 'CPz'}, {'mean'}, {}});
verifyEqual(tc, c(2, :), {'N1', [0.08 0.14], {'Cz'}, {'peakAmplitude', 'negative'}, {}});
verifyEqual(tc, T.parseComponents(T.componentsText(c)), c);
verifyError(tc, @() T.parseComponents('P3: 0.3 @ Pz'), 'PipeCompare:Contract');
% contralateral minus ipsilateral: the electrode contralateral to each condition
l = T.parseComponents('N2pc: 0.2 0.275 @ PO7 PO8 # contra PO8 PO7');
verifyEqual(tc, l(1, :), {'N2pc', [0.2 0.275], {'PO7', 'PO8'}, {'mean'}, {'PO8', 'PO7'}});
verifyEqual(tc, T.componentsText(l), 'N2pc: 0.2 0.275 @ PO7 PO8 # contra PO8 PO7');
l = T.parseComponents('LRP: -0.1 0 @ C3 C4 # peakAmplitude negative contra C4 C3');
verifyEqual(tc, l(1, 4:5), {{'peakAmplitude', 'negative'}, {'C4', 'C3'}});
verifyEqual(tc, T.parseComponents(T.componentsText(l)), l);
k = pipecompare.eval.Contract('conditions', {'left', {'1'}; 'right', {'2'}}, 'components', l);
verifyTrue(tc, k.isLateral(1));
verifyError(tc, @() T.parseComponents('N2pc: 0.2 0.275 @ PO7 PO8 # contra'), 'PipeCompare:Contract');
end

function testBandsRoundTrip(tc)
T = pipecompare.gui.PanelText;
b = T.parseBands('alpha: 8 13 @ O1 Oz O2; theta: 4 8 @ "F z"');
verifyEqual(tc, b(1, :), {'alpha', [8 13], {'O1', 'Oz', 'O2'}});
verifyEqual(tc, b(2, :), {'theta', [4 8], {'F z'}});
verifyEqual(tc, T.parseBands(T.bandsText(b)), b);
verifyEqual(tc, size(T.parseBands('')), [0 3]);
verifyError(tc, @() T.parseBands('alpha: 8 @ Oz'), 'PipeCompare:Contract');
end

function testTrialRuleAndNumberTexts(tc)
T = pipecompare.gui.PanelText;
verifyEqual(tc, T.trialText(struct('mode', 'all')), 'all trials');
verifyEqual(tc, T.trialText(struct('mode', 'time_ranges', 'ranges', [20 60])), 'time ranges [20 60] s');
verifyEqual(tc, T.trialText(struct('mode', 'urevents', 'ids', 1:4)), '4 selected events');
verifyEqual(tc, T.pctText(0.256), '25.6%');
verifyEqual(tc, T.pctText(NaN), '-');
verifyEqual(tc, T.num(1.23456, '%.3g'), '1.23');
verifyEqual(tc, T.orDash(''), '-');
end

function testValuesAreParsedWithoutEvaluation(tc)
V = pipecompare.gui.PanelValues;
verifyEqual(tc, V.parseValues('0.1 | 0.5 | 1', 'number'), {0.1, 0.5, 1});
verifyEqual(tc, V.parseValues('auto | 100', 'number'), {'auto', 100});   % a rejection limit chosen from the data
verifyEqual(tc, V.parseValues('[-200 0] | [-100 0]', 'number'), {[-200 0], [-100 0]});
verifyEqual(tc, V.parseValues('Pz Cz | "POL EYEL"', 'labels'), {{'Pz', 'Cz'}, {'POL EYEL'}});
verifyEqual(tc, V.parseValues('kurt | ''prob''', 'text'), {'kurt', 'prob'});
verifyError(tc, @() V.parseValues('disp(1)', 'number'), 'PipeCompare:Plan');   % never run as code
verifyEqual(tc, V.parseValues('', 'number'), {});
end

function testTimeText(tc)
% NQC-038: 7170 s read '1 h 60 min'
T = @pipecompare.gui.Progress.timeText;
verifyEqual(tc, T(40), '40 s');
verifyEqual(tc, T(720), '12 min');
verifyEqual(tc, T(3570), '1 h 0 min');
verifyEqual(tc, T(7170), '2 h 0 min');
verifyEqual(tc, T(7800), '2 h 10 min');
C = @pipecompare.gui.Progress.clockText;                    % the time so far, to the second
verifyEqual(tc, C(45.7), '45 s');
verifyEqual(tc, C(372), '6 min 12 s');
verifyEqual(tc, C(3780), '1 h 3 min');
S = @(type, p) pipecompare.gui.Progress.stepText(struct('type', type, 'params', p, 'label', 'plan label'));
verifyEqual(tc, S('highpass', struct('cutoff', 0.5)), 'high-pass filter 0.5 Hz');
verifyEqual(tc, S('ica', struct()), 'fitting ICA (the slow part)');
verifyEqual(tc, S('native', struct()), 'plan label');
end

function testValuesEditTextRoundTrip(tc)
V = pipecompare.gui.PanelValues;
L = {0.1, [1 2], {'Pz', 'POL EYEL'}};
verifyEqual(tc, V.valuesEditText(L), '0.1 | [1 2] | Pz "POL EYEL"');
verifyEqual(tc, V.parseValues(V.valuesEditText({0.1, 0.5}), 'number'), {0.1, 0.5});
verifyEqual(tc, V.kindOf({'Pz'}), 'labels');
verifyEqual(tc, V.kindOf('kurt'), 'text');
verifyEqual(tc, V.kindOf(3), 'number');
end
