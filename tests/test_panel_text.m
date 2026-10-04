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
verifyEqual(tc, c(1, :), {'P3', [0.3 0.6], {'Pz', 'CPz'}, {'mean'}});
verifyEqual(tc, c(2, :), {'N1', [0.08 0.14], {'Cz'}, {'peakAmplitude', 'negative'}});
verifyEqual(tc, T.parseComponents(T.componentsText(c)), c);
verifyError(tc, @() T.parseComponents('P3: 0.3 @ Pz'), 'PipeCompare:Contract');
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
verifyEqual(tc, V.parseValues('[-200 0] | [-100 0]', 'number'), {[-200 0], [-100 0]});
verifyEqual(tc, V.parseValues('Pz Cz | "POL EYEL"', 'labels'), {{'Pz', 'Cz'}, {'POL EYEL'}});
verifyEqual(tc, V.parseValues('kurt | ''prob''', 'text'), {'kurt', 'prob'});
verifyError(tc, @() V.parseValues('disp(1)', 'number'), 'PipeCompare:Plan');   % never run as code
verifyEqual(tc, V.parseValues('', 'number'), {});
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
