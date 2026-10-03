classdef DatasetInspector
    % DatasetInspector - Automated health check before preprocessing
    % Channel / time / frequency / event level QC
    
    methods (Static)
        function report = inspect(EEG, opts)
            % inspect continuous or epoched EEGLAB EEG struct
            % Returns report with per-domain status: PASS / WARNING / REVIEW / FAIL
            if nargin < 2, opts = struct(); end
            opts = neuroqc.inspect.DatasetInspector.defaultOptions(opts);
            
            report = struct();
            report.generatedAt = datetime('now');
            report.domains = struct();
            
            chReport = neuroqc.inspect.DatasetInspector.checkChannels(EEG, opts);
            timeReport = neuroqc.inspect.DatasetInspector.checkTimeDomain(EEG, opts);
            freqReport = neuroqc.inspect.DatasetInspector.checkFrequency(EEG, opts);
            evtReport = neuroqc.inspect.EventInspector.inspect(EEG, opts);
            
            report.domains.channels = chReport;
            report.domains.time = timeReport;
            report.domains.frequency = freqReport;
            report.domains.events = evtReport;
            
            report.dataRank = neuroqc.utils.estimateRank(EEG.data);
            report.overall = neuroqc.inspect.DatasetInspector.rollup({ ...
                chReport.status, timeReport.status, freqReport.status, evtReport.status});
            
            neuroqc.inspect.DatasetInspector.printReport(report);
        end
        
        function opts = defaultOptions(opts)
            defaults = struct( ...
                'flatlineTol', 1e-12, ...
                'varRatioWarn', 0.01, ...      % variance < 1% of median
                'varRatioFail', 0.001, ...
                'corrWarn', 0.3, ...            % neighbor corr below
                'lineNoiseHz', [50 60], ...
                'lineNoiseRatio', 10, ...       % peak/median PSD ratio
                'ampWarnUv', 150, ...           % peak abs amplitude warn
                'ampFailUv', 500, ...
                'maxBadChanRatio', 0.3, ...
                'transientZ', 6, ...
                'saturationTol', 1e-6);          % consecutive identical samples
            fn = fieldnames(defaults);
            for i = 1:numel(fn)
                if ~isfield(opts, fn{i})
                    opts.(fn{i}) = defaults.(fn{i});
                end
            end
        end
        
        function data = dataMicrovolts(EEG)
            % Unit normalization: all absolute thresholds (flatlineTol,
            % saturationTol, amp*Uv) live in µV space. Declared V scales up;
            % uV or undeclared keeps the legacy µV assumption. Relative
            % checks (varRatio, corr, PSD ratios, robust z) are scale-free.
            factor = 1;
            if isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && ...
                    isfield(EEG.etc.neuroqc, 'dataUnit') && ...
                    strcmpi(EEG.etc.neuroqc.dataUnit, 'V')
                factor = 1e6; % V -> µV
            end
            data = double(EEG.data) * factor;
        end

        function r = checkChannels(EEG, opts)
            raw = double(EEG.data);
            if ndims(raw) == 3
                raw = reshape(raw, size(EEG.data,1), []);
            end
            rawPeak = max(abs(raw), [], 2);
            data = neuroqc.inspect.DatasetInspector.dataMicrovolts(EEG);
            if ndims(data) == 3
                data = data(:, :);
                data = reshape(data, size(EEG.data,1), []);
            end
            [nch, ~] = size(data);
            % Tolerate missing/short/label-less chanlocs: pad to nch with ''.
            labels = cell(1, nch);
            labels(:) = {''};
            if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs) && ...
                    isfield(EEG.chanlocs, 'labels')
                L = {EEG.chanlocs.labels};
                k = min(nch, numel(L));
                labels(1:k) = L(1:k);
            end
            
            variance = var(data, 0, 2);
            medVar = median(variance(variance > 0));
            if isempty(medVar) || medVar == 0, medVar = 1; end
            
            flat = variance < opts.flatlineTol | variance < opts.varRatioFail * medVar;
            lowVar = ~flat & variance < opts.varRatioWarn * medVar;
            
            peakAbs = max(abs(data), [], 2); % µV (unit-normalized at entry)
            peakAbsUv = peakAbs;
            hiAmp = peakAbsUv > opts.ampFailUv;
            warnAmp = ~hiAmp & peakAbsUv > opts.ampWarnUv;
            
            % NaN / Inf
            badVals = any(~isfinite(data), 2);
            
            % Missing locations
            noLoc = false(nch, 1);
            if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs)
                for i = 1:nch
                    if i > numel(EEG.chanlocs) || ...
                            ~isfield(EEG.chanlocs(i), 'X') || ...
                            isempty(EEG.chanlocs(i).X) || ...
                            ~isfinite(EEG.chanlocs(i).X)
                        noLoc(i) = true;
                    end
                end
            end
            
            % Duplicate labels (only among non-empty labels; '' means
            % "unknown", not a duplicate of every other unknown).
            nonempty = find(~cellfun(@isempty, labels));
            [~, ia] = unique(labels(nonempty));
            dupLabels = nonempty(setdiff(1:numel(nonempty), ia));
            
            % Correlation-based (sample a subset for speed)
            corrBad = false(nch, 1);
            try
                step = max(1, floor(size(data,2) / 5000));
                sub = data(:, 1:step:end);
                C = corrcoef(sub');
                C(1:nch+1:end) = 0;
                meanCorr = mean(C, 2, 'omitnan');
                corrBad = meanCorr < opts.corrWarn;
            catch
            end
            
            candidateBad = flat | badVals | hiAmp;
            softBad = lowVar | warnAmp | noLoc | corrBad | ismember((1:nch)', dupLabels(:));
            
            reasons = cell(nch, 1);
            for i = 1:nch
                rs = {};
                if flat(i), rs{end+1} = 'flatline'; end %#ok<AGROW>
                if badVals(i), rs{end+1} = 'nonfinite'; end %#ok<AGROW>
                if hiAmp(i), rs{end+1} = 'amp_fail'; end %#ok<AGROW>
                if lowVar(i), rs{end+1} = 'low_variance'; end %#ok<AGROW>
                if warnAmp(i), rs{end+1} = 'amp_warn'; end %#ok<AGROW>
                if noLoc(i), rs{end+1} = 'missing_location'; end %#ok<AGROW>
                if corrBad(i), rs{end+1} = 'low_correlation'; end %#ok<AGROW>
                if ismember(i, dupLabels), rs{end+1} = 'duplicate_label'; end %#ok<AGROW>
                if isempty(rs), reasons{i} = ''; else, reasons{i} = strjoin(rs, ','); end
            end
            
            badRatio = sum(candidateBad) / nch;
            if badRatio > opts.maxBadChanRatio
                status = 'FAIL';
            elseif any(candidateBad) || any(softBad)
                status = 'WARNING';
            else
                status = 'PASS';
            end
            
            r = struct();
            r.status = status;
            r.channelCount = nch;
            r.candidateBadChannels = find(candidateBad);
            r.candidateBadLabels = labels(candidateBad);
            r.softFlags = find(softBad);
            r.softFlagLabels = labels(softBad);
            r.reasons = reasons(candidateBad | softBad);
            sel = candidateBad | softBad;
            ch = labels(sel); ch = ch(:)'; % unify to 1xK row cell
            dt = reasons(sel); dt = dt(:)';
            r.reasonMap = struct('channels', {ch}, 'detail', {dt});
            r.badRatio = badRatio;
            r.variance = variance;
            r.peakAbs = peakAbs; % µV-scale (unit-normalized) for threshold consistency
            r.peakAbsRaw = rawPeak;
            r.warnings = {};
            if badRatio > opts.maxBadChanRatio
                r.warnings{end+1} = sprintf('Bad channel ratio %.0f%% exceeds limit', 100*badRatio);
            end
            if any(flat), r.warnings{end+1} = 'Flatline channels detected'; end
            if any(hiAmp), r.warnings{end+1} = 'Severe amplitude channels detected'; end
        end
        
        function r = checkTimeDomain(EEG, opts)
            data = neuroqc.inspect.DatasetInspector.dataMicrovolts(EEG);
            if ndims(data) == 3
                data = reshape(data, size(EEG.data,1), []);
            end
            
            % Transient spikes: robust z of max |diff| per channel.
            % mad(x,1) is the median absolute deviation (the constant 1.4826
            % converts median-MAD to sigma); plain mad(x) is mean-based and
            % the constant does not apply to it.
            dmax = max(abs(diff(data, 1, 2)), [], 2);
            z = (dmax - median(dmax)) / (1.4826 * mad(dmax, 1) + eps);
            transients = z > opts.transientZ;
            
            % Saturation: long runs of identical samples
            sat = false(size(data,1), 1);
            for i = 1:size(data,1)
                sat(i) = neuroqc.inspect.DatasetInspector.hasLongRun(data(i,:), opts.saturationTol);
            end
            
            % Slow drift: very low freq power proxy via moving range
            win = min(size(data,2), max(64, round(EEG.srate * 10)));
            driftScore = zeros(size(data,1), 1);
            for i = 1:size(data,1)
                x = data(i,:);
                m = movmean(x, win);
                driftScore(i) = std(m) / (std(x) + eps);
            end
            drift = driftScore > 0.8;
            
            % Discontinuities from boundary events
            nBoundary = 0;
            if isfield(EEG, 'event') && ~isempty(EEG.event)
                for i = 1:numel(EEG.event)
                    if ischar(EEG.event(i).type) && strcmp(EEG.event(i).type, 'boundary')
                        nBoundary = nBoundary + 1;
                    end
                end
            end
            
            status = 'PASS';
            if any(transients) || any(sat) || nBoundary > 0
                status = 'WARNING';
            end
            if any(sat) && sum(sat) > 0.2 * size(data,1)
                status = 'REVIEW';
            end
            
            r = struct();
            r.status = status;
            r.transientChannels = find(transients);
            r.saturationChannels = find(sat);
            r.driftChannels = find(drift);
            r.driftScore = driftScore;
            r.boundaryCount = nBoundary;
            r.warnings = {};
            if nBoundary > 0
                r.warnings{end+1} = sprintf('%d boundary discontinuities present', nBoundary);
            end
            if any(transients), r.warnings{end+1} = 'Large transient steps detected'; end
            if any(sat), r.warnings{end+1} = 'Possible saturation / clipping detected'; end
        end
        
        function r = checkFrequency(EEG, opts)
            data = neuroqc.inspect.DatasetInspector.dataMicrovolts(EEG);
            if ndims(data) == 3
                data = reshape(data, size(EEG.data,1), []);
            end
            
            % Welch PSD on subset of channels for speed
            nch = size(data,1);
            idx = unique(round(linspace(1, nch, min(16, nch))));
            fs = EEG.srate;
            nfft = 2^nextpow2(min(4096, size(data,2)));
            faxis = (0:nfft/2) * fs / nfft;
            
            psdAll = zeros(numel(idx), numel(faxis));
            for k = 1:numel(idx)
                P = pwelch(data(idx(k), :), [], [], nfft, fs);
                psdAll(k, :) = P(:)';
            end
            medPsd = median(psdAll, 1);
            baseline = median(medPsd(faxis >= 1));
            
            lineRatios = zeros(1, numel(opts.lineNoiseHz));
            for li = 1:numel(opts.lineNoiseHz)
                fhz = opts.lineNoiseHz(li);
                [~, fi] = min(abs(faxis - fhz));
                band = max(1, fi-2):min(numel(faxis), fi+2);
                lineRatios(li) = max(medPsd(band)) / (baseline + eps);
            end
            
            % HF noise: ratio of 40-100 (or to Nyquist) vs 1-10
            loBand = medPsd(faxis >= 1 & faxis <= 10);
            hiCut = min(fs/2 - 1, 100);
            hiBand = medPsd(faxis >= min(40, hiCut) & faxis <= hiCut);
            hfRatio = mean(hiBand) / (mean(loBand) + eps);
            
            status = 'PASS';
            warnings = {};
            for li = 1:numel(opts.lineNoiseHz)
                if lineRatios(li) > opts.lineNoiseRatio
                    status = 'WARNING';
                    warnings{end+1} = sprintf('Line noise at %g Hz strong (ratio %.1f)', ...
                        opts.lineNoiseHz(li), lineRatios(li)); %#ok<AGROW>
                end
            end
            if hfRatio > 5
                if strcmp(status, 'PASS'), status = 'WARNING'; end
                warnings{end+1} = sprintf('High-frequency contamination suspected (HF/low ratio %.1f)', hfRatio);
            end
            
            r = struct();
            r.status = status;
            r.psdFreq = faxis;
            r.psdMedian = medPsd;
            r.lineNoiseHz = opts.lineNoiseHz;
            r.lineNoiseRatio = lineRatios;
            r.hfRatio = hfRatio;
            r.warnings = warnings;
        end
        
        function tf = hasLongRun(x, tol)
            tf = false;
            if numel(x) < 100, return; end
            d = abs(diff(x));
            run = 0;
            for i = 1:numel(d)
                if d(i) <= tol
                    run = run + 1;
                    if run > max(50, round(numel(x) * 0.05))
                        tf = true;
                        return;
                    end
                else
                    run = 0;
                end
            end
        end
        
        function overall = rollup(statuses)
            if any(strcmp(statuses, 'FAIL'))
                overall = 'FAIL';
            elseif any(strcmp(statuses, 'REVIEW'))
                overall = 'REVIEW';
            elseif any(strcmp(statuses, 'WARNING'))
                overall = 'WARNING';
            else
                overall = 'PASS';
            end
        end
        
        function printReport(report)
            fprintf('\n=== Initial Dataset QC: %s ===\n', report.overall);
            d = report.domains;
            fprintf('Channels:  %s  (bad flags: %d)\n', d.channels.status, numel(d.channels.candidateBadChannels));
            fprintf('Time:      %s  (boundaries: %d)\n', d.time.status, d.time.boundaryCount);
            fprintf('Frequency: %s\n', d.frequency.status);
            fprintf('Events:    %s\n', d.events.status);
            fprintf('Data rank: %d\n', report.dataRank);
            
            allW = [d.channels.warnings, d.time.warnings, d.frequency.warnings, d.events.warnings];
            if ~isempty(allW)
                fprintf('Warnings:\n');
                for i = 1:numel(allW)
                    fprintf('  - %s\n', allW{i});
                end
            end
            fprintf('\n');
        end
    end
end