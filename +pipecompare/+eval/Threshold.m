classdef Threshold
    %THRESHOLD The amplitude limit of epoch rejection chosen from the data
    %   (reject_threshold with uv = 'auto').
    %
    %   [u, info] = pipecompare.eval.Threshold.choose(EEG, m, ctx)
    %
    %   m: per epoch, the value the limit is compared with: the largest
    %   absolute value over the tested channels and the whole epoch, or
    %   with method peaktopeak the largest moving-window peak-to-peak
    %   value. An epoch is rejected when m > u. Raising u only adds epochs,
    %   so the kept sets are nested and there are only as many different
    %   ones as different values of m: every limit between two neighbouring
    %   values keeps the same epochs. The objective of the ranking (the SME
    %   of each condition's mean score, RMS over measures and conditions, or
    %   the one measure named by the objective option) is computed for
    %   every one of these sets: the exact best limit, not the best of a few
    %   limits tried. The signal gain is left out: it is the same at every
    %   limit (the known signal is the same in every epoch).
    %
    %   Only limits that keep at least minTrials trials and minRetention of
    %   the trials of every condition (the ranking's own limits) are
    %   considered. Among them, the limits whose objective the data do not
    %   distinguish from the best one's (the paired bootstrap and
    %   simultaneous intervals of the ranking, over at most MaxCompared
    %   limits spread over the range, the best included) are equally good,
    %   and the highest of them is chosen: no epoch is rejected without
    %   evidence that rejecting it makes the measure more precise. u is the
    %   roundest number among the limits that keep the same epochs.
    %
    %   The scores are those of the data at this step (the steps after it
    %   are not run): exact when nothing after it changes the scores other
    %   than the baseline, which the scores already have removed.
    %   Needs per-trial scores: mean amplitude or band power.

    properties (Constant)
        MaxCompared = 60   % limits compared by the bootstrap (spread over the range, the best included)
    end

    methods (Static)
        function [u, info] = choose(EEG, m, ctx)
            contract = ctx.contract;
            % the trials of the starting data (minRetention is a share of them);
            % without them (a preview), those at this step
            ref = pipecompare.utils.fieldOr(ctx, 'ref', []);
            if isempty(ref), ref = pipecompare.eval.Measure.reference(EEG, contract); end
            opts = pipecompare.utils.withDefaults(pipecompare.utils.fieldOr(ctx, 'rank', struct()), ...
                pipecompare.eval.Rank.defaults());
            assert(pipecompare.eval.Threshold.applies(contract), 'PipeCompare:Threshold', ...
                ['A rejection limit chosen from the data (uv = ''auto'') needs mean amplitude or band power ', ...
                 '(peak measures have no score per trial); set the limits instead (e.g. 75 | 100 | 150).']);
            name = pipecompare.eval.Rank.objectiveName(opts.objective, ref);
            use = 1:numel(ref.objectives);
            if ~strcmp(name, 'composite'), use = find(strcmp(ref.objectives, name)); end
            T = pipecompare.eval.Measure.trials(EEG, contract);
            m = double(m(:)');
            nC = numel(ref.ids); X = cell(1, nC); M = cell(1, nC);
            for c = 1:nC
                % the reference trials of condition c, in time order
                rows = find(T.cond == c);
                [tf, loc] = ismember(T.id(rows), ref.ids{c});
                rows = rows(tf); loc = loc(tf);
                [~, first] = unique(loc); rows = rows(first);     % sorted by loc: time order
                Xc = [T.data{use}];
                X{c} = Xc(rows, :) - mean(Xc(rows, :), 1);       % centred: the SD does not change
                M{c} = m(T.epoch(rows));
            end
            v = unique([M{:}]);   % one limit per kept set (keep m <= v(j))
            U = numel(v);
            assert(U > 0, 'PipeCompare:Threshold', 'No trial of the conditions is left at this step.');
            need = max(opts.minTrials, ceil(opts.minRetention * ref.n - 1e-9));
            ok = true(1, U); acc = zeros(1, U);
            for c = 1:nC
                K = double(M{c}(:) <= v);                     % trials x limits
                n = sum(K, 1);
                ok = ok & n >= max(need(c), 2);
                for o = 1:size(X{c}, 2)
                    s1 = X{c}(:, o)' * K; s2 = (X{c}(:, o) .^ 2)' * K;
                    acc = acc + max((s2 - s1 .^ 2 ./ n) ./ (n - 1), 0) ./ n;
                end
            end
            obj = sqrt(acc / (nC * size(X{1}, 2)));
            obj(~ok | ~isfinite(obj)) = NaN;
            info = struct('uvBest', NaN, 'uvChosen', NaN, 'limits', U, 'feasible', sum(ok), 'compared', 0, ...
                'equallyGood', 0, 'objectiveBest', NaN, 'objectiveChosen', NaN, 'rejectedBest', 0, 'rejectedChosen', 0, ...
                'note', '');
            nAll = numel([M{:}]);
            if ~any(ok)
                % no limit keeps enough trials: reject nothing (the ranking
                % then reports the trials missing)
                u = roundIn(v(end), 2 * v(end)); info.uvChosen = u; info.uvBest = u;
                info.note = 'no limit keeps enough trials; nothing rejected';
                return;
            end
            F = find(ok);
            best = F(find(obj(F) == min(obj(F)), 1, 'last'));   % ties: the higher limit
            pick = F;
            if numel(F) > pipecompare.eval.Threshold.MaxCompared
                pick = unique([F(round(linspace(1, numel(F), pipecompare.eval.Threshold.MaxCompared - 1))) best]);
            end
            Bq = pipecompare.eval.Threshold.bootstrap(X, M, v(pick), opts, ref);
            keep = pipecompare.eval.Rank.confidenceSet(obj(pick)', Bq, find(pick == best), opts.alpha);
            chosen = max(pick(keep));
            u = roundIn(v(chosen), nextAbove(v, chosen));
            info.uvBest = roundIn(v(best), nextAbove(v, best)); info.uvChosen = u;
            info.compared = numel(pick); info.equallyGood = sum(keep);
            info.objectiveBest = obj(best); info.objectiveChosen = obj(chosen);
            info.rejectedBest = sum([M{:}] > v(best)); info.rejectedChosen = sum([M{:}] > v(chosen));
            pipecompare.utils.log(['Rejection limit chosen from the data: %g uV (best %g uV; %d different limits, ', ...
                '%d equally good; %d/%d trials rejected).'], u, info.uvBest, U, info.equallyGood, info.rejectedChosen, nAll);
        end

        function tf = applies(contract)
            % per-trial scores exist: band power, or only mean amplitudes
            tf = strcmp(contract.analysis, 'bandpower') || ...
                (~isempty(contract.components) && all(strcmp({contract.components.measure}, 'mean')));
        end

        function Bq = bootstrap(X, M, v, opts, ref)
            % The objective at each limit v under the paired bootstrap of the
            % ranking (same resampled trials for every limit): limits x B.
            s = RandStream('mt19937ar', 'Seed', opts.seed + 202);
            segmented = isfield(ref, 'segmented') && ref.segmented;
            nC = numel(X); B = opts.nBoot;
            acc = zeros(numel(v), B);
            for c = 1:nC
                W = pipecompare.eval.Rank.resampleWeights(s, size(X{c}, 1), B, segmented);
                K = double(M{c}(:) <= v(:)');                 % trials x limits
                Nb = K' * W;
                for o = 1:size(X{c}, 2)
                    x = X{c}(:, o);
                    s1 = K' * (x .* W); s2 = K' * (x .^ 2 .* W);
                    sm2 = max((s2 - s1 .^ 2 ./ Nb) ./ (Nb - 1), 0) ./ Nb;
                    sm2(Nb < 2) = Inf;
                    acc = acc + sm2;
                end
            end
            Bq = sqrt(acc / (nC * size(X{1}, 2)));
        end
    end
end

function b = nextAbove(v, j)
% the next value of m above the limit (the same epochs are kept up to it)
if j < numel(v), b = v(j + 1); else, b = 2 * v(j); end   % above all: any limit keeps every epoch
end

function u = roundIn(a, b)
% the roundest number in [a, b): fewest significant digits
for d = -4:12
    u = ceil(a * 10 ^ d) / 10 ^ d;
    if u >= a && u < b, return; end
end
u = a;
end
