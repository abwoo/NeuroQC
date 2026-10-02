function tests = v06_reproductions
%V06_REPRODUCTIONS Executable reproductions of the defects found in NeuroQC 0.6.
%   Run against the 0.6 code (e.g. a git worktree of main on the path,
%   NOT the 0.7 package). Each test states the CORRECT behaviour; on 0.6
%   every test is expected to FAIL, which is the reproduction. The 0.6
%   suite (252 tests) passes because it checks the code against its own
%   definitions, not against these external criteria.
%
%   addpath('<worktree of main>'); runtests('tests/v06_reproductions.m')
tests = functiontests(localfunctions);
end

function setupOnce(tc)
assumeTrue(tc, exist('neuroqc.advice.CandidateSession', 'class') == 8, ...
    'needs the NeuroQC 0.6 package on the path');
end

% R1 -----------------------------------------------------------------------
function testR1_rereferencingIsNotDistortion(tc)
% Average re-reference changes no signal content; a "distortion" metric must
% not reject it. 0.6 measures distortion as the L2 change from the raw data.
[e, c, s, o] = fixture(struct('p300Uv', 8));
s.reference = {'average'}; o.selectedSteps = {'reref'};
q = evaluateAll(e, c, s, o);
fprintf('R1: waveformDistortion after average reference = %.3f (hard gate 0.5)\n', q(1).waveformDistortion);
verifyLessThan(tc, q(1).waveformDistortion, 0.5);
end

% R2 -----------------------------------------------------------------------
function testR2_reliabilityNotInflatedByDcOffsets(tc)
% Pure noise has no ERP, so split-half reliability must be ~0 whether or
% not channels carry constant offsets. 0.6 correlates un-baselined averages.
[e, c] = fixture(struct('p300Uv', 0, 'n200Uv', 0, 'driftUv', 0, 'lineNoiseUv', 0, 'blinkRateHz', 0));
c.components(1).roi = {'Pz','P3','P4','CPz'}; % multi-channel ROI
off = e; off.data = off.data + (1:off.nbchan)' * 20e-6; % 20..640 uV channel offsets
prep = struct('dataUnit', 'V', 'trialSelection', struct('mode', 'all'), 'trialSteps', true, 'codes', {{'s1001','s1002'}});
ref = neuroqc.advice.CandidateSession.view(neuroqc.advice.RecipeInput.prepare(e, prep), c);
a = neuroqc.advice.CandidateSession.measure(ref, ref, c);
b = neuroqc.advice.CandidateSession.measure(ref, ...
    neuroqc.advice.CandidateSession.view(neuroqc.advice.RecipeInput.prepare(off, prep), c), c);
fprintf('R2: pure noise: reliability %.3f / %.3f, topoStability %.3f / %.3f (without / with offsets)\n', ...
    a.reliability, b.reliability, a.topoStability, b.topoStability);
verifyLessThan(tc, b.reliability, 0.5);
verifyLessThan(tc, b.topoStability, 0.5);
end

% R3 -----------------------------------------------------------------------
function testR3_overFilteringIsGated(tc)
% A 2 Hz high-pass removes a large part of a P300; it must not be accepted.
% 0.6 declares a filterGuard gate but nothing computes it.
[e, c, s, o] = fixture(struct('p300Uv', 8));
s.highpass = {0.1, 2}; s.lowpass = {30}; o.selectedSteps = {'filter'};
[q, out] = evaluateAll(e, c, s, o);
hp = arrayfun(@(p) p.steps(1).parameters.highpass, out.pipelines);
for k = 1:numel(hp)
    fprintf('R3: highpass %g Hz: distortion %.3f reliability %.3f; on front %d; reason: %s\n', hp(k), ...
        q(k).waveformDistortion, q(k).reliability, ismember(k, out.frontIdx), strjoin(cellstr(out.constraintReasons), ' | '));
end
fprintf('R3: filterGuard computed: %d\n', isfield(q(1), 'filterGuard'));
% correct behaviour: the gentle filter is acceptable, the 2 Hz one is not
verifyTrue(tc, ismember(find(hp == 0.1), out.frontIdx));
verifyFalse(tc, ismember(find(hp == 2), out.frontIdx));
end

