classdef Measure
    %MEASURE Trial-level scores and their measurement error, per objective.
    %
    %   ref = neuroqc.eval.Measure.reference(rootEEG, contract)
    %   m   = neuroqc.eval.Measure.candidate(EEG, contract, ref, opts)
    %
    %   Every candidate is scored the same way. Data still continuous are
    %   epoched with the contract window; the contract baseline is removed
    %   (idempotent when the pipeline already did it). Then one objective is
    %   computed per contract component:
    %
    %     mean          trial score = mean amplitude over ROI and window;
    %                   precision = analytic SME = SD / sqrt(N)  (uV)
    %     peakAmplitude precision of the peak amplitude of the averaged
    %     peakLatency   ROI waveform = bootstrapped SME (bSME: SD of the
    %                   measure over bootstrap averages; uV or ms)
    %     logpower      trial score = log10 band power (Hann-tapered FFT,
    %                   ROI mean); analytic SME (log10 uV^2)
    %
    %   (Luck, Stewart, Simmons & Rhemtulla, 2021, Psychophysiology.)
    %   SME falls when noise is removed and rises when trials are lost, so it
    %   prices the noise-vs-trial-count trade-off directly. It does NOT tell
    %   whether the signal survived; that is the job of
    %   neuroqc.eval.Injection.
    %
    %   Trials are identified by the urevent index of their time-locking
    %   event, so the same physical trial is paired across candidates.

    methods (Static)
        function o = defaults()
            o = struct('nBootPeak', 1000, 'seed', 1);
        end

        function ref = reference(EEG, contract)
            T = neuroqc.eval.Measure.trials(EEG, contract);
            conds = contract.effectiveConditions();
            ref = struct('ids', {cell(1, numel(conds))}, 'names', {{conds.name}});
            for c = 1:numel(conds)
                ref.ids{c} = unique(T.id(T.cond == c))';
                assert(numel(ref.ids{c}) >= 2, 'NeuroQC:Contract', ...
                    'Condition %s has %d eligible trial(s) in the current dataset.', conds(c).name, numel(ref.ids{c}));
            end
            ref.n = cellfun(@numel, ref.ids);
            ref.objectives = contract.objectiveNames();
            ref.units = contract.objectiveUnits();
        end

        function m = candidate(EEG, contract, ref, opts)
            if nargin < 4, opts = struct(); end
            opts = withDefaults(opts, neuroqc.eval.Measure.defaults());
            T = neuroqc.eval.Measure.trials(EEG, contract);
            nC = numel(ref.ids); nO = numel(ref.objectives);
            m = struct('kept', zeros(1, nC), 'retention', zeros(1, nC), 'extraTrials', 0, ...
                'objectives', [], 'composite', NaN);
            % align rows of every condition to the reference trial ids
            rowOf = cell(1, nC);
            for c = 1:nC
                rows = find(T.cond == c);
                [tf, loc] = ismember(T.id(rows), ref.ids{c});
                m.extraTrials = m.extraTrials + sum(~tf);
                rows = rows(tf); loc = loc(tf);
                [loc, first] = unique(loc, 'stable'); rows = rows(first);
                rowOf{c} = struct('rows', rows, 'loc', loc);
                m.kept(c) = numel(loc);
                m.retention(c) = m.kept(c) / ref.n(c);
            end
            objs = repmat(struct('name', '', 'unit', '', 'kind', '', 'polarity', '', 'times', [], ...
                'X', {{}}, 'estimate', [], 'sme', [], 'agg', NaN), 1, nO);
            for k = 1:nO
                o = objs(k);
                o.name = ref.objectives{k}; o.unit = ref.units{k};
                [o.kind, o.polarity] = objKind(contract, k);
                o.times = T.times{k};
                o.X = cell(1, nC); o.estimate = nan(1, nC); o.sme = nan(1, nC);
                for c = 1:nC
                    X = nan(ref.n(c), size(T.data{k}, 2));
                    X(rowOf{c}.loc, :) = T.data{k}(rowOf{c}.rows, :);
                    o.X{c} = X;
                    [o.estimate(c), o.sme(c)] = neuroqc.eval.Measure.estimate(o, X, opts, k * 1000 + c);
                end
                o.agg = sqrt(mean(o.sme .^ 2));
                objs(k) = o;
            end
            m.objectives = objs;
            if numel(unique(ref.units)) == 1
                m.composite = sqrt(mean([objs.sme] .^ 2));
            end
        end

        function v = sme(S)
            % Analytic SME of a mean score per column, ignoring missing (NaN) trials.
            v = nan(1, size(S, 2));
            for j = 1:size(S, 2)
                x = S(~isnan(S(:, j)), j);
                if numel(x) >= 2, v(j) = std(x) / sqrt(numel(x)); end
            end
        end

        function [est, sme] = estimate(o, X, opts, salt)
            % Point estimate and its SME for one condition.
            keep = ~isnan(X(:, 1)); Y = X(keep, :); n = size(Y, 1);
            est = NaN; sme = NaN;
            if n < 2, return; end
            switch o.kind
                case 'scalar'
                    est = mean(Y); sme = std(Y) / sqrt(n);
                otherwise
                    est = peakOf(mean(Y, 1), o);
                    s = RandStream('mt19937ar', 'Seed', opts.seed + salt);
                    idx = randi(s, n, n, opts.nBootPeak);
                    W = full(sparse(idx, repmat(1:opts.nBootPeak, n, 1), 1, n, opts.nBootPeak));
                    avgs = (W' * Y) / n;
                    sme = std(peakOf(avgs, o));
            end
        end

        function v = smeBoot(o, Wc, opts, salt, scale)
            % SME of objective o under each outer bootstrap draw (paired:
            % Wc{c} holds the same trial counts for every candidate).
            % scale(c) rescales condition c (half-samples -> full sample).
            % Returns 1 x B, RMS over conditions.
            if nargin < 5, scale = ones(1, numel(Wc)); end
            B = size(Wc{1}, 2); acc = zeros(1, B);
            for c = 1:numel(Wc)
                X = o.X{c}; M = double(~isnan(X(:, 1))); X0 = X; X0(isnan(X0)) = 0;
                Nb = M' * Wc{c};
                if strcmp(o.kind, 'scalar')
                    s1 = X0' * Wc{c}; s2 = (X0 .^ 2)' * Wc{c};
                    sm2 = max((s2 - s1 .^ 2 ./ Nb) ./ (Nb - 1), 0) ./ Nb;
                else
                    % nested bootstrap: bSME within each outer draw
                    sm2 = zeros(1, B);
                    s = RandStream('mt19937ar', 'Seed', opts.seed + salt + c);
                    Bin = opts.nBootPeakInner; keep = find(M);
                    for b = 1:B
                        w = Wc{c}(keep, b); n = sum(w);
                        if n < 2, sm2(b) = Inf; continue; end
                        nz = w > 0; kk = keep(nz); w = w(nz);
                        edges = [0; cumsum(w(:)) / n]; edges(end) = 1;
                        pick = discretize(rand(s, n, Bin), edges);   % index into kk
                        Win = full(sparse(pick, repmat(1:Bin, n, 1), 1, numel(kk), Bin));
                        avgs = (Win' * X(kk, :)) / n;
                        sm2(b) = var(peakOf(avgs, o));
                    end
                end
                sm2(:, Nb < 2) = Inf;
                acc = acc + sm2 * scale(c) ^ 2;
            end
            v = sqrt(acc / numel(Wc));
        end

        function T = trials(EEG, contract)
            % One row per epoch: urevent id, condition index, per-objective data.
            conds = contract.effectiveConditions();
            codes = contract.allEvents();
            win = contract.effectiveEpoch();
            if EEG.trials == 1 && (~isfield(EEG, 'epoch') || isempty(EEG.epoch))
                [~, EEG] = evalc('pop_epoch(EEG, codes, win, ''epochinfo'', ''yes'')');
            end
            tol = 1.5 / EEG.srate;
            assert(EEG.xmin <= win(1) + tol && EEG.xmax >= win(2) - tol, ...
                'NeuroQC:Measure', 'Epochs [%g %g] s do not cover the contract epoch [%g %g] s.', EEG.xmin, EEG.xmax, win);
            times = EEG.xmin + (0:EEG.pnts-1) / EEG.srate;
            labels = lower({EEG.chanlocs.labels});
            nT = EEG.trials;
            id = nan(nT, 1); cond = zeros(nT, 1);
            eligible = [];
            if isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && isfield(EEG.etc.neuroqc, 'eligibleUrevents')
                eligible = EEG.etc.neuroqc.eligibleUrevents;
            end
            halfSample = 1000 / EEG.srate / 2 + 1e-6; % eventlatency is in ms
            for k = 1:nT
                ep = EEG.epoch(k);
                lat = cellify(ep.eventlatency); ev = cellify(ep.event); ty = ep.eventtype;
                if ischar(ty) || isstring(ty), ty = {char(ty)}; elseif ~iscell(ty), ty = num2cell(ty); end
                for q = 1:numel(lat)
                    if abs(double(lat{q})) > halfSample, continue; end
                    t = strtrim(char(string(ty{q})));
                    ci = find(arrayfun(@(cd) any(strcmp(cd.events, t)), conds), 1);
                    if isempty(ci), continue; end
                    e = EEG.event(ev{q});
                    assert(isfield(e, 'urevent') && ~isempty(e.urevent), 'NeuroQC:Urevent', ...
                        'Time-locking events have no urevent index.');
                    if ~isempty(eligible) && ~ismember(double(e.urevent), eligible), break; end
                    id(k) = double(e.urevent); cond(k) = ci;
                    break;
                end
            end
            keep = cond > 0;
            data = double(EEG.data(:, :, keep));
            bl = contract.effectiveBaseline();
            T = struct('id', id(keep), 'cond', cond(keep), 'data', {{}}, 'times', {{}}, ...
                'labels', {labels});
            if ~isempty(bl)
                bsel = times >= bl(1) - 1e-9 & times <= bl(2) + 1e-9;
                assert(any(bsel), 'NeuroQC:Measure', 'No samples in the baseline window.');
                data = data - mean(data(:, bsel, :), 2);
            end
            for j = 1:numel(contract.components)
                comp = contract.components(j);
                roi = roiIndex(comp.roi, labels);
                w = times >= comp.window(1) - 1e-9 & times <= comp.window(2) + 1e-9;
                wave = permute(mean(data(roi, w, :), 1), [3 2 1]);   % trials x samples
                if size(wave, 2) ~= sum(w), wave = reshape(wave, [], sum(w)); end
                if strcmp(comp.measure, 'mean')
                    T.data{j} = mean(wave, 2);
                else
                    T.data{j} = wave;
                end
                T.times{j} = 1000 * times(w);
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

function c = cellify(x)
if iscell(x), c = x; else, c = num2cell(x); end
end

function idx = roiIndex(roi, labels)
[ok, idx] = ismember(lower(roi), labels);
if ~all(ok)
    error('NeuroQC:RoiMissing', 'ROI channel(s) missing in this candidate: %s', strjoin(roi(~ok), ', '));
end
end

function [kind, pol] = objKind(contract, k)
pol = '';
comp = contract.components(k);
pol = comp.polarity;
switch comp.measure
    case 'mean', kind = 'scalar';
    otherwise, kind = comp.measure;
end
end

function v = peakOf(avgs, o)
% avgs: draws x samples. Peak of each averaged waveform.
if strcmp(o.polarity, 'negative'), [a, i] = min(avgs, [], 2); else, [a, i] = max(avgs, [], 2); end
if strcmp(o.kind, 'peakLatency'), v = reshape(o.times(i), [], 1); else, v = a; end
end

