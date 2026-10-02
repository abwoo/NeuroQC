classdef FeaturePreservation
    % FeaturePreservation - Aggregates temporal/spatial/spectral/event/rank/condition fidelity
    % Display-only by default: enforce=false means metrics never gate HardConstraints.
    % featurePreservation status: NOT_VALIDATED | REFERENCE_MINIMAL | SYNTHETIC_VALIDATED

    methods (Static)
        function report = evaluate(candidateEEG, reference, contract, opts)
            % candidateEEG: processed EEG (epoched preferred)
            % reference: PreservationReference or struct with fields:
            %   .sourceEEG (minimal/synthetic epoched) OR .truth struct
            % opts.enforce (default false) — display only
            if nargin < 4, opts = struct(); end
            if ~isfield(opts,'enforce'), opts.enforce = false; end

            report = struct();
            report.status = 'NOT_RUN';
            report.featurePreservation = 'NOT_VALIDATED';
            report.enforce = logical(opts.enforce);
            report.referenceSource = 'not_available';
            report.temporal = struct('status','NOT_RUN');
            report.spatial = struct('status','NOT_RUN');
            report.spectral = struct('status','NOT_RUN');
            report.event = struct('status','NOT_RUN');
            report.rank = struct('status','NOT_RUN');
            report.conditionBalance = struct('status','NOT_RUN');
            report.gateReasons = {};
            report.gateOk=~opts.enforce;
            if opts.enforce, report.gateReasons={'missing_preservation_reference'}; end

            if nargin < 3 || isempty(reference)
                report.status = 'NO_REFERENCE';
                report.notes = 'No preservation reference supplied';
                return;
            end
            if isa(reference, 'neuroqc.preserve.PreservationReference')
                ref = reference;
            else
                ref = neuroqc.preserve.PreservationReference.unavailable('inline ref');
            end
            report.referenceSource = ref.referenceSource;

            if ~ref.usable()
                report.status = 'NO_REFERENCE';
                report.notes = ref.notes;
                return;
            end

            % --- Event / condition balance (from candidate quality fields if present) ---
            q = [];
            if isfield(opts, 'quality'), q = opts.quality; end
            report.event = neuroqc.preserve.FeaturePreservation.eventFidelity(candidateEEG, q);
            report.conditionBalance = neuroqc.preserve.FeaturePreservation.conditionBalance(q);
            report.rank = neuroqc.preserve.FeaturePreservation.rankFidelity(candidateEEG, opts);

            % --- Temporal / spatial / spectral vs reference EEG or precomputed maps ---
            candWave = neuroqc.preserve.FeaturePreservation.roiWave(candidateEEG, contract);
            refWave = [];
            refMap = [];
            candMap = [];
            if isa(reference,'neuroqc.preserve.PreservationReference') && ~isempty(reference.sourceEEG)
                refWave = neuroqc.preserve.FeaturePreservation.roiWave(reference.sourceEEG, contract);
                refMap = neuroqc.preserve.FeaturePreservation.componentMap(reference.sourceEEG, contract);
            elseif isstruct(reference) && isfield(reference, 'roiWave')
                refWave = reference;
            end
            candMap = neuroqc.preserve.FeaturePreservation.componentMap(candidateEEG, contract);

            if ~isempty(candWave) && ~isempty(refWave)
                report.temporal = neuroqc.preserve.TemporalFidelity.evaluate(candWave, refWave, contract);
            else
                report.temporal = struct('status','NO_WAVEFORM');
            end
            if ~isempty(candMap) && ~isempty(refMap)
                labels = {};
                if isstruct(reference) && isfield(reference, 'labels')
                    labels = reference.labels;
                end
                report.spatial = neuroqc.preserve.SpatialFidelity.evaluate(candMap, refMap, labels);
            else
                report.spatial = struct('status','NO_MAP');
            end
            if ~isempty(candWave) && ~isempty(refWave)
                report.spectral = neuroqc.preserve.SpectralFidelity.evaluate(candWave, refWave, [1 10]);
            else
                report.spectral = struct('status','NO_WAVEFORM');
            end

            % --- Status machine ---
            measured=isfield(report.temporal,'maxAmplitudeError') && isfield(report.temporal,'maxLatencyShiftMs') && ...
                isfield(report.spatial,'topoFidelity') && all(isfinite([report.temporal.maxAmplitudeError report.temporal.maxLatencyShiftMs report.spatial.topoFidelity]));
            if measured
                report.featurePreservation='REFERENCE_COMPARED'; report.status='MEASURED';
            else
                report.featurePreservation='NOT_VALIDATED'; report.status='INSUFFICIENT_REFERENCE';
            end

            % --- Optional gate (default OFF per product decision) ---
            if opts.enforce
                defaults = struct('maxLatencyShiftMs',10,'maxAmplitudeError',0.15,'minTopoFidelity',0.85);
                lim = defaults;
                if isfield(opts,'limits')
                    fn = fieldnames(opts.limits);
                    for i=1:numel(fn)
                        if isfield(defaults, fn{i}), lim.(fn{i}) = opts.limits.(fn{i}); end
                    end
                end
                reasons = {};
                if ~measured, reasons={'missing_preservation_metrics'}; end
                if isfield(report.temporal, 'maxLatencyShiftMs') && ...
                        isfinite(report.temporal.maxLatencyShiftMs) && ...
                        report.temporal.maxLatencyShiftMs > lim.maxLatencyShiftMs
                    reasons{end+1} = sprintf('latencyShift=%.1fms', report.temporal.maxLatencyShiftMs); %#ok<AGROW>
                end
                if isfield(report.temporal, 'maxAmplitudeError') && ...
                        isfinite(report.temporal.maxAmplitudeError) && ...
                        report.temporal.maxAmplitudeError > lim.maxAmplitudeError
                    reasons{end+1} = sprintf('amplitudeError=%.2f', report.temporal.maxAmplitudeError); %#ok<AGROW>
                end
                if isfield(report.spatial, 'topoFidelity') && ...
                        isfinite(report.spatial.topoFidelity) && ...
                        report.spatial.topoFidelity < lim.minTopoFidelity
                    reasons{end+1} = sprintf('topoFidelity=%.2f', report.spatial.topoFidelity); %#ok<AGROW>
                end
                report.gateReasons = reasons;
                report.gateOk = isempty(reasons);
            else
                report.gateOk = true;
                report.gateReasons = {};
            end
        end

        function w = roiWave(EEG, contract)
            w = [];
            if isempty(EEG) || isempty(contract) || isempty(contract.components)
                return;
            end
            if EEG.trials <= 1
                return; % need epoched averages for component windows
            end
            % Mean ERP across trials: chan x time
            X = double(EEG.data);
            if ndims(X) == 3
                erp = mean(X, 3);
            else
                erp = X;
            end
            times = (0:EEG.pnts-1)/EEG.srate + EEG.xmin;
            roi = contract.targetChannels;
            if isempty(roi)
                roi = {EEG.chanlocs.labels};
            end
            labels = upper(string({EEG.chanlocs.labels}'));
            roiU = upper(string(roi(:)));
            idx = find(ismember(labels, roiU));
            if isempty(idx)
                return;
            end
            % ROI mean waveform + component windows metadata
            waves = erp(idx, :);
            roiWaveVal = mean(waves, 1);
            w = struct('times', times, 'roiWave', roiWaveVal, 'erpByChan', waves, ...
                'componentWindows', {arrayfun(@(c) c.window, contract.components, 'UniformOutput', false)});
        end

        function m = componentMap(EEG, contract)
            m = [];
            if isempty(EEG) || isempty(contract) || isempty(contract.components)
                return;
            end
            if EEG.trials <= 1
                return;
            end
            X = double(EEG.data);
            if ndims(X) == 3
                erp = mean(X, 3);
            else
                erp = X;
            end
            times = (0:EEG.pnts-1)/EEG.srate + EEG.xmin;
            % Map: nChan x nComponent (mean amplitude in each component window)
            nC = numel(contract.components);
            m = nan(EEG.nbchan, nC);
            for k = 1:nC
                w = contract.components(k).window;
                sel = times >= w(1) & times <= w(2);
                if any(sel)
                    m(:, k) = mean(erp(:, sel), 2);
                end
            end
        end

        function e = eventFidelity(EEG, q)
            e = struct('status','NOT_RUN','eventLoss',NaN,'perCondition',[]);
            if ~isempty(q) && isstruct(q) && isfield(q, 'eventLoss')
                e.eventLoss = logical(q.eventLoss);
                e.status = 'FROM_QUALITY';
            elseif ~isempty(EEG) && isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && ...
                    isfield(EEG.etc.neuroqc, 'selection')
                sel = EEG.etc.neuroqc.selection;
                e.status = 'FROM_SELECTION';
                e.selected = numel(sel.selectedSourceIds);
                e.retained = EEG.trials;
            end
        end

        function c = conditionBalance(q)
            c = struct('status','NOT_RUN','spread',NaN,'minRetention',NaN);
            if ~isempty(q) && isstruct(q)
                if isfield(q, 'conditionRetentionSpread')
                    c.spread = q.conditionRetentionSpread;
                    c.status = 'FROM_QUALITY';
                end
                if isfield(q, 'minConditionRetention')
                    c.minRetention = q.minConditionRetention;
                end
            end
        end

        function r = rankFidelity(EEG, opts)
            r = struct('status','NOT_RUN','rank',NaN,'referenceRank',NaN,'delta',NaN);
            if isempty(EEG)
                return;
            end
            try
                r.rank = neuroqc.utils.estimateRank(EEG.data);
                r.status = 'RUN';
            catch
                return;
            end
            if nargin >= 2 && isstruct(opts) && isfield(opts, 'referenceRank') && ...
                    isfinite(opts.referenceRank)
                r.referenceRank = opts.referenceRank;
                r.delta = r.rank - r.referenceRank;
            end
        end

        function report = attachToQuality(q, report)
            % Convenience: copy display fields onto quality struct (value copy)
            q.preservation = report;
            q.featurePreservation = report.featurePreservation;
            if isfield(report, 'temporal') && isfield(report.temporal, 'maxLatencyShiftMs')
                q.latencyShiftMs = report.temporal.maxLatencyShiftMs;
            end
            if isfield(report, 'temporal') && isfield(report.temporal, 'maxAmplitudeError')
                q.amplitudeError = report.temporal.maxAmplitudeError;
            end
            if isfield(report, 'spatial') && isfield(report.spatial, 'topoFidelity')
                q.topoFidelity = report.spatial.topoFidelity;
            end
            report = q; % misuse avoidance: callers should use fields directly
        end
    end
end
