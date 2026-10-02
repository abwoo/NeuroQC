classdef SyntheticInjection
    % SyntheticInjection - Known-amplitude/latency ERP injection for preservation validation
    methods (Static)
        function [EEG, truth] = generate(opts)
            if nargin < 1, opts = struct(); end
            defaults = struct( ...
                'srate', 250, ...
                'durationSec', 60, ...
                'nChannels', 32, ...
                'seed', 42, ...
                'nTarget', 30, ...
                'nStandard', 60, ...
                'p300Uv', 8, ...
                'p300LatencyMs', 300, ...
                'p300WidthMs', 50, ...
                'noiseUv', 3, ...
                'labels', []);
            fn = fieldnames(defaults);
            for i = 1:numel(fn)
                if ~isfield(opts, fn{i}), opts.(fn{i}) = defaults.(fn{i}); end
            end

            [EEG, base] = neuroqc.inspect.SyntheticEEG.generate(struct( ...
                'srate', opts.srate, 'durationSec', opts.durationSec, ...
                'nChannels', opts.nChannels, 'seed', opts.seed, ...
                'nTarget', opts.nTarget, 'nStandard', opts.nStandard, ...
                'p300Uv', opts.p300Uv, 'noiseUv', opts.noiseUv, ...
                'lineNoiseUv', 0, 'driftUv', 0, 'blinkRateHz', 0));

            truth = struct();
            truth.referenceSource = 'synthetic_truth';
            truth.p300LatencyMs = opts.p300LatencyMs;
            truth.p300Uv = opts.p300Uv;
            truth.p300WidthMs = opts.p300WidthMs;
            truth.seed = opts.seed;
            truth.conditionNames = {'target','standard'};
            if isstruct(base) && isfield(base, 'conditionNames')
                truth.conditionNames = base.conditionNames;
            end

            % Re-stamp known-latency P300 on target events for a clean truth marker
            fs = EEG.srate;
            lat0 = round(opts.p300LatencyMs/1000 * fs);
            w = max(3, round(opts.p300WidthMs/1000 * fs));
            sigma = w/4;
            nch = EEG.nbchan;
            labels = arrayfun(@(k) EEG.chanlocs(k).labels, 1:nch, 'UniformOutput', false);
            roi = find(ismember(upper(string(labels)), ["PZ","CPZ","CZ","PZ","FPZ","FZ"]));
            if isempty(roi), roi = 1:min(4, nch); end
            for e = 1:numel(EEG.event)
                if ~strcmp(char(string(EEG.event(e).type)), 's1002')
                    continue;
                end
                onset = round(EEG.event(e).latency);
                peak = onset + lat0;
                if peak + w > size(EEG.data, 2) || peak - w < 1
                    continue;
                end
                tt = (-2*w:2*w);
                bump = opts.p300Uv * 1e-6 * exp(-0.5 * ((tt - 0)/sigma).^2);
                for c = roi
                    seg = peak + tt;
                    valid = seg >= 1 & seg <= size(EEG.data, 2);
                    EEG.data(c, seg(valid)) = EEG.data(c, seg(valid)) + bump(valid);
                end
            end
            truth.roiLabels = labels(roi);
            EEG.etc.neuroqc.truth = truth;
        end

        function contract = defaultContract()
            contract = neuroqc.contract.AnalysisContract();
            contract.paradigm = 'oddball';
            contract = contract.addCondition('target', {'s1002'}, 'target');
            contract = contract.addCondition('standard', {'s1001'}, 'standard');
            contract = contract.setEpoch(-0.2, 1.0);
            contract = contract.setBaseline(-0.2, 0);
            contract = contract.addComponent('P300', [0.30 0.60], {'Pz','CPz','Cz'}, 'mean');
            contract.ignoreEvents = {'boundary'};
        end

        function report = validateRun(candidateEEG, truth, contract, opts)
            % High-level: build reference from injection metadata + candidate ERP
            if nargin < 4, opts = struct(); end
            ref = neuroqc.preserve.PreservationReference.fromTruth(truth, contract);
            report = neuroqc.preserve.FeaturePreservation.evaluate(candidateEEG, ref, contract, opts);
            % Temporal wave reference: use contract component windows vs clean truth shape
            % (full ROI waveform reference requires epoched ground-truth average; mark partial)
            if strcmp(report.featurePreservation, 'SYNTHETIC_VALIDATED') && ...
                    strcmp(report.temporal.status, 'NO_WAVEFORM')
                report.temporal = struct('status','PARTIAL', ...
                    'note', 'Truth metadata available; ROI waveform reference not epoched in this call');
            end
        end
    end
end
