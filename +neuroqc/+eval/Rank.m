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
    %      trials, by urevent, for every candidate). For each candidate the
    %      (1-alpha) percentile interval of its difference from the best is
    %      reported. If it reaches 0 the data do NOT DISTINGUISH the
    %      candidate from the best - this is absence of evidence, not
    %      equivalence. Equivalence is claimed only with an explicit margin
    %      (opts.equivalenceMargin, objective units): the 90% interval of
    %      the difference must lie inside +/- margin (two one-sided tests at
    %      5%). probBest = share of bootstrap draws in which the candidate is
    %      best (ranking uncertainty). Default alpha = 0.02, chosen by
    %      simulation (see tests): post-selection false "worse" rate <= ~5%
    %      for 20-100 trials per condition. opts.adjust = 'bonferroni'
    %      divides alpha by the number of comparisons.
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
                'nBootPeak', 1000, 'alpha', 0.02, 'adjust', 'none', 'equivalenceMargin', [], 'seed', 1, ...
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
                ampErr(i) = sg.amplitudeError; latSh(i) = sg.latencyShiftMs; artPct(i) = sg.artifactPct;
                wCorr(i) = sg.waveformCorr; tCorr(i) = sg.topoCorr;
                resid(i) = m.artifactPct; blsd(i) = m.baselineSd;
                why = {};
                if minKept(i) < opts.minTrials, why{end+1} = sprintf('only %d trials in a condition (< %d)', minKept(i), opts.minTrials); end %#ok<AGROW>
                if minRet(i) < opts.minRetention, why{end+1} = sprintf('retention %.0f%% (< %.0f%%)', 100*minRet(i), 100*opts.minRetention); end %#ok<AGROW>
                if interp(i) > opts.maxInterpolated, why{end+1} = sprintf('%.0f%% channels interpolated (> %.0f%%)', 100*interp(i), 100*opts.maxInterpolated); end %#ok<AGROW>
                if ampErr(i) > opts.maxAmplitudeError, why{end+1} = sprintf('%s: component amplitude changed by %.0f%%', sg.source, 100*ampErr(i)); end %#ok<AGROW>
                if latSh(i) > opts.maxLatencyShiftMs, why{end+1} = sprintf('%s: peak latency shifted by %.0f ms', sg.source, latSh(i)); end %#ok<AGROW>
                if artPct(i) > opts.maxArtifactPct, why{end+1} = sprintf('%s: artifactual deflection of %.0f%%', sg.source, 100*artPct(i)); end %#ok<AGROW>
                if wCorr(i) < opts.minWaveformCorr, why{end+1} = sprintf('%s: recovered waveform r = %.2f', sg.source, wCorr(i)); end %#ok<AGROW>
                if tCorr(i) < opts.minTopoCorr, why{end+1} = sprintf('%s: recovered topography r = %.2f', sg.source, tCorr(i)); end %#ok<AGROW>
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
                    keepS = false(size(S));
                    for k = 1:numel(S)
                        d = boot{q}(S(k), :) - boot{q}(bq, :); d = d(isfinite(d));
                        if isempty(d), continue; end
                        l = pct(d, 100 * alphaEff / 2); h = pct(d, 100 * (1 - alphaEff / 2));
                        keepS(k) = l <= 0 || S(k) == bq;
                        if q == 1
                            lo(feas(S(k))) = l; hi(feas(S(k))) = h;
                            if ~isempty(opts.equivalenceMargin)
                                mrg = opts.equivalenceMargin;
                                equiv(feas(S(k))) = pct(d, 5) >= -mrg && pct(d, 95) <= mrg;
                            end
                        end
                    end
                    if q == 1
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
            nC = numel(ref.ids); W = cell(1, nC);
            for c = 1:nC
                N = ref.n(c);
                idx = randi(s, N, N, B);
                W{c} = full(sparse(idx, repmat(1:B, N, 1), 1, N, B));
            end
            nO = numel(ref.objectives);
            per = zeros(numel(cands), B, nO);
            for k = 1:numel(cands)
                objs = cands(k).m.objectives;
                for o = 1:nO
                    per(k, :, o) = neuroqc.eval.Measure.smeBoot(objs(o), W, opts, 7919 * o);
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
                    'with %.0f%% interval; "nd" = not distinguished from the best by these data (not equivalence).'], ...
                    strjoin(R.objective, ' > '), 100 * (1 - o.alpha));
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