% R4 -----------------------------------------------------------------------
function testR4_rankingIndependentOfIrrelevantCandidates(tc)
% Whether A or B is better must not depend on which third candidate exists.
A = row('A', 0.800, 0.999); B = row('B', 0.810, 0.995);
prof = neuroqc.optimize.GoalProfile('two', [ ...
    neuroqc.optimize.ObjectiveSpec('reliability', 'reliability', 'max', 1), ...
    neuroqc.optimize.ObjectiveSpec('retention', 'retention', 'max', 1)]);
best1 = pick([A B row('C', 0.600, 0.9995)], prof);
best2 = pick([A B row('D', 0.805, 0.990)], prof);
fprintf('R4: best with C present: %s; best with D present: %s\n', best1, best2);
verifyEqual(tc, best1, best2);
end

% R5 -----------------------------------------------------------------------
function testR5_historyKeepsRepeatedSteps(tc)
h = sprintf(['EEG = pop_reref( EEG, []);\nEEG = pop_runica(EEG, ''icatype'', ''runica'');\n' ...
    'EEG = pop_subcomp( EEG, [], 0);\nEEG = pop_reref( EEG, []);\nEEG = pop_runica(EEG, ''icatype'', ''runica'');']);
steps = neuroqc.gui.CheckpointDialog.parseHistory(h);
fprintf('R5: parsed steps: %s\n', strjoin(steps, ' > '));
verifyEqual(tc, sum(strcmp(steps, 'run_ica')), 2);
end

% R6 -----------------------------------------------------------------------
function testR6_candidateHistoryRecordsItsSteps(tc)
% A processed candidate must carry the commands that produced it.
[e, c, s, o] = fixture(struct('p300Uv', 8));
s.highpass = {0.5}; s.lowpass = {30}; o.selectedSteps = {'filter'};
[~, out] = evaluateAll(e, c, s, o);
cand = neuroqc.advice.CandidateSession.loadCandidate(out, 1);
added = strrep(char(cand.history), char(e.history), '');
fprintf('R6: history added by the recipe: "%s"\n', strtrim(added));
verifyTrue(tc, contains(added, 'pop_eegfiltnew'));
end

% R7 -----------------------------------------------------------------------
function testR7_hashCost(tc)
% Informational: cost of the full-data SHA-256 0.6 runs on every
% generate/compare and inside every recipe.
e = fixture(struct('durationSec', 600, 'nChannels', 64));
t = tic; for k = 1:3, neuroqc.utils.hashEEG(e); end
fprintf('R7: hashEEG on %.0f MB: %.2f s per call\n', numel(e.data) * 8 / 1e6, toc(t) / 3);
verifyTrue(tc, true);
end

% ---------------------------------------------------------------- helpers
function [e, c, s, o] = fixture(opts)
d = struct('durationSec', 120, 'nTarget', 40, 'nStandard', 60);
for f = fieldnames(opts)', d.(f{1}) = opts.(f{1}); end
e = neuroqc.inspect.SyntheticEEG.generate(d);
e = eeg_checkset(e);
c = neuroqc.contract.AnalysisContract();
c = c.addCondition('target', {'s1002'}, '');
c = c.addCondition('standard', {'s1001'}, '');
c = c.setEpoch(-0.2, 1.0); c = c.setBaseline(-0.2, 0);
c = c.addComponent('P300', [.3 .6], {'Pz'}, 'mean');
s = neuroqc.pipeline.SearchSpace.defaultERP();
o = struct('dataUnit', 'V', 'outputDir', tempname, 'trialSelection', struct('mode', 'all'));
end

function [q, out] = evaluateAll(e, c, s, o)
out = neuroqc.advice.RecommendPath.run(e, c, s, o);
out = neuroqc.advice.CandidateSession.compare(out, e, c, [], 1:numel(out.pipelines));
q = [out.results.quality];
end

function r = row(id, rel, ret)
q = neuroqc.advice.ExternalQC.defaultQuality();
q.reliability = rel; q.retention = ret; q.waveformDistortion = 0.1; q.interpRatio = 0; q.badRatio = 0;
r = struct('id', id, 'quality', q);
end

function id = pick(rows, prof)
rec = neuroqc.optimize.GoalRanker.rank(rows, 1:numel(rows), prof);
id = rows(rec.bestOverall).id;
end
