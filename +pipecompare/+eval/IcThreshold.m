classdef IcThreshold
    %ICTHRESHOLD The ICLabel threshold of IC removal chosen from the data
    %   (icremove with threshold = 'auto').
    %
    %   [t, info] = pipecompare.eval.IcThreshold.choose(EEG, q, ctx)
    %
    %   q: per component, the largest ICLabel probability among the artifact
    %   classes of the step (below 1: pop_icflag flags a class probability p
    %   when t < p < 1). A component is removed when q > t, so lowering t
    %   only adds components: the removed sets are nested and there are only
    %   as many different ones as different values of q. Every one of them
    %   that removes only components with q > MinProbability (more likely
    %   that artifact than anything else) is compared, and removing nothing:
    %   the exact best threshold, not the best of a few thresholds tried.
    %
    %   Removing components is linear (the data minus the removed
    %   components' projections, as pop_subcomp computes it), and the steps
    %   up to the epoch rejection that follows (ctx.after: epoching and
    %   baseline removal) commute with it, so each set is applied to the
    %   epoched data directly. For each set, the rejection that follows is
    %   applied as it would run: a fixed limit, or with uv 'auto' the best of
    %   all its limits (pipecompare.eval.Threshold). The objective is the
    %   ranking's (gain-corrected SME), the gain and the signal check coming
    %   from the known-signal copy (ctx.signal) with the same components
    %   removed; a set that fails the signal check or keeps too few trials is
    %   not a candidate. Among the sets whose objective the data do not
    %   distinguish from the best one's (paired bootstrap, simultaneous
    %   intervals), the one removing the fewest components is chosen: no
    %   component is removed without evidence that it makes the measure more
    %   precise. t is the roundest number among the thresholds that remove
    %   that set.
    %
    %   The signal check of each set is that of all epochs (the rejected
    %   ones change it only where epochs overlap); the candidate's own check
    %   after the whole pipeline is the one the ranking uses.
    %   Needs per-trial scores: mean amplitude or band power.

    properties (Constant)
        MinProbability = 0.5   % lowest threshold compared
    end

    methods (Static)
        function [t, info] = choose(EEG, q, ctx)
            contract = ctx.contract;
            ref = pipecompare.utils.fieldOr(ctx, 'ref', []);
            if isempty(ref), ref = pipecompare.eval.Measure.reference(EEG, contract); end
            opts = pipecompare.utils.withDefaults(pipecompare.utils.fieldOr(ctx, 'rank', struct()), ...
                pipecompare.eval.Rank.defaults());
            assert(pipecompare.eval.Threshold.applies(contract), 'PipeCompare:IcThreshold', ...
                ['An ICLabel threshold chosen from the data (threshold = ''auto'') needs mean amplitude or band power ', ...
                 '(peak measures have no score per trial); set the thresholds instead (e.g. 0.7 | 0.8 | 0.9).']);
            [before, rej] = splitAfter(pipecompare.utils.fieldOr(ctx, 'after', {}));
            Ep = runBefore(EEG, before, ctx);
            sig = pipecompare.utils.fieldOr(ctx, 'signal', []);
            Sp = [];
            if ~isempty(sig) && ~isempty(sig.S), Sp = runBefore(sig.S, before, ctx); end
            % the removed sets: none, then down the distinct values of q
            qr = q(:)';                          % as ICLabel stores them (pop_icflag compares these)
            q = double(qr);
            c = sort(unique(q(q > pipecompare.eval.IcThreshold.MinProbability)), 'descend');
            K = numel(c) + 1;                    % set 1 removes nothing, set k those with q >= c(k-1)
            hi = [1 c]; lo = [c max([0 q(q <= pipecompare.eval.IcThreshold.MinProbability)])];
            R = [{false(size(qr))} arrayfun(@(x) qr >= x, c, 'UniformOutput', false)];   % a threshold in [lo(k), hi(k)) removes R{k} (q > t)
            chans = [];
            if ~isempty(rej), chans = pipecompare.run.Steps.testedChannels(Ep, rej.params); end
            f = nan(1, K); u = nan(1, K); why = repmat({''}, 1, K); X = cell(1, K); M = cell(1, K);
            for k = 1:K
                comps = find(R{k});
                Ek = Ep; Ek.data = removeComponents(EEG, Ep.data, comps);
                g = [];
                if ~isempty(Sp)
                    Sk = Sp; Sk.data = removeComponents(EEG, Sp.data, comps);
                    r = pipecompare.eval.Injection.compare(Sk, contract, sig.truth, {});
                    g = double(r.gain(:)');
                    w = pipecompare.eval.Rank.signalReasons(r, opts);
                    if ~all(g > 0), w{end+1} = 'signal lost or inverted'; end %#ok<AGROW>
                    if ~isempty(w), why{k} = strjoin(w, '; '); end
                end
                if isempty(rej)
                    m = zeros(1, Ek.trials); v = 0;              % nothing rejected
                else
                    m = pipecompare.run.Steps.limitStat(Ek, chans, rej.params);
                    v = [];                                     % every limit (uv 'auto')
                    if ~ischar(rej.params.uv), v = rej.params.uv; end
                end
                [v, ok, obj, X{k}, M{k}] = pipecompare.eval.Threshold.curve(Ek, m, contract, ref, opts, g, v);
                if ~any(ok)
                    if isempty(why{k}), why{k} = 'too few trials kept'; end
                    continue;
                end
                F = find(ok);
                b = F(find(obj(F) == min(obj(F)), 1, 'last'));
                f(k) = obj(b); u(k) = v(b);
                if ~isempty(why{k}), f(k) = NaN; end
            end
            % per set (fewest components first): its objective at its best
            % limit (NaN: not a candidate, why says why) and the number removed
            info = struct('thresholdBest', NaN, 'thresholdChosen', NaN, 'sets', K, 'feasible', sum(isfinite(f)), ...
                'equallyGood', 0, 'objectiveBest', NaN, 'objectiveChosen', NaN, 'removedBest', 0, 'removedChosen', 0, ...
                'objectives', f, 'removed', cellfun(@sum, R), 'why', {why}, 'note', '');
            F = find(isfinite(f));
            if isempty(F)
                % no set meets the limits: remove the fewest (the ranking
                % then reports what is wrong)
                chosen = 1; best = 1;
                info.note = sprintf('no threshold meets the limits (%s); the fewest components removed', why{1});
            else
                best = F(find(f(F) == min(f(F)), 1));     % ties: fewer components
                Bq = zeros(numel(F), opts.nBoot);
                for i = 1:numel(F)
                    Bq(i, :) = pipecompare.eval.Threshold.bootstrap(X{F(i)}, M{F(i)}, u(F(i)), opts, ref);
                end
                keep = pipecompare.eval.Rank.confidenceSet(f(F)', Bq, find(F == best), opts.alpha);
                chosen = min(F(keep));
                info.equallyGood = sum(keep);
                info.objectiveBest = f(best); info.objectiveChosen = f(chosen);
            end
            t = roundIn(lo(chosen), hi(chosen), qr, R{chosen});
            info.thresholdBest = roundIn(lo(best), hi(best), qr, R{best}); info.thresholdChosen = t;
            info.removedBest = sum(R{best}); info.removedChosen = sum(R{chosen});
            pipecompare.utils.log(['ICLabel threshold chosen from the data: %g (best %g; %d different component sets, ', ...
                '%d equally good; %d of %d components removed).'], t, info.thresholdBest, K, info.equallyGood, ...
                info.removedChosen, numel(q));
        end
    end
end

function [before, rej] = splitAfter(after)
% the steps between IC removal and the epoch rejection, and that rejection
% ([] when none follows)
rej = [];
k = find(cellfun(@(in) strcmp(in.type, 'reject_threshold'), after), 1);
if isempty(k), before = after; else, before = after(1:k-1); rej = after{k}; end
for i = 1:numel(before)
    assert(any(strcmp(before{i}.type, {'epoch', 'baseline'})), 'PipeCompare:IcThreshold', ...
        'An ICLabel threshold chosen from the data needs only epoching and baseline removal before the epoch rejection (found %s).', ...
        before{i}.type);
end
end

function E = runBefore(E, before, ctx)
% the steps between IC removal and the rejection, then epochs (as the
% measure takes them) when the data are still continuous
for i = 1:numel(before)
    [~, E] = evalc('pipecompare.run.Steps.run(before{i}, E, ctx)');
end
if E.trials == 1
    [~, E] = evalc('pop_epoch(E, ctx.contract.allEvents(), ctx.contract.epoch, ''epochinfo'', ''yes'')');
end
end

function X = removeComponents(EEG, X, comps)
% the data without components comps, as pop_subcomp computes it: the
% back-projection of the components kept (nothing changes when none is
% removed: pop_subcomp is not run)
if isempty(comps), return; end
W = double(EEG.icaweights) * double(EEG.icasphere);
A = double(EEG.icawinv); if isempty(A), A = pinv(W); end
keep = setdiff(1:size(W, 1), comps);
sz = size(X); X2 = reshape(X, sz(1), []);
ch = EEG.icachansind;
X2(ch, :) = A(:, keep) * (W(keep, :) * double(X2(ch, :)));
X = reshape(X2, sz);
end

function t = roundIn(lo, hi, q, target)
% the roundest threshold in [lo, hi) (hi = 1 included: nothing has q > 1)
% that removes the components target, checked with the comparison
% pop_icflag makes (q > t)
for d = 0:12
    t = ceil(lo * 10 ^ d) / 10 ^ d;
    if (t < hi || t == 1) && isequal(q > t, target), return; end
end
t = lo;
end
