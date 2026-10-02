classdef Rank
    %RANK Decide which candidates are acceptable and which is recommended.
    %
    %   R = neuroqc.eval.Rank.run(cands, ref, opts)
    %
    %   1. Execution failures are reported, never ranked.
    %   2. Constraints (each one a reason you can read):
    %        trials per condition    >= opts.minTrials
    %        retention per condition >= opts.minRetention
    %        interpolated channels   <= opts.maxInterpolated (fraction)
    %        filter probe: amplitude error <= opts.maxAmplitudeError,
    %        latency shift <= opts.maxLatencyShiftMs, artifactual
    %        deflection <= opts.maxArtifactPct
    %   3. Feasible candidates are ordered by composite SME (RMS over
    %      conditions x components, in uV; lower = less noise in the
    %      measured quantity).
    %   4. A paired bootstrap over trials (same resampled trials for every
    %      candidate, B draws) gives a percentile interval for each
    %      candidate's SME difference from the best. Candidates whose
    %      interval reaches 0 are statistically indistinguishable from the
    %      best ("tied"). Intervals are per comparison (not adjusted for
    %      the number of candidates), so the tied set is if anything too
    %      small rather than too large.
    %   5. Among tied candidates the recommendation is the least
    %      aggressive: highest minimum trial retention, then smallest
    %      filter distortion, then lowest SME.
    %
    %   No experimental effect (condition difference, p-value) is used at
    %   any point, so selecting a pipeline cannot inflate the effect you
    %   will later test.

    methods (Static)
        function o = defaults()
            o = struct('minTrials', 10, 'minRetention', 0.5, 'maxInterpolated', 0.2, ...
                'maxAmplitudeError', 0.10, 'maxLatencyShiftMs', 10, 'maxArtifactPct', 0.05, ...
                'nBoot', 2000, 'alpha', 0.05, 'seed', 1);
        end

        function R = run(cands, ref, opts)
            d = neuroqc.eval.Rank.defaults();
            if nargin < 3, opts = struct(); end
            for f = fieldnames(d)'
                if ~isfield(opts, f{1}), opts.(f{1}) = d.(f{1}); end
            end
            n = numel(cands);
            status = repmat({''}, n, 1); reasons = repmat({''}, n, 1);
            composite = nan(n, 1); minRet = nan(n, 1); minKept = nan(n, 1);
            interp = nan(n, 1); ampErr = nan(n, 1); latSh = nan(n, 1); artPct = nan(n, 1);
            for i = 1:n
                c = cands(i);
                if ~strcmp(c.status, 'ok')
                    status{i} = 'failed'; reasons{i} = c.message; continue;
                end
                m = c.m;
                composite(i) = m.composite; minRet(i) = min(m.retention); minKept(i) = min(m.kept);
                interp(i) = c.interpolatedFraction;
                ampErr(i) = c.probe.amplitudeError; latSh(i) = c.probe.latencyShiftMs; artPct(i) = c.probe.artifactPct;
                why = {};
                if minKept(i) < opts.minTrials, why{end+1} = sprintf('only %d trials in a condition (< %d)', minKept(i), opts.minTrials); end %#ok<AGROW>
                if minRet(i) < opts.minRetention, why{end+1} = sprintf('retention %.0f%% (< %.0f%%)', 100*minRet(i), 100*opts.minRetention); end %#ok<AGROW>
                if interp(i) > opts.maxInterpolated, why{end+1} = sprintf('%.0f%% channels interpolated (> %.0f%%)', 100*interp(i), 100*opts.maxInterpolated); end %#ok<AGROW>
                if ampErr(i) > opts.maxAmplitudeError, why{end+1} = sprintf('filters change component amplitude by %.0f%%', 100*ampErr(i)); end %#ok<AGROW>
                if latSh(i) > opts.maxLatencyShiftMs, why{end+1} = sprintf('filters shift peak latency by %.0f ms', latSh(i)); end %#ok<AGROW>
                if artPct(i) > opts.maxArtifactPct, why{end+1} = sprintf('filters create an artifactual deflection of %.0f%%', 100*artPct(i)); end %#ok<AGROW>
                if ~isfinite(composite(i)), why{end+1} = 'SME undefined'; end %#ok<AGROW>
                if isempty(why), status{i} = 'feasible'; else, status{i} = 'rejected'; reasons{i} = strjoin(why, '; '); end
            end

            feas = find(strcmp(status, 'feasible'));
            tied = false(n, 1); lo = nan(n, 1); hi = nan(n, 1);
            best = []; recommended = [];
            if ~isempty(feas)
                [~, ib] = min(composite(feas)); best = feas(ib);
                boot = neuroqc.eval.Rank.bootstrap(cands(feas), ref, opts);
                bBest = boot(ib, :);
                for k = 1:numel(feas)
                    dlt = boot(k, :) - bBest;
                    dlt = dlt(isfinite(dlt));
                    if isempty(dlt), continue; end
                    lo(feas(k)) = pct(dlt, 100 * opts.alpha / 2);
                    hi(feas(k)) = pct(dlt, 100 * (1 - opts.alpha / 2));
                    tied(feas(k)) = lo(feas(k)) <= 0;
                end
                tied(best) = true; lo(best) = 0; hi(best) = 0;
                t = find(tied);
                key = [-minRet(t), ampErr(t), composite(t)];
                [~, o] = sortrows(round(key, 10));
                recommended = t(o(1));
            end
            order = [feas(argsort(composite(feas))); find(strcmp(status, 'rejected')); find(strcmp(status, 'failed'))];
            R = struct();
            R.table = table((1:n)', status, composite, lo, hi, tied, minRet, minKept, interp, ampErr, latSh, artPct, reasons, ...
                'VariableNames', {'id','status','smeComposite','diffLo','diffHi','tiedWithBest','minRetention', ...
                'minTrials','interpolated','ampError','latencyShiftMs','artifactPct','reason'});
            R.order = order;
            R.best = best;
            R.recommended = recommended;
            R.options = opts;
        end

        function boot = bootstrap(cands, ref, opts)
            % Paired bootstrap of the composite SME: in every draw, the
            % same trials (urevent ids, resampled within condition) are
            % used for every candidate; a candidate contributes the drawn
            % trials it retained.
            s = RandStream('mt19937ar', 'Seed', opts.seed);
            B = opts.nBoot; nC = numel(ref.ids);
            W = cell(1, nC);
            for c = 1:nC
                N = ref.n(c);
                idx = randi(s, N, N, B);
                W{c} = full(sparse(idx, repmat(1:B, N, 1), 1, N, B));
            end
            boot = nan(numel(cands), B);
            for k = 1:numel(cands)
                acc = zeros(1, B); cnt = 0;
                for c = 1:nC
                    S = cands(k).m.S{c};
                    M = double(~isnan(S(:, 1)));
                    S0 = S; S0(isnan(S0)) = 0;
                    Nb = M' * W{c};                       % 1 x B
                    s1 = S0' * W{c}; s2 = (S0 .^ 2)' * W{c}; % J x B
                    v = (s2 - s1 .^ 2 ./ Nb) ./ (Nb - 1);
                    sm2 = max(v, 0) ./ Nb;               % SME^2
                    sm2(:, Nb < 2) = Inf;
                    acc = acc + sum(sm2, 1); cnt = cnt + size(S, 2);
                end
                boot(k, :) = sqrt(acc / cnt);
            end
        end

        function T = marginal(R, leaves, searched)
            % For each searched parameter: how each value fares across all
            % evaluated candidates (median SME and median minimum
            % retention) and among the feasible ones (best SME). Shows which
            % choices matter for this dataset, also when nothing is feasible.
            rows = {};
            st = R.table.status; comp = R.table.smeComposite; ret = R.table.minRetention;
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
            if isempty(rows)
                T = table(); return;
            end
            T = cell2table(rows, 'VariableNames', {'parameter','value','n','nFeasible', ...
                'medianSME','medianMinRetention','bestFeasibleSME'});
        end

        function print(R, labels)
            neuroqc.utils.log('Ranking (composite SME in uV; lower is better; tied = indistinguishable from best at %.0f%%):', ...
                100 * (1 - R.options.alpha));
            T = R.table;
            fprintf('   %-4s %-9s %8s %17s %6s %7s %6s %6s %6s  %s\n', 'id', 'status', 'SME', 'diff vs best [CI]', 'tied', 'minRet', 'interp', 'ampErr', 'art%', 'pipeline');
            for k = R.order(:)'
                mark = ' '; if isequal(k, R.recommended), mark = '*'; end
                ci = ''; if isfinite(T.diffLo(k)), ci = sprintf('[%+.3f %+.3f]', T.diffLo(k), T.diffHi(k)); end
                tiedTxt = ''; if T.tiedWithBest(k), tiedTxt = 'yes'; end
                fprintf('  %s%-4d %-9s %8.3f %17s %6s %6.0f%% %5.0f%% %5.0f%% %5.1f%%  %s\n', mark, k, T.status{k}, ...
                    T.smeComposite(k), ci, tiedTxt, 100*T.minRetention(k), 100*T.interpolated(k), ...
                    100*T.ampError(k), 100*T.artifactPct(k), labels{k});
                if ~isempty(T.reason{k}), fprintf('        -> %s\n', T.reason{k}); end
            end
            if isempty(R.recommended)
                neuroqc.utils.log('No candidate satisfies the constraints; see the reasons above.');
                rs = T.reason(~strcmp(T.status, 'feasible'));
                parts = regexp(strjoin(rs', '; '), ';\s*', 'split');
                parts = regexprep(parts, '[\d\.]+', '#');
                [u, ~, ic] = unique(parts(~cellfun(@isempty, parts)));
                if ~isempty(u)
                    [n, o] = sort(accumarray(ic(:), 1), 'descend');
                    neuroqc.utils.log('Most common reasons: %s', strjoin(arrayfun(@(k) sprintf('%s (x%d)', u{o(k)}, n(k)), ...
                        1:min(3, numel(o)), 'UniformOutput', false), '; '));
                end
            else
                neuroqc.utils.log('Recommended (*): candidate %d. Best SME: candidate %d. %d candidate(s) tied with the best.', ...
                    R.recommended, R.best, sum(T.tiedWithBest));
            end
        end
    end
end

function v = pct(x, p)
x = sort(x(:));
if numel(x) == 1, v = x; return; end
r = 1 + (numel(x) - 1) * p / 100;
v = interp1(1:numel(x), x, r, 'linear');
end

function i = argsort(x)
[~, i] = sort(x); i = i(:);
end

function t = valText(v)
if ischar(v) || isstring(v), t = char(v);
elseif isnumeric(v) || islogical(v), t = mat2str(v);
elseif iscell(v), t = strjoin(cellfun(@valText, v, 'UniformOutput', false), ',');
else, t = class(v);
end
end
