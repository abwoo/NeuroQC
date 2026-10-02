function tests = test_neuroqc
%TEST_NEUROQC Tests for NeuroQC 0.7 (needs EEGLAB on the path).
%   Run: results = runtests('test_neuroqc');
tests = functiontests(localfunctions);
end

function setupOnce(tc)
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
assert(exist('pop_epoch', 'file') == 2, 'EEGLAB must be on the path');
% Optional: a real processed dataset (never committed), e.g.
% setenv('NEUROQC_REAL_SET', '/path/to/file.set')
tc.TestData.realSet = getenv('NEUROQC_REAL_SET');
end

% ---------------------------------------------------------------- history
function testHistoryOrderedNoDedupe(tc)
h = sprintf([ ...
    'EEG.etc.eeglabvers = ''2026.0.0''; %% this tracks which version\n' ...
    'EEG = pop_eegfiltnew(EEG, ''locutoff'',1,''hicutoff'',30,''plotfreqz'',1);\n' ...
    'figure; pop_spectopo(EEG, 1, [0  4121340], ''EEG'' , ''freq'', [6 10 22]);\n' ...
    'EEG = pop_eegfiltnew(EEG, ''locutoff'',48,''hicutoff'',52,''revfilt'',1,''plotfreqz'',1);\n' ...
    'EEG = pop_select( EEG, ''rmchannel'',{''O1'',''O2''});\n' ...
    'EEG = pop_reref( EEG, []);\n' ...
    'EEG = pop_runica(EEG, ''icatype'', ''runica'', ''extended'',1,''pca'',20,''interrupt'',''on'');\n' ...
    'EEG = pop_interp(EEG, ALLEEG(5).chanlocs, ''spherical'');\n' ...
    'pop_selectcomps(EEG, [1:20] );\n' ...
    'EEG = pop_epoch( EEG, {  ''11''  ''21''  ''31''  }, [-0.2           1], ''epochinfo'', ''yes'');\n' ...
    'EEG = pop_subcomp( EEG, [], 0);\n' ...
    'EEG = pop_rmbase( EEG, [-200 0] ,[]);\n' ...
    'EEG = pop_reref( EEG, []);\n' ...
    'EEG = pop_runica(EEG, ''icatype'', ''runica'', ''extended'',1);\n' ...
    'EEG = pop_eegthresh(EEG,1,[1:30],-100,100,-0.2,0.996,0,0);\n' ...
    'EEG = pop_rejepoch( EEG, [3 7], 0);']);
e = neuroqc.live.History.parse(h);
steps = {e.step};
verifyEqual(tc, sum(strcmp(steps, 'reref')), 2);
verifyEqual(tc, sum(strcmp(steps, 'ica')), 2);
verifyEqual(tc, e(strcmp({e.fn}, 'pop_spectopo')).kind, 'view');
verifyEqual(tc, e(strcmp({e.fn}, 'figure')).kind, 'view');
bp = e(find(strcmp({e.fn}, 'pop_eegfiltnew'), 1));
verifyEqual(tc, bp.step, 'bandpass'); verifyEqual(tc, bp.params.locutoff, 1); verifyEqual(tc, bp.params.hicutoff, 30);
nt = e(find(strcmp({e.fn}, 'pop_eegfiltnew'), 1, 'last'));
verifyEqual(tc, nt.step, 'linenoise');
verifyEqual(tc, e(strcmp({e.fn}, 'pop_select')).step, 'channels');
ep = e(strcmp({e.fn}, 'pop_epoch'));
verifyEqual(tc, ep.params.window, [-0.2 1]);
verifyTrue(tc, contains(e(strcmp({e.fn}, 'pop_interp')).note, 'not reproducible'));
verifyTrue(tc, contains(e(strcmp({e.fn}, 'pop_subcomp')).note, 'gcompreject'));
verifyEqual(tc, e(strcmp({e.fn}, 'pop_eegthresh')).kind, 'mark');
verifyEqual(tc, e(strcmp({e.fn}, 'pop_rejepoch')).step, 'reject_epochs');
verifyEqual(tc, e(1).kind, 'admin');
end

function testHistoryCharMatrixAndPositional(tc)
h = char({'EEG = pop_eegfiltnew(EEG, 0.5, []);', 'EEG = pop_eegfiltnew(EEG, [], 40);', ...
    'EEG = pop_resample( EEG, 250);'});
