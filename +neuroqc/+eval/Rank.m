classdef Rank
    %RANK Decide which candidates are acceptable and which is recommended.
    %
    %   R = neuroqc.eval.Rank.run(cands, ref, opts)
    %
    %   1. Execution failures are reported, never ranked.
    %   2. Constraints, each with a readable reason:
    %        trials per condition    >= minTrials
    %        retention per condition >= minRetention
    %        interpolated channels   <= maxInterpolated (fraction)
    %        signal preservation (FilterProbe or Injection):
    %          amplitude error <= maxAmplitudeError, peak shift <=
    %          maxLatencyShiftMs, artifactual deflection <= maxArtifactPct,
    %          waveform correlation >= minWaveformCorr, topography
    %          correlation >= minTopoCorr (injection only)
    %        optional limits on imported external QC columns
    %   3. Objective (opts.objective):
    %        'composite'  RMS of all objective SMEs (only when every
    %                     objective has the same unit)
    %        {'P3.mean','N2.peakLatency'}  priority order: candidates the
    %                     first objective cannot distinguish from its best
    %                     are compared on the second, and so on
    %        'pareto'     the non-dominated set over all objectives (point
    %                     estimates); no single winner unless it is unique
    %   4. Uncertainty: a paired bootstrap over trials (the same resampled
    %      trials, by urevent, for every candidate). A candidate is "not
    %      distinguished from the best" unless the data show it is worse
    %      than some other candidate. Default (opts.adjust =
    %      'simultaneous'): intervals for ALL pairwise differences are
    %      simultaneous (bootstrap maximum over pairs), so the probability
    %      that ANY candidate is wrongly declared worse stays bounded for
    %      any number of candidates and after selecting the best. The
    %      bootstrap is anti-conservative with few trials, so the default
    %      alpha = 0.02 was chosen by simulation: probability of any false
    %      "worse" <= 5% for 2-24 candidates, 20-100 trials per condition,
    %      unequal condition sizes, independent or highly correlated
    %      candidates (see test_statistics). diffLo/diffHi are these
    %      simultaneous intervals of the difference from the best. If one
    %      reaches 0 the data do NOT DISTINGUISH the candidate from the
    %      best - absence of evidence, not equivalence. Equivalence is
    %      claimed only with an explicit margin (opts.equivalenceMargin,
    %      objective units): the 90% interval of the difference must lie
    %      inside +/- margin (two one-sided tests at 5%). probBest = share
    %      of bootstrap draws in which the candidate is best.
    %      opts.adjust = 'none' (one percentile interval per comparison
    %      with the selected best; NOT valid for many candidates) or
    %      'bonferroni' (the same with alpha / number of comparisons).
    %   5. Among candidates the data do not distinguish from the best, the
    %      recommendation is the least aggressive: highest minimum trial
    %      retention, then smallest signal distortion, then best objective.
    %   6. Candidates are compared only within a stratum: candidates that
    %      differ in a parameter that changes the measured quantity (e.g.
    %      the reference) are ranked separately and never against each
    %      other.
    %
    %   No experimental effect (condition difference, p-value) is used, so
    %   choosing a pipeline cannot inflate the effect tested later.

    methods (Static)
        function o = defaults()
            o = struct('minTrials', 10, 'minRetention', 0.5, 'maxInterpolated', 0.2, ...
                'maxAmplitudeError', 0.10, 'maxLatencyShiftMs', 10, 'maxArtifactPct', 0.05, ...
                'minWaveformCorr', 0.95, 'minTopoCorr', 0.90, ...
                'objective', 'composite', 'nBoot', 2000, 'nBootPeakOuter', 200, 'nBootPeakInner', 100, ...
                'nBootPeak', 1000, 'alpha', 0.02, 'adjust', 'simultaneous', 'equivalenceMargin', [], 'seed', 1, ...
                'externalQC', [], 'externalLimits', struct());
        end

        function R = run(cands, ref, opts)
            if nargin < 3, opts = struct(); end
            opts = withDefaults(opts, neuroqc.eval.Rank.defaults());
            n = numel(cands);
            [objNames, mode] = resolveObjective(opts.objective, ref);
            nO = numel(ref.objectives);
            status = repmat({''}, n, 1); reasons = repmat({''}, n, 1);
            stratum = repmat({''}, n, 1);
            primary = nan(n, 1); minRet = nan(n, 1); minKept = nan(n, 1); interp = nan(n, 1);
            ampErr = nan(n, 1); latSh = nan(n, 1); artPct = nan(n, 1); wCorr = nan(n, 1); tCorr = nan(n, 1);
            resid = nan(n, 1); blsd = nan(n, 1); objAgg = nan(n, nO);
            ext = externalColumns(opts.externalQC, cands);
            for i = 1:n
                c = cands(i);
                if isfield(c, 'stratum') && ~isempty(c.stratum), stratum{i} = c.stratum; end
                if strcmp(c.status, 'rejected')      % e.g. a rejection step removed every epoch
                    status{i} = 'rejected'; minRet(i) = 0; reasons{i} = sprintf('retention 0%% (%s)', c.message); continue;
                elseif ~strcmp(c.status, 'ok')
                    status{i} = 'failed'; reasons{i} = c.message; continue;
                end
                m = c.m;
                objAgg(i, :) = [m.objectives.agg];
                primary(i) = primaryPoint(m, objNames{1}, ref);
                minRet(i) = min(m.retention); minKept(i) = min(m.kept);
                interp(i) = c.interpolatedFraction;
                sg = c.signal;
                if ~isempty(sg)
                    ampErr(i) = sg.amplitudeError; latSh(i) = sg.latencyShiftMs; artPct(i) = sg.artifactPct;
                    wCorr(i) = sg.waveformCorr; tCorr(i) = sg.topoCorr;
                end
                resid(i) = m.artifactPct; blsd(i) = m.baselineSd;
                why = {};
                % every comparison is written so that a missing value (NaN) fails it:
                % a check that was not computed is never a pass
                if ~(minKept(i) >= opts.minTrials), why{end+1} = sprintf('only %d trials in a condition (< %d)', minKept(i), opts.minTrials); end %#ok<AGROW>
                if ~(minRet(i) >= opts.minRetention), why{end+1} = sprintf('retention %.0f%% (< %.0f%%)', 100*minRet(i), 100*opts.minRetention); end %#ok<AGROW>
                if ~(interp(i) <= opts.maxInterpolated), why{end+1} = sprintf('%.0f%% channels interpolated (> %.0f%%)', 100*interp(i), 100*opts.maxInterpolated); end %#ok<AGROW>
                if isempty(sg)
                    why{end+1} = 'signal check missing'; %#ok<AGROW>
                else
                    na = {}; if isfield(sg, 'notApplicable'), na = cellstr(sg.notApplicable); end
                    lim = {'amplitudeError', opts.maxAmplitudeError, 1, 'component amplitude changed by %.0f%%', 100; ...
                        'latencyShiftMs', opts.maxLatencyShiftMs, 1, 'peak latency shifted by %.0f ms', 1; ...
                        'artifactPct', opts.maxArtifactPct, 1, 'artifactual deflection of %.0f%%', 100; ...
                        'waveformCorr', opts.minWaveformCorr, -1, 'recovered waveform r = %.2f', 1; ...
                        'topoCorr', opts.minTopoCorr, -1, 'recovered topography r = %.2f', 1};
                    for q = 1:size(lim, 1)
                        if any(strcmp(lim{q, 1}, na)), continue; end
                        v = sg.(lim{q, 1});
                        if ~isfinite(v)
                            why{end+1} = sprintf('%s: %s not computed', sg.source, lim{q, 1}); %#ok<AGROW>
                        elseif ~(lim{q, 3} * v <= lim{q, 3} * lim{q, 2})
                            why{end+1} = sprintf(['%s: ' lim{q, 4}], sg.source, lim{q, 5} * v); %#ok<AGROW>
                        end
                    end
                end
                for f = fieldnames(opts.externalLimits)'
                    lim = opts.externalLimits.(f{1}); v = ext.(f{1})(i);
                    if ~(v >= lim(1) && v <= lim(2)), why{end+1} = sprintf('external %s = %g outside [%g %g]', f{1}, v, lim); end %#ok<AGROW>
                end
                if ~isfinite(primary(i)), why{end+1} = 'objective undefined'; end %#ok<AGROW>
                if isempty(why), status{i} = 'feasible'; else, status{i} = 'rejected'; reasons{i} = strjoin(why, '; '); end
            end

            lo = nan(n, 1); hi = nan(n, 1); notDist = false(n, 1); equiv = nan(n, 1); pBest = nan(n, 1);
            pareto = false(n, 1); recommended = []; best = [];
            byStratum = struct('stratum', {}, 'best', {}, 'recommended', {}, 'set', {});
            strata = unique(stratum(strcmp(status, 'feasible')), 'stable');
            for s = 1:numel(strata)
                feas = find(strcmp(status, 'feasible') & strcmp(stratum, strata{s}));
                if strcmp(mode, 'pareto')
                    P = objAgg(feas, :);
                    nd = true(numel(feas), 1);
                    for a = 1:numel(feas)
                        dom = all(P <= P(a, :), 2) & any(P < P(a, :), 2);
                        nd(a) = ~any(dom);
                    end
                    pareto(feas(nd)) = true;
                    set = feas(nd);
                    rec = []; if isscalar(set), rec = set; end
                    byStratum(end+1) = struct('stratum', strata{s}, 'best', set, 'recommended', rec, 'set', set); %#ok<AGROW>
                    continue;
                end
                boot = neuroqc.eval.Rank.bootstrap(cands(feas), ref, opts, objNames);
                alphaEff = opts.alpha;
                if strcmp(opts.adjust, 'bonferroni'), alphaEff = opts.alpha / max(1, numel(feas) - 1); end
                S = 1:numel(feas);
                for q = 1:numel(objNames)
                    pts = arrayfun(@(i) primaryPoint(cands(feas(i)).m, objNames{q}, ref), S);
                    [~, ib] = min(pts); bq = S(ib);
                    [keepS, l, h] = bestSet(pts(:), boot{q}(S, :), ib, alphaEff, opts.adjust);
                    if q == 1
                        lo(feas(S)) = l; hi(feas(S)) = h;
                        if ~isempty(opts.equivalenceMargin)
                            mrg = opts.equivalenceMargin;
                            for k = 1:numel(S)
                                d = boot{q}(S(k), :) - boot{q}(bq, :); d = d(isfinite(d));
                                if ~isempty(d), equiv(feas(S(k))) = pct(d, 5) >= -mrg && pct(d, 95) <= mrg; end
                            end
                        end
                        notDist(feas(S(keepS))) = true;
                        Bm = boot{1}(S, :);
                        isMin = Bm <= min(Bm, [], 1) + 1e-12 * max(1, abs(min(Bm, [], 1)));
                        pBest(feas(S)) = mean(isMin ./ sum(isMin, 1), 2);   % exact ties share the draw
                        bestS = feas(bq);
                        lo(bestS) = 0; hi(bestS) = 0;
                    end
                    S = S(keepS);
                end
                t = feas(S);
                key = [-minRet(t), ampErr(t), primary(t)];
                [~, o] = sortrows(round(key, 10));
                byStratum(end+1) = struct('stratum', strata{s}, 'best', bestS, 'recommended', t(o(1)), 'set', t); %#ok<AGROW>
            end
            if isscalar(byStratum)
                recommended = byStratum.recommended; best = byStratum.best;
            end
            feasAll = find(strcmp(status, 'feasible'));
            order = [sortBy(feasAll, primary); find(strcmp(status, 'rejected')); find(strcmp(status, 'failed'))];
            T = table((1:n)', stratum, status, primary, lo, hi, notDist, equiv, pBest, pareto, minRet, minKept, interp, ...
                ampErr, latSh, artPct, wCorr, tCorr, resid, blsd, reasons, ...
                'VariableNames', {'id','stratum','status','objective','diffLo','diffHi','notDistinguished', ...
                'equivalent','probBest','pareto','minRetention','minTrials','interpolated','ampError', ...
                'latencyShiftMs','artifactPct','waveformCorr','topoCorr','residualArtifactPct','baselineSd','reason'});
            for k = 1:nO
                T.(matlab.lang.makeValidName(['sme_' ref.objectives{k}])) = objAgg(:, k);
            end
            for f = fieldnames(ext)'
                T.(matlab.lang.makeValidName(['ext_' f{1}])) = ext.(f{1});
            end
            R = struct('table', T, 'order', order, 'best', best, 'recommended', recommended, ...
                'byStratum', byStratum, 'objective', {objNames}, 'mode', mode, 'options', opts, ...
                'units', {ref.units});
        end

        function boot = bootstrap(cands, ref, opts, objNames)
            % Paired bootstrap. Returns one (candidates x B) matrix per
            % objective in objNames ('composite' allowed).
            if nargin < 4, objNames = {'composite'}; end
            opts = withDefaults(opts, neuroqc.eval.Rank.defaults());
            s = RandStream('mt19937ar', 'Seed', opts.seed);
            peak = isfield(cands(1).m, 'objectives') && any(~strcmp({cands(1).m.objectives.kind}, 'scalar'));
            B = opts.nBoot; if peak, B = opts.nBootPeakOuter; end
            nC = numel(ref.ids); W = cell(1, nC); scale = ones(1, nC);
            for c = 1:nC
                N = ref.n(c);
                if peak
                    % Peak measures already carry an inner bootstrap (bSME).
                    % Resampling WITH replacement around it overstates how
                    % much bSME varies (simulated: SD of a difference 11 ms
                    % vs 7.4 ms across replications), which left no power.
                    % Half-samples without replacement, rescaled to the full
                    % sample (bSME ~ 1/sqrt(n)), give the right spread
                    % (7.0 ms); the same half-samples for every candidate.
                    m = floor(N / 2);
                    W{c} = zeros(N, B);
                    for b = 1:B, W{c}(randperm(s, N, m), b) = 1; end
                    scale(c) = sqrt(m / N);
                else
                    idx = randi(s, N, N, B);
                    W{c} = full(sparse(idx, repmat(1:B, N, 1), 1, N, B));
                end
            end
            nO = numel(ref.objectives);
            per = zeros(numel(cands), B, nO);
            for k = 1:numel(cands)
                objs = cands(k).m.objectives;
                for o = 1:nO
                    per(k, :, o) = neuroqc.eval.Measure.smeBoot(objs(o), W, opts, 7919 * o, scale);
                end
            end
            boot = cell(1, numel(objNames));
            for q = 1:numel(objNames)
                if strcmp(objNames{q}, 'composite')
                    boot{q} = sqrt(mean(per .^ 2, 3));
                else
                    boot{q} = per(:, :, strcmp(ref.objectives, objNames{q}));
                end
            end
        end

        function T = marginal(R, leaves, searched)
            % For each searched parameter: how each value fares across all
            % evaluated candidates (median objective, median minimum
            % retention) and among feasible ones (best objective).
            rows = {};
            st = R.table.status; comp = R.table.objective; ret = R.table.minRetention;
            for s = 1:numel(searched)
                slot = searched(s).slot; param = searched(s).param;
                vals = cell(numel(leaves), 1);
                for i = 1:numel(leaves)
                    vals{i} = 'absent';
                    for q = 1:numel(leaves(i).path)
                        in = leaves(i).path{q};
                        if ~strcmp(in.slot, slot), continue; end
                        if strcmp(param, '(alternative)'), vals{i} = in.type;
                        elseif isfield(in.params, param), vals{i} = valText(in.params.(param)); end
                    end
                end
                u = unique(vals, 'stable');
                for v = 1:numel(u)
                    sel = strcmp(vals, u{v});
                    ev = sel & ~strcmp(st, 'failed');
                    f = sel & strcmp(st, 'feasible');
                    best = min(comp(f)); if isempty(best), best = NaN; end
                    rows(end+1, :) = {sprintf('%s.%s', slot, param), u{v}, sum(sel), sum(f), ...
                        median(comp(ev), 'omitnan'), median(ret(ev), 'omitnan'), best}; %#ok<AGROW>
                end
            end
            if isempty(rows), T = table(); return; end
            T = cell2table(rows, 'VariableNames', {'parameter','value','n','nFeasible', ...
                'medianObjective','medianMinRetention','bestFeasibleObjective'});
        end

        function print(R, labels, searchMode)
            if nargin < 3, searchMode = 'exhaustive'; end
            T = R.table; o = R.options;
            if strcmp(R.mode, 'pareto')
                neuroqc.utils.log('Ranking: Pareto set over objectives %s (point estimates).', strjoin(R.objective, ', '));
            else
                neuroqc.utils.log(['Ranking by %s (lower SME = more precise measure). diff = difference from the best ', ...
                    'with %.0f%% interval (%s); "nd" = not distinguished from the best by these data (not equivalence).'], ...
                    strjoin(R.objective, ' > '), 100 * (1 - o.alpha), ...
                    ternary(strcmp(o.adjust, 'simultaneous'), 'simultaneous over all candidates', ['adjust = ' o.adjust]));
            end
            fprintf('   %-4s %-9s %9s %19s %3s %5s %6s %6s %6s %5s  %s\n', 'id', 'status', 'objective', 'diff vs best [CI]', 'nd', 'pBest', 'minRet', 'interp', 'ampErr', 'art', 'pipeline');
            for k = R.order(:)'
                mark = ' '; if any([R.byStratum.recommended] == k), mark = '*'; end
                ci = ''; if isfinite(T.diffLo(k)), ci = sprintf('[%+.3f %+.3f]', T.diffLo(k), T.diffHi(k)); end
                nd = ''; if T.notDistinguished(k), nd = 'nd'; end
                if T.pareto(k), nd = 'P'; end
                fprintf('  %s%-4d %-9s %9.4g %19s %3s %5.2f %5.0f%% %5.0f%% %5.0f%% %4.1f%%  %s\n', mark, k, T.status{k}, ...
                    T.objective(k), ci, nd, T.probBest(k), 100*T.minRetention(k), 100*T.interpolated(k), ...
                    100*T.ampError(k), 100*T.artifactPct(k), labels{k});
                if ~isempty(T.stratum{k}), fprintf('        stratum: %s\n', T.stratum{k}); end
                if ~isempty(T.reason{k}), fprintf('        -> %s\n', T.reason{k}); end
                if isfinite(T.equivalent(k)) && T.equivalent(k)
                    fprintf('        equivalent to the best within +/- %g\n', o.equivalenceMargin);
                end
            end
            if isempty(R.byStratum)
                neuroqc.utils.log('NO FEASIBLE PIPELINE: no candidate satisfies the constraints (none relaxed).');
                rs = T.reason(~strcmp(T.status, 'feasible'));
                parts = regexp(strjoin(rs', '; '), ';\s*', 'split');
                parts = regexprep(parts, '[\d\.]+', '#');
                [u, ~, ic] = unique(parts(~cellfun(@isempty, parts)));
                if ~isempty(u)
                    [cnt, ord] = sort(accumarray(ic(:), 1), 'descend');
                    neuroqc.utils.log('Most common reasons: %s', strjoin(arrayfun(@(k) sprintf('%s (x%d)', u{ord(k)}, cnt(k)), ...
                        1:min(3, numel(ord)), 'UniformOutput', false), '; '));
                end
                return;
            end
            for s = 1:numel(R.byStratum)
                b = R.byStratum(s);
                lab = ''; if ~isempty(b.stratum), lab = sprintf(' [stratum %s]', b.stratum); end
                if strcmp(R.mode, 'pareto')
                    neuroqc.utils.log('Pareto set%s: %s%s', lab, mat2str(b.set(:)'), ...
                        ternary(isscalar(b.set), sprintf(' -> recommended %d', b.recommended), ' (no single winner; choose by your priorities)'));
                else
                    neuroqc.utils.log('Recommended (*)%s: candidate %d; best objective: candidate %d; %d candidate(s) not distinguished from the best.', ...
                        lab, b.recommended, b.best, numel(b.set));
                end
            end
            if numel(R.byStratum) > 1
                neuroqc.utils.log('Strata differ in what is measured; their results are not comparable with each other.');
            end
            if strcmp(searchMode, 'sample')
                neuroqc.utils.log('SEARCH WAS SAMPLED: the result is the best among the sampled candidates, not a proven optimum.');
            end
        end
    end
end

% ---------------------------------------------------------------------
function o = withDefaults(o, d)
for f = fieldnames(d)'
    if ~isfield(o, f{1}), o.(f{1}) = d.(f{1}); end
end
end

function [names, mode] = resolveObjective(obj, ref)
if ischar(obj) || isstring(obj)
    obj = char(obj);
    switch obj
        case 'composite'
            assert(numel(unique(ref.units)) == 1, 'NeuroQC:Objective', ...
                ['Objectives have different units (%s); a composite would add incompatible quantities. ', ...
                 'Set opts.objective to a priority list, e.g. {''%s''}, or ''pareto''.'], ...
                strjoin(unique(ref.units), ', '), ref.objectives{1});
            names = {'composite'}; mode = 'composite';
        case 'pareto'
            names = ref.objectives; mode = 'pareto';
        otherwise
            names = {obj}; mode = 'priority';
    end
else
    names = cellstr(obj); mode = 'priority';
end
if strcmp(mode, 'priority')
    bad = setdiff(names, ref.objectives);
    assert(isempty(bad), 'NeuroQC:Objective', 'Unknown objective(s) %s; available: %s', ...
        strjoin(bad, ', '), strjoin(ref.objectives, ', '));
end
end

function v = primaryPoint(m, name, ref)
if strcmp(name, 'composite'), v = m.composite;
else, v = m.objectives(strcmp(ref.objectives, name)).agg; end
end

function ext = externalColumns(Q, cands)
ext = struct();
if isempty(Q), return; end
if ischar(Q) || isstring(Q), Q = readtable(char(Q), 'TextType', 'char'); end
assert(istable(Q) && any(strcmp(Q.Properties.VariableNames, 'key')), 'NeuroQC:ExternalQC', ...
    'External QC must be a table (or CSV) with a ''key'' column matching the candidate pipeline keys.');
keys = arrayfun(@(c) c.key, cands, 'UniformOutput', false);
[tf, loc] = ismember(keys, Q.key);
for v = setdiff(Q.Properties.VariableNames, {'key'})
    col = Q.(v{1});
    if ~isnumeric(col) && ~islogical(col), continue; end
    x = nan(numel(cands), 1); x(tf) = double(col(loc(tf)));
    ext.(matlab.lang.makeValidName(v{1})) = x;
end
end

function [keep, lo, hi] = bestSet(pts, Bq, ib, alpha, adjust)
% Which candidates the data do not show to be worse than another one.
% pts: point objectives (K x 1); Bq: paired bootstrap replicates (K x B);
% ib: index of the point-best. lo/hi: interval of each difference from
% the best (0 for the best itself).
K = numel(pts); keep = false(K, 1); lo = nan(K, 1); hi = nan(K, 1);
keep(ib) = true;
if ~strcmp(adjust, 'simultaneous')
    % one percentile interval per comparison with the selected best
    for k = 1:K
        d = Bq(k, :) - Bq(ib, :); d = d(isfinite(d));
        if isempty(d), continue; end
        lo(k) = pct(d, 100 * alpha / 2); hi(k) = pct(d, 100 * (1 - alpha / 2));
        keep(k) = keep(k) || lo(k) <= 0;
    end
    return;
end
% Simultaneous over ALL ordered pairs (bootstrap max statistic): with
% probability ~>= 1-alpha no candidate is wrongly declared worse than any
% other, however many candidates are compared and whichever one looks
% best. This is what makes "not distinguished from the best" valid after
% selecting the best among many. The statistic is the raw difference, not
% a t-ratio: with few trials the per-pair bootstrap SD is itself noisy and
% the maximum of t-ratios over many pairs is driven by the pairs whose SD
% happens to be underestimated (simulation: 40% false "worse" at 30
% trials and 24 candidates). Raw differences keep the error rate bounded
% at the cost of power for pairs that differ little.
B = size(Bq, 2); maxD = -inf(1, B);
Dhat = pts - pts';                             % K x K: i minus j
for i = 1:K
    D = Bq(i, :) - Bq;                         % K x B: candidate i minus each j
    D(~isfinite(D)) = NaN;
    maxD = max(maxD, max(D - Dhat(i, :)', [], 1, 'omitnan'));
end
z = maxD(isfinite(maxD));
if isempty(z), c = Inf; else, c = pct(z, 100 * (1 - alpha)); end
worse = Dhat > c;
keep = keep | ~any(worse, 2);
lo = Dhat(:, ib) - c; hi = Dhat(:, ib) + c;
lo(ib) = 0; hi(ib) = 0;
end

function v = pct(x, p)
x = sort(x(:));
if numel(x) == 1, v = x; return; end
r = 1 + (numel(x) - 1) * p / 100;
v = interp1(1:numel(x), x, r, 'linear');
end

function i = sortBy(idx, val)
[~, o] = sort(val(idx)); i = idx(o); i = i(:);
end

function t = valText(v)
if ischar(v) || isstring(v), t = char(v);
elseif isnumeric(v) || islogical(v), t = mat2str(v);
elseif iscell(v), t = strjoin(cellfun(@valText, v, 'UniformOutput', false), ',');
else, t = class(v);
end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
