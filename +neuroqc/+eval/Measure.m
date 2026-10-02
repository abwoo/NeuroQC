classdef Measure
    %MEASURE Trial-level scores and data quality of one candidate.
    %
    %   ref = neuroqc.eval.Measure.reference(rootEEG, contract)
    %   m   = neuroqc.eval.Measure.candidate(EEG, contract, ref)
    %
    %   Every candidate is scored the same way: epoch with the contract
    %   window if still continuous, remove the contract baseline (idempotent
    %   when the pipeline already did), then take each trial's mean
    %   amplitude over each component's ROI channels and time window.
    %
    %   Data quality is the standardized measurement error (SME) of that
    %   score: SD across trials / sqrt(N), per condition and component, in
    %   microvolts (Luck et al., 2021). It falls when noise is removed and
    %   rises when trials are lost, so it prices the noise-vs-trial-count
    %   trade-off of artifact handling directly.
    %
    %   Trials are identified by the EEGLAB urevent index of their
    %   time-locking event, so the same physical trial is paired across
    %   candidates (needed for the paired bootstrap in neuroqc.eval.Rank).

    methods (Static)
        function ref = reference(EEG, contract)
            T = neuroqc.eval.Measure.trials(EEG, contract);
            ref = struct('ids', {cell(1, numel(contract.conditions))});
            for c = 1:numel(contract.conditions)
                ref.ids{c} = unique(T.id(T.cond == c))';
                assert(numel(ref.ids{c}) >= 2, 'NeuroQC:Contract', ...
                    'Condition %s has %d trial(s) in the current dataset.', contract.conditions(c).name, numel(ref.ids{c}));
            end
            ref.n = cellfun(@numel, ref.ids);
        end

        function m = candidate(EEG, contract, ref)
            T = neuroqc.eval.Measure.trials(EEG, contract);
            nC = numel(contract.conditions); nJ = numel(contract.components);
            m = struct('S', {cell(1, nC)}, 'kept', zeros(1, nC), 'retention', zeros(1, nC), ...
                'sme', nan(nC, nJ), 'composite', NaN, 'extraTrials', 0);
            for c = 1:nC
                S = nan(ref.n(c), nJ);
                rows = find(T.cond == c);
                [tf, loc] = ismember(T.id(rows), ref.ids{c});
                m.extraTrials = m.extraTrials + sum(~tf);
                rows = rows(tf); loc = loc(tf);
                [loc, first] = unique(loc, 'stable'); rows = rows(first);
                S(loc, :) = T.score(rows, :);
                m.S{c} = S;
                m.kept(c) = numel(loc);
                m.retention(c) = m.kept(c) / ref.n(c);
                m.sme(c, :) = neuroqc.eval.Measure.sme(S);
            end
            m.composite = sqrt(mean(m.sme(:) .^ 2));
        end

        function v = sme(S)
            % Analytic SME of the mean amplitude, ignoring missing trials.
            v = nan(1, size(S, 2));
            for j = 1:size(S, 2)
                x = S(~isnan(S(:, j)), j);
                if numel(x) >= 2, v(j) = std(x) / sqrt(numel(x)); end
            end
        end

        function T = trials(EEG, contract)
            % One row per epoch: urevent id, condition index, scores.
            codes = contract.allEvents();
            if EEG.trials == 1 && (~isfield(EEG, 'epoch') || isempty(EEG.epoch))
                [~, EEG] = evalc('pop_epoch(EEG, codes, contract.epoch, ''epochinfo'', ''yes'')');
            end
            assert(EEG.xmin <= contract.epoch(1) + 1.5/EEG.srate && EEG.xmax >= contract.epoch(2) - 1.5/EEG.srate, ...
                'NeuroQC:Measure', 'Epochs [%g %g] s do not cover the contract epoch.', EEG.xmin, EEG.xmax);
            times = EEG.xmin + (0:EEG.pnts-1) / EEG.srate;
            labels = lower({EEG.chanlocs.labels});
            nT = EEG.trials;
            id = nan(nT, 1); cond = zeros(nT, 1);
            tol = 1000 / EEG.srate / 2 + 1e-6; % eventlatency is in ms
            for k = 1:nT
                ep = EEG.epoch(k);
                lat = ep.eventlatency; ev = ep.event; ty = ep.eventtype;
                if ~iscell(lat), lat = num2cell(lat); end
                if ~iscell(ev), ev = num2cell(ev); end
                if ischar(ty) || isstring(ty), ty = {char(ty)}; elseif ~iscell(ty), ty = num2cell(ty); end
                for q = 1:numel(lat)
                    if abs(double(lat{q})) > tol, continue; end
                    t = strtrim(char(string(ty{q})));
                    ci = find(arrayfun(@(cd) any(strcmp(cd.events, t)), contract.conditions), 1);
                    if isempty(ci), continue; end
                    e = EEG.event(ev{q});
                    assert(isfield(e, 'urevent') && ~isempty(e.urevent), 'NeuroQC:Urevent', ...
                        'Time-locking events have no urevent index.');
                    id(k) = double(e.urevent); cond(k) = ci;
                    break;
                end
            end
            keep = cond > 0;
            % baseline removal (same window for every candidate)
            bl = times >= contract.baseline(1) - 1e-9 & times <= contract.baseline(2) + 1e-9;
            assert(any(bl), 'NeuroQC:Measure', 'No samples in the baseline window.');
            nJ = numel(contract.components);
            score = nan(nT, nJ);
            for j = 1:nJ
                comp = contract.components(j);
                [ok, roi] = ismember(lower(comp.roi), labels);
                if ~all(ok)
                    error('NeuroQC:RoiMissing', 'ROI channel(s) missing in this candidate: %s', ...
                        strjoin(comp.roi(~ok), ', '));
                end
                w = times >= comp.window(1) - 1e-9 & times <= comp.window(2) + 1e-9;
                X = double(EEG.data(roi, :, :));
                X = X - mean(X(:, bl, :), 2);
                score(:, j) = squeeze(mean(mean(X(:, w, :), 1), 2));
            end
            T = struct('id', id(keep), 'cond', cond(keep), 'score', score(keep, :));
        end
    end
end