e = neuroqc.live.History.parse(h);
verifyEqual(tc, {e.step}, {'highpass','lowpass','resample'});
verifyEqual(tc, e(3).params.fs, 250);
end

function testRealDatasetHistory(tc)
assumeTrue(tc, ~isempty(tc.TestData.realSet) && isfile(tc.TestData.realSet), 'set NEUROQC_REAL_SET to run');
EEG = pop_loadset(tc.TestData.realSet);
s = neuroqc.live.DataState.fromEEG(EEG);
% every pop_* call that the history contains is kept (no deduplication)
h = char(EEG.history); h = h(:)';
for fn = {'pop_runica', 'pop_reref', 'pop_epoch', 'pop_eegfiltnew'}
    verifyEqual(tc, sum(strcmp({s.history.fn}, fn{1})), numel(regexp(h, ['\<' fn{1} '\s*\('])), fn{1});
end
neuroqc.live.DataState.print(s);
end

% ------------------------------------------------------------------- plan
function testPlanFixedAndSearched(tc)
st = fakeState(false, 500);
c = contractFor();
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

function testPlanMustFixReference(tc)
p = neuroqc.plan.Plan(); p = p.add('reref', 'mode', {'average','channels'});
verifyError(tc, @() p.enumerate(fakeState(false, 500), contractFor()), 'NeuroQC:MustFix');
p = neuroqc.plan.Plan(); p = p.add('reref');
verifyError(tc, @() p.enumerate(fakeState(false, 500), contractFor()), 'NeuroQC:MustFix');
end

function testPlanLegality(tc)
c = contractFor();
p = neuroqc.plan.Plan(); p = p.add('baseline'); p = p.add('epoch');
verifyError(tc, @() p.enumerate(fakeState(false, 500), c), 'NeuroQC:NoLegalPipeline');
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', 0.1);
verifyError(tc, @() p.enumerate(fakeState(true, 500), c), 'NeuroQC:NoLegalPipeline'); % already epoched
p = neuroqc.plan.Plan(); p = p.add('icremove');
verifyError(tc, @() p.enumerate(fakeState(false, 500), c), 'NeuroQC:NoLegalPipeline'); % no ICA
end

function testOrderSearchWithPinAndBefore(tc)
c = contractFor();
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('linenoise'); p = p.add('epoch'); p = p.add('baseline');
p.OrderMode = 'search';
p = p.pin('epoch'); p = p.pin('baseline');
leaves = p.enumerate(fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 6); % 3! orders of the filters, epoch/baseline pinned
p = p.before('highpass', 'lowpass');
leaves = p.enumerate(fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 3);
end

function testChoiceWithNone(tc)
c = contractFor();
p = neuroqc.plan.Plan(); p = p.add('epoch');
p = p.addChoice('reject', {'reject_threshold', 'uv', 100}, {'reject_jointprob', 'sd', 4}, 'none');
leaves = p.enumerate(fakeState(false, 500), c);
verifyEqual(tc, numel(leaves), 3);
end

function testSearchBudgetRefusesSilently(tc)
p = neuroqc.plan.Plan(); p = p.add('highpass', 'cutoff', num2cell(0.1:0.1:2));
p = p.add('lowpass', 'cutoff', num2cell(20:1:45));
verifyError(tc, @() p.enumerate(fakeState(false, 500), contractFor(), struct('maxLeaves', 100)), 'NeuroQC:SearchTooLarge');
end

% -------------------------------------------------------------- statistics
function testSmeAnalytic(tc)
S = [1; 2; 3; 4; NaN];
verifyEqual(tc, neuroqc.eval.Measure.sme(S), std([1 2 3 4]) / 2, 'AbsTol', 1e-12);
end

function testBootstrapTiesAndSeparates(tc)
rng(3);
N = 120; base = randn(N, 1);
ref = struct('ids', {{1:N}}, 'n', N);
mk = @(S) struct('m', struct('S', {{S}}));
a = mk(base); b = mk(base + 0.01 * randn(N, 1)); noisy = mk(base * 1.6);
dropped = base; dropped(1:60) = NaN; d = mk(dropped);
boot = neuroqc.eval.Rank.bootstrap([a b noisy d], ref, neuroqc.eval.Rank.defaults());
diffB = boot(2, :) - boot(1, :); diffN = boot(3, :) - boot(1, :);
verifyTrue(tc, pct(diffB, 2.5) <= 0 || abs(mean(diffB)) < 0.01);
verifyGreaterThan(tc, pct(diffN, 2.5), 0);           % clearly noisier -> separated
verifyGreaterThan(tc, median(boot(4, :) - boot(1, :)), 0); % half the trials -> larger SME
end

function testFilterProbe(tc)
c = contractFor();
mk = @(type, v) struct('type', type, 'params', struct('cutoff', v), 'key', sprintf('%s(%g)', type, v), 'slot', type);
gentle = neuroqc.eval.FilterProbe.run({mk('highpass', 0.1), mk('lowpass', 30)}, 250, c);
harsh = neuroqc.eval.FilterProbe.run({mk('highpass', 2)}, 250, c);
none = neuroqc.eval.FilterProbe.run({}, 250, c);
verifyLessThan(tc, gentle.amplitudeError, 0.05);
verifyLessThan(tc, gentle.artifactPct, 0.05);
verifyGreaterThan(tc, harsh.amplitudeError, 0.2);
verifyGreaterThan(tc, harsh.artifactPct, gentle.artifactPct);
verifyEqual(tc, none.amplitudeError, 0);
end

% ------------------------------------------------------------- end to end
function testEndToEndRecoversSensibleChoice(tc)
[EEG, truth] = nqc_synth();
setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], truth.roi});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 2});
p = p.add('lowpass', 'cutoff', 30);
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', {75, 1000});
r = neuroqc.NeuroQC.optimize(p, c);
T = r.ranking.table;
verifyEqual(tc, numel(r.leaves), 4);
verifyEqual(tc, r.report.nNodes, 2 + 2 + 2 + 2 + 4);
% 2 Hz high-pass distorts the P3 -> rejected by the probe
hp2 = find(contains(r.labels, 'highpass(cutoff=2)'));
verifyTrue(tc, all(strcmp(T.status(hp2), 'rejected')));
% with movement artifacts on ~15% of trials, rejecting at 75 uV beats no rejection
rec = r.ranking.recommended;
verifyTrue(tc, contains(r.labels{rec}, 'highpass(cutoff=0.1)'));
verifyTrue(tc, contains(r.labels{rec}, 'uv=75'));
% every candidate carries its full command history
verifyTrue(tc, any(contains(r.cands(rec).coms, 'pop_eegfiltnew')));
verifyTrue(tc, any(contains(r.cands(rec).coms, 'pop_rejepoch')));
% the live dataset was not modified
cur = evalin('base', 'EEG');
verifyEqual(tc, cur.history, EEG.history);
% adopt: new dataset, full history, identical SME on replay
nBefore = evalin('base', 'numel(ALLEEG)');
neuroqc.NeuroQC.adopt(r);
verifyEqual(tc, evalin('base', 'numel(ALLEEG)'), nBefore + 1);
adopted = evalin('base', 'EEG');
verifyTrue(tc, contains(adopted.history, 'pop_eegthresh'));
verifyTrue(tc, contains(adopted.history, 'pop_rejepoch'));
m = neuroqc.eval.Measure.candidate(adopted, c, r.ref);
verifyEqual(tc, m.composite, r.cands(rec).m.composite, 'RelTol', 1e-9);
end

function testIcaSharedAcrossThresholds(tc)
EEG = nqc_synth(struct('seconds', 240, 'nPerCond', 50));
setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4','POz'}});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', 0.1); p = p.add('lowpass', 'cutoff', 30);
p = p.add('reref', 'mode', 'average');
p = p.add('ica', 'fitHighpass', 1); p = p.add('icremove', 'threshold', {0.8, 0.9});
p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, c);
verifyEqual(tc, numel(r.leaves), 2);
verifyEqual(tc, r.report.nNodes, 4 + 2 * 3); % one ICA for both thresholds
verifyTrue(tc, all(strcmp({r.cands.status}, 'ok')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'EEGica = pop_eegfiltnew')));
verifyTrue(tc, any(contains(r.cands(1).coms, 'pop_icflag')));
end

function testNativeCommandStep(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30, 'artifactTrials', 0));
setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], {'Pz','P3','P4'}});
p = neuroqc.plan.Plan();
p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30,''plotfreqz'',1);');
p = p.add('epoch'); p = p.add('baseline');
r = neuroqc.NeuroQC.optimize(p, c);
verifyEqual(tc, r.cands(1).status, 'ok');
verifyTrue(tc, contains(r.cands(1).coms{1}, '''plotfreqz'',0'));
verifyGreaterThan(tc, r.cands(1).probe.amplitudeError, 0); % filter recognised by the probe
end

% ------------------------------------------------- numerical validation
function testSmeMatchesEmpiricalSdOfTheMean(tc)
% SME must estimate the standard deviation of the averaged score across
% replications of the experiment (its definition), not just "be a number".
rs = RandStream('mt19937ar', 'Seed', 11);
N = 40; sigma = 7; reps = 4000;
m = zeros(reps, 1); sme = zeros(reps, 1);
for r = 1:reps
    x = 3 + sigma * randn(rs, N, 1);
    m(r) = mean(x); sme(r) = neuroqc.eval.Measure.sme(x);
end
verifyEqual(tc, mean(sme), std(m), 'RelTol', 0.05);
verifyEqual(tc, mean(sme), sigma / sqrt(N), 'RelTol', 0.05);
end

function testTieCriterionErrorRateAndPower(tc)
% Paired bootstrap tie test: with equal true noise the better-looking
% candidate must rarely be declared distinguishable (post-selection false
% "worse" rate <= ~5% at the default alpha); with 1.4x noise it must usually be.
rs = RandStream('mt19937ar', 'Seed', 5);
N = 100; sims = 150; o = neuroqc.eval.Rank.defaults(); o.nBoot = 800;
ref = struct('ids', {{1:N}}, 'n', N);
fa = 0; hit = 0;
for k = 1:sims
    common = randn(rs, N, 1);                 % shared (paired) trial-to-trial variance
    a = common + randn(rs, N, 1); b = common + randn(rs, N, 1);
    c = common + 1.71 * randn(rs, N, 1);       % total SD 1.4x that of a
    fa = fa + worse(a, b, ref, o);
    hit = hit + worse(a, c, ref, o);
end
fprintf('tie test: false-worse rate %.3f, power %.3f\n', fa / sims, hit / sims);
verifyLessThan(tc, fa / sims, 0.06);
verifyGreaterThan(tc, hit / sims, 0.8);
end

function testRankingIndependentOfOtherCandidates(tc)
% Adding a candidate must not change how two existing candidates compare
% (0.6 GoalRanker failed this, see v06_reproductions R4).
rng(2); N = 80; ref = struct('ids', {{1:N}}, 'n', N);
base = randn(N, 1);
A = cand(base * 1.0); B = cand(base * 1.2);
o = neuroqc.eval.Rank.defaults(); o.nBoot = 500;
r1 = neuroqc.eval.Rank.run([A B], ref, o);
r2 = neuroqc.eval.Rank.run([A B cand(base * 3)], ref, o);
r3 = neuroqc.eval.Rank.run([A B cand(base * 1.1 + 0.3 * randn(N, 1))], ref, o);
verifyEqual(tc, r1.table.smeComposite(1:2), r2.table.smeComposite(1:2));
verifyEqual(tc, r1.table.smeComposite(1:2), r3.table.smeComposite(1:2));
verifyEqual(tc, r1.recommended, r2.recommended);
end

function testConstraintBoundaries(tc)
N = 20; ref = struct('ids', {{1:N}}, 'n', N);
x = randn(N, 1);
atLimit = x; atLimit(11:end) = NaN;          % 10 of 20 trials = 50%
below = x; below(10:end) = NaN;              % 9 of 20 = 45%
o = neuroqc.eval.Rank.defaults(); o.nBoot = 100;
R = neuroqc.eval.Rank.run([cand(atLimit) cand(below)], ref, o);
verifyEqual(tc, R.table.status, {'feasible'; 'rejected'});
verifyTrue(tc, contains(R.table.reason{2}, 'retention'));
end

function testScoresIgnoreChannelOffsets(tc)
% 0.6 split-half metrics were driven by per-channel DC offsets
% (v06_reproductions R2). Scores here are baseline-corrected per trial.
EEG = nqc_synth(struct('seconds', 90, 'nPerCond', 20, 'artifactTrials', 0));
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4','POz'}});
ref = neuroqc.eval.Measure.reference(EEG, c);
off = EEG; off.data = off.data + single((1:off.nbchan)' * 50);
a = neuroqc.eval.Measure.candidate(EEG, c, ref); b = neuroqc.eval.Measure.candidate(off, c, ref);
verifyEqual(tc, b.sme, a.sme, 'AbsTol', 1e-3);
end

function testFilterProbeIsMonotonicAndNeutral(tc)
c = contractFor();
mk = @(type, v) {struct('type', type, 'params', struct('cutoff', v), 'key', sprintf('%s(%g)', type, v), 'slot', type)};
hp = [0.05 0.1 0.3 0.5 1 2]; lp = [10 20 30 40];
eh = arrayfun(@(v) neuroqc.eval.FilterProbe.run(mk('highpass', v), 500, c).amplitudeError, hp);
el = arrayfun(@(v) neuroqc.eval.FilterProbe.run(mk('lowpass', v), 500, c).amplitudeError, lp);
rs = neuroqc.eval.FilterProbe.run({struct('type', 'resample', 'params', struct('fs', 250), 'key', 'resample(250)', 'slot', 'r')}, 500, c);
fprintf('probe amp error HP %s: %s\nprobe amp error LP %s: %s\n', mat2str(hp), mat2str(eh, 3), mat2str(lp), mat2str(el, 3));
verifyTrue(tc, all(diff(eh) >= -1e-4));   % more high-pass -> more distortion
verifyTrue(tc, all(diff(el) <= 1e-4));    % more low-pass (lower edge) -> more distortion
verifyLessThan(tc, eh(2), 0.02);          % 0.1 Hz: negligible for a 300-600 ms component
verifyLessThan(tc, rs.amplitudeError, 0.01);
end

function testEnumerationEqualsBruteForce(tc)
% Independent brute force: all permutations x all parameter values.
c = contractFor();
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30, 40});
p = p.add('linenoise', 'freq', {50, 60}); p.OrderMode = 'search';
leaves = p.enumerate(fakeState(false, 500), c);
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

function testPrefixSharingEqualsIndependentRuns(tc)
% Depth-first prefix sharing must give exactly what each pipeline gives
% when run on its own from the starting dataset (no state leaks between
% branches).
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'t', {'11'}; 's', {'31'}}, 'epoch', [-0.2 1], ...
    'baseline', [-0.2 0], 'components', {'P3', [0.3 0.5], {'Pz','P3','P4'}});
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', {0.1, 0.5}); p = p.add('lowpass', 'cutoff', {20, 30});
p = p.add('epoch'); p = p.add('baseline'); p = p.add('reject_threshold', 'uv', {80, 1000});
r = neuroqc.NeuroQC.optimize(p, c);
for k = 1:numel(r.leaves)
    E = neuroqc.run.Executor.replay(r, k);
    m = neuroqc.eval.Measure.candidate(E, c, r.ref);
    verifyEqual(tc, m.composite, r.cands(k).m.composite, 'RelTol', 1e-12, r.labels{k});
    h = regexp(E.history, '[^\n]+', 'match');
    verifyEqual(tc, h(end-numel(r.cands(k).coms)+1:end), r.cands(k).coms);
end
end

% ------------------------------------------------- EEGLAB integration
function testLiveDetectionAndUnstoredWarning(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
setBase(EEG);
[cur, info] = neuroqc.live.Session.current();
verifyEqual(tc, cur.setname, 'nqc_synth'); verifyTrue(tc, info.stored);
evalin('base', 'EEG.setname = ''changed on the command line'';');
[cur, info] = neuroqc.live.Session.current();
verifyEqual(tc, cur.setname, 'changed on the command line'); verifyFalse(tc, info.stored);
end

function testApplyThroughEeglabCodePathRecordsHistory(tc)
% "Apply now" wraps the call in EEGLAB's own try/catch + eeglab_new, so
% EEGLAB records it (EEG.history and ALLCOM). DEBUG_EEGLAB_MENUS keeps
% eeglab_new from opening its interactive "new dataset" dialog in a test.
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
setBase(EEG);
evalin('base', 'DEBUG_EEGLAB_MENUS = 1;');
cleanup = onCleanup(@() evalin('base', 'clear DEBUG_EEGLAB_MENUS'));
neuroqc.run.Native.applyCall('[EEG, LASTCOM] = pop_reref(EEG, []);', 'reref');
cur = evalin('base', 'EEG');
verifyTrue(tc, contains(cur.history, 'pop_reref( EEG, [])'));
s = neuroqc.live.DataState.fromEEG(cur);
verifyEqual(tc, s.process(end).step, 'reref');
global ALLCOM %#ok<GVMIS>
verifyTrue(tc, any(contains(ALLCOM, 'pop_reref')));
end

function testCaptureReturnsCommandWithoutTouchingData(tc)
EEG = nqc_synth(struct('seconds', 60, 'nPerCond', 10));
com = neuroqc.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_eegfiltnew(EEG, ''locutoff'', 0.5);');
verifyTrue(tc, startsWith(com, 'EEG = pop_eegfiltnew('));
p = neuroqc.plan.Plan(); p = p.addNative(com);     % becomes a fixed step
verifyEqual(tc, p.Slots(1).alternatives{1}.type, 'native');
end

% -------------------------------------------------------------------- GUI
function testPanelFollowsLiveDatasetAndRuns(tc)
EEG = nqc_synth(struct('seconds', 120, 'nPerCond', 30));
setBase(EEG);
app = neuroqc.gui.Panel();
cleanup = onCleanup(@() delete(app));
verifyEqual(tc, size(app.HistTable.Data, 1), 1);
% an EEGLAB operation on the live dataset (as a menu would do) appears in the panel
evalin('base', '[EEG, LASTCOM] = pop_reref(EEG, []); EEG = eegh(LASTCOM, EEG); [ALLEEG, EEG] = eeg_store(ALLEEG, EEG, CURRENTSET);');
app.refreshLive(false);
verifyEqual(tc, size(app.HistTable.Data, 1), 2);
verifyEqual(tc, app.HistTable.Data{2, 3}, 'reref');
% build a plan through the panel and run it
app.TypeDrop.Value = 'highpass'; app.addStep();
app.planEdited(struct('Indices', [1 3], 'NewData', 'cutoff = {0.1, 0.5}'));
app.TypeDrop.Value = 'epoch'; app.addStep();
app.TypeDrop.Value = 'baseline'; app.addStep();
app.CondField.Value = 'target: 11; standard: 31';
app.CompField.Value = 'P3: 0.3 0.5 @ Pz P3 P4';
app.run(false);
verifyEqual(tc, size(app.ResultTable.Data, 1), 2);
verifyTrue(tc, evalin('base', 'exist(''neuroqc_result'', ''var'')') == 1);
end

% ---------------------------------------------------------------- helpers
function st = fakeState(epoched, srate)
st = struct('isEpoched', epoched, 'srate', srate, 'ica', struct('present', false), ...
    'process', struct('step', {}), 'filters', struct('highpass', []));
end

function c = cand(S)
c = struct('status', 'ok', 'message', '', 'm', struct('S', {{S}}, 'composite', NaN, ...
    'retention', mean(~isnan(S)), 'kept', sum(~isnan(S))), 'interpolatedFraction', 0, ...
    'probe', struct('amplitudeError', 0, 'latencyShiftMs', 0, 'artifactPct', 0));
c.m.composite = neuroqc.eval.Measure.sme(S);
end

function tf = worse(a, b, ref, o)
% true if the noisier-looking of a/b is declared distinguishable from the other
R = neuroqc.eval.Rank.run([cand(a) cand(b)], ref, o);
tf = sum(R.table.tiedWithBest) < 2;
end

function c = contractFor()
c = neuroqc.eval.Contract('conditions', {'a', {'11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.3 0.6], {'Pz'}});
end

function setBase(EEG)
assignin('base', 'NQC_TMP', EEG);
evalin('base', ['global ALLCOM; ALLEEG = []; [ALLEEG, EEG, CURRENTSET] = eeg_store([], NQC_TMP, 0); ' ...
    'clear NQC_TMP;']);
end

function v = pct(x, p)
x = sort(x(:)); v = x(max(1, round(numel(x) * p / 100)));
end
