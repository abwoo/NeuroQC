classdef ERPAnalyzer
    % ERPAnalyzer - ERP computation, QC, SNR, reliability, bootstrap
    % NEVER optimizes for condition difference significance
    
    methods (Static)
        function result = analyze(EEG, contract, opts)
            % Full ERP analysis for all contract conditions/components
            if nargin < 3, opts = struct(); end
            if ~isfield(opts, 'nSplits'), opts.nSplits = 100; end
            if ~isfield(opts, 'nBoot'), opts.nBoot = 1000; end
            if ~isfield(opts, 'seed'), opts.seed = 42; end
            
            result = struct();
            result.contractSubject = contract.subject;
            result.conditions = struct();
            result.components = struct();
            result.differenceWaves = struct();
            result.notes = {};
            
            if EEG.trials <= 1
                error('NeuroQC:ERPNeedsEpoched', 'ERP analysis requires epoched data');
            end
            
            labels = {EEG.chanlocs.labels};
            times = (0:EEG.pnts-1) / EEG.srate + EEG.xmin;
            
            % Per-condition ERP
            condTypes = containers.Map();
            for ci = 1:numel(contract.conditions)
                cond = contract.conditions(ci);
                sel = false(1, EEG.trials);
                types = neuroqc.erpERPAnalyzer_types(EEG);
                for ei = 1:numel(cond.events)
                    sel = sel | strcmp(types, cond.events{ei});
                end
                condTypes(cond.name) = sel;
                
                cr = struct();
                cr.nTrials = sum(sel);
                if cr.nTrials == 0
                    cr.status = 'FAIL';
                    result.conditions.(cond.name) = cr;
                    result.notes{end+1} = sprintf('Condition %s has 0 trials', cond.name);
                    continue;
                end
                
                sub = double(EEG.data(:, :, sel));
                erp = mean(sub, 3);
                sem = std(sub, 0, 3) / sqrt(cr.nTrials);
                
                cr.erp = erp;
                cr.sem = sem;
                cr.times = times;
                cr.labels = labels;
                
                % Baseline SD: std of baseline samples (noise proxy).
                % Note: baseline correction removes per-trial mean, not variance.
                if contract.baseline.start < contract.baseline.end
                    bsel = times >= contract.baseline.start & times <= contract.baseline.end;
                    cr.baselineSd = std(sub(:, bsel, :), 0, 'all');
                else
                    % Degenerate baseline window (start==end): std over the ERP
                    % is signal spread, not a noise estimate. Report unknown
                    % instead of a misleading number.
                    cr.baselineSd = NaN;
                end
                cr.baselineSdUv = cr.baselineSd * 1e6;
                
                cr.status = 'PASS';
                result.conditions.(cond.name) = cr;
            end
            
            % Difference wave (first - second) if exactly 2 conditions
            cn = contract.conditionNames;
            if numel(cn) == 2 && isfield(result.conditions, cn{1}) && isfield(result.conditions, cn{2})
                if result.conditions.(cn{1}).nTrials > 0 && result.conditions.(cn{2}).nTrials > 0
                    dw = struct();
                    dw.name = sprintf('%s - %s', cn{1}, cn{2});
                    dw.wave = result.conditions.(cn{1}).erp - result.conditions.(cn{2}).erp;
                    dw.times = times;
                    result.differenceWaves.primary = dw;
                end
            end
            
            % Component metrics
            for ci = 1:numel(contract.components)
                comp = contract.components(ci);
                cr = struct();
                cr.name = comp.name;
                cr.window = comp.window;
                cr.roi = comp.roi;
                
                wsel = times >= comp.window(1) & times <= comp.window(2);
                if ~any(wsel)
                    cr.status = 'FAIL';
                    result.components.(comp.name) = cr;
                    continue;
                end
                
                % ROI channel indices
                if isempty(comp.roi)
                    roiIdx = 1:EEG.nbchan;
                else
                    assert(all(ismember(lower(string(comp.roi)),lower(string(labels)))),'NeuroQC:MissingROI','Required ROI channel missing after preprocessing');
                    roiIdx = find(ismember(lower(string(labels)), lower(string(comp.roi))));
                end
                
                % Per-condition component metrics
                cr.byCondition = struct();
                fn = fieldnames(result.conditions);
                for k = 1:numel(fn)
                    c = result.conditions.(fn{k});
                    if ~isfield(c, 'erp'), continue; end
                    w = c.erp(roiIdx, wsel);
                    cm = struct();
                    cm.meanAmplitudeUv = mean(w, 'all') * 1e6;
                    cm.peakAmplitudeUv = max(w, [], 'all') * 1e6;
                    cm.minAmplitudeUv = min(w, [], 'all') * 1e6;
                    if strcmpi(comp.type, 'negative')
                        cm.peakAmplitudeUv = min(w, [], 'all') * 1e6;
                        tw = w;
                        [~, lin] = min(tw(:));
                    else
                        tw = w;
                        [~, lin] = max(tw(:));
                    end
                    [rch, tch] = ind2sub(size(tw), lin);
                    cm.peakLatencyMs = times(wsel) * 1000;
                    cm.peakLatencyMs = cm.peakLatencyMs(tch);
                    cm.nTrials = c.nTrials;
                    cm.baselineSdUv = c.baselineSdUv;
                    
                    % SNR definition (explicit):
                    % SNR_mean = |mean amplitude in window| / baseline SD.
                    % Non-finite/zero baseline (degenerate window) -> SNR is
                    % undefined: report NaN instead of |mean|/eps, which would
                    % fabricate a huge number out of a missing baseline.
                    if isfinite(c.baselineSd) && c.baselineSd > 0
                        snrMean = abs(mean(w, 'all')) / c.baselineSd;
                    else
                        snrMean = NaN;
                    end
                    cm.snrDefinition = 'abs(window_mean) / baseline_SD';
                    cm.snrMean = snrMean;
                    
                    % SNR_peak: peak deviation / baseline SD
                    if ~isfinite(c.baselineSd) || c.baselineSd <= 0
                        cm.snrPeak = NaN;
                    elseif strcmpi(comp.type, 'negative')
                        cm.snrPeak = abs(cm.minAmplitudeUv * 1e-6) / c.baselineSd;
                    else
                        cm.snrPeak = abs(cm.peakAmplitudeUv * 1e-6) / c.baselineSd;
                    end
                    cm.snrPeakDefinition = 'abs(peak_amplitude) / baseline_SD';
                    
                    cr.byCondition.(fn{k}) = cm;
                end
                
                % Split-half reliability — per condition (not "most trials")
                % Primary = first contract condition with enough N (often target).
                cr.reliabilityByCondition = struct();
                primaryCond = '';
                for k = 1:numel(fn)
                    cn = fn{k};
                    if ~isfield(result.conditions.(cn), 'erp'), continue; end
                    nC = result.conditions.(cn).nTrials;
                    if nC < 8
                        cr.reliabilityByCondition.(cn) = struct('status', 'LOW_N', 'medianCorrelation', NaN);
                        continue;
                    end
                    sub = double(EEG.data(:, :, condTypes(cn)));
                    rel = neuroqc.erp.ERPAnalyzer.splitHalf(sub, wsel, roiIdx, opts.nSplits, opts.seed);
                    cr.reliabilityByCondition.(cn) = rel;
                    if isempty(primaryCond)
                        primaryCond = cn;
                    end
                end
                if isempty(primaryCond)
                    cr.reliability = struct('status', 'LOW_N', 'medianCorrelation', NaN);
                else
                    cr.reliability = cr.reliabilityByCondition.(primaryCond);
                    cr.reliabilityCondition = primaryCond;
                end

                % Bootstrap CI on primary condition mean amplitude
                if ~isempty(primaryCond)
                    sub = double(EEG.data(:, :, condTypes(primaryCond)));
                    boot = neuroqc.erp.ERPAnalyzer.bootstrapMeanAmp(sub, wsel, roiIdx, opts.nBoot, opts.seed);
                    cr.bootstrap = boot;
                    cr.bootstrapCondition = primaryCond;
                end

                cr.topoByCondition=struct();
                for ci=1:numel(fn)
                    cn=fn{ci};
                    if result.conditions.(cn).nTrials>=8
                        sub=double(EEG.data(:,:,condTypes(cn)));
                        cr.topoByCondition.(cn)=neuroqc.erp.ERPAnalyzer.topoStability(sub,wsel,opts.nSplits,opts.seed);
                    else
                        cr.topoByCondition.(cn)=struct('medianSpatialCorrelation',NaN);
                    end
                end
                % Topographic stability on primary condition
                if ~isempty(primaryCond)
                    sub = double(EEG.data(:, :, condTypes(primaryCond)));
                    topo = neuroqc.erp.ERPAnalyzer.topoStability(sub, wsel, opts.nSplits, opts.seed);
                    cr.topoStability = topo;
                    cr.topoStabilityCondition = primaryCond;
                end
                
                cr.status = neuroqc.erp.ERPAnalyzer.componentStatus(cr);
                result.components.(comp.name) = cr;
            end
            
            % Overall QC rollup
            sts = {};
            fn = fieldnames(result.components);
            for k = 1:numel(fn)
                if isfield(result.components.(fn{k}), 'status')
                    sts{end+1} = result.components.(fn{k}).status; %#ok<AGROW>
                end
            end
            result.status = neuroqc.qc.QCEngine.rollup(sts);
        end
        
        function rel = splitHalf(sub, wsel, roiIdx, nSplits, seed)
            % sub: chan x time x trials
            % Reliability = median split-half correlation of ROI-mean
            % waveform time course in the component window.
            n = size(sub, 3);
            rng(seed, 'twister');
            cors = nan(nSplits, 1);
            for s = 1:nSplits
                p = randperm(n);
                half = max(2, floor(n/2));
                iA = p(1:half);
                iB = p(half+1:min(n, 2*half));
                if numel(iB) < 2, break; end
                eA = mean(sub(:, wsel, iA), 3);
                eB = mean(sub(:, wsel, iB), 3);
                wA = mean(eA(roiIdx, :), 1);
                wB = mean(eB(roiIdx, :), 1);
                if std(wA) > 0 && std(wB) > 0
                    cors(s) = corr(wA(:), wB(:));
                else
                    cors(s) = NaN; % flat half: correlation undefined (not 0)
                end
            end
            % Amplitude reliability: correlation of per-half window mean amplitudes
            % (recompute properly across splits)
            rng(seed, 'twister');
            ampsA = zeros(nSplits, 1);
            ampsB = zeros(nSplits, 1);
            for s = 1:nSplits
                p = randperm(n);
                half = max(2, floor(n/2));
                iA = p(1:half);
                iB = p(half+1:min(n, 2*half));
                if numel(iB) < 2, break; end
                ampsA(s) = mean(mean(sub(roiIdx, wsel, iA), 3), 'all');
                ampsB(s) = mean(mean(sub(roiIdx, wsel, iB), 3), 'all');
            end
            % Keep genuine zero correlations (they are real evidence); drop
            % only undefined splits (NaN from flat halves / break).
            valid = isfinite(cors);
            cors = cors(valid);
            if ~isempty(cors) && std(ampsA) > 0 && std(ampsB) > 0
                ampCorsVal = corr(ampsA, ampsB);
            else
                ampCorsVal = NaN;
            end
            
            rel = struct();
            rel.nSplits = nSplits;
            rel.n = n;
            % splitPrcRange: percentile range of the split distribution.
            % NOT a confidence interval - the splits share trials, so this
            % understates uncertainty (renamed from the misleading ci95).
            if isempty(cors)
                rel.medianCorrelation = NaN;
                rel.splitPrcRange = [NaN NaN];
            else
                rel.medianCorrelation = median(cors);
                rel.splitPrcRange = prctile(cors, [2.5 97.5]);
            end
            rel.medianAmplitudeCorrelation = ampCorsVal;
            rel.definition = 'split-half correlation of ROI-mean waveform in component window (median over random splits)';
            r = rel.medianCorrelation;
            if ~isfinite(r)
                rel.spearmanBrown = NaN;
                rel.level = 'Unknown';
            else
                rel.spearmanBrown = neuroqc.utils.spearmanBrown(r);
                if r >= 0.7
                    rel.level = 'Strong';
                elseif r >= 0.5
                    rel.level = 'Moderate';
                else
                    rel.level = 'Weak';
                end
            end
        end
        
        function boot = bootstrapMeanAmp(sub, wsel, roiIdx, nBoot, seed)
            n = size(sub, 3);
            rng(seed, 'twister');
            amps = zeros(nBoot, 1);
            % Mean over ROI and window per trial
            perTrial = squeeze(mean(mean(sub(roiIdx, wsel, :), 1), 2)); % n x 1
            perTrial = perTrial(:);
            for b = 1:nBoot
                idx = randi(n, n, 1);
                amps(b) = mean(perTrial(idx));
            end
            boot = struct();
            boot.pointEstimateUv = mean(perTrial) * 1e6;
            boot.ci95Uv = prctile(amps, [2.5 97.5]) * 1e6;
            boot.nBoot = nBoot;
            boot.n = n;
            boot.definition = 'percentile bootstrap CI of ROI-window mean amplitude across trials';
        end
        
        function topo = topoStability(sub, wsel, nSplits, seed)
            % Correlation of scalp maps (channel x 1 window mean) across splits
            n = size(sub, 3);
            nch = size(sub, 1);
            rng(seed, 'twister');
            cors = nan(nSplits, 1);
            for s = 1:nSplits
                p = randperm(n);
                half = max(2, floor(n/2));
                iA = p(1:half);
                iB = p(half+1:min(n, 2*half));
                if numel(iB) < 2, break; end
                mA = mean(mean(sub(:, wsel, iA), 2), 3);
                mB = mean(mean(sub(:, wsel, iB), 2), 3);
                if nch >= 3
                    cors(s) = corr(mA, mB); % NaN if a map is constant
                end
            end
            % Keep genuine zero spatial correlations; drop only undefined ones.
            cors = cors(isfinite(cors));
            topo = struct();
            % splitPrcRange: percentile range of the split distribution, NOT a
            % confidence interval (renamed from the misleading ci95).
            if isempty(cors)
                topo.medianSpatialCorrelation = NaN;
                topo.splitPrcRange = [NaN NaN];
            else
                topo.medianSpatialCorrelation = median(cors);
                topo.splitPrcRange = prctile(cors, [2.5 97.5]);
            end
            topo.definition = 'spatial correlation of window-mean scalp maps across split-halves';
            if ~isfinite(topo.medianSpatialCorrelation)
                topo.level = 'Unknown'; % matches reliability handling
            elseif topo.medianSpatialCorrelation >= 0.8
                topo.level = 'Strong';
            elseif topo.medianSpatialCorrelation >= 0.6
                topo.level = 'Moderate';
            else
                topo.level = 'Weak';
            end
        end
        
        function st = componentStatus(cr)
            st = 'PASS';
            score = 0;
            n = 0;
            
            if isfield(cr, 'reliability') && isfield(cr.reliability, 'medianCorrelation') && ...
                    isfinite(cr.reliability.medianCorrelation)
                n = n + 1;
                if cr.reliability.medianCorrelation >= 0.5, score = score + 1; end
                if cr.reliability.medianCorrelation < 0.3, st = 'REVIEW'; end
            end
            
            if isfield(cr, 'topoStability') && isfield(cr.topoStability, 'medianSpatialCorrelation')
                if ~isfinite(cr.topoStability.medianSpatialCorrelation)
                    % Unmeasurable topography stability must not pass silently:
                    % cannot score it, so require human review.
                    st = 'REVIEW';
                else
                    n = n + 1;
                    if cr.topoStability.medianSpatialCorrelation >= 0.6, score = score + 1; end
                    if cr.topoStability.medianSpatialCorrelation < 0.4, st = 'REVIEW'; end
                end
            end
            
            fn = fieldnames(cr.byCondition);
            for k = 1:numel(fn)
                cm = cr.byCondition.(fn{k});
                if isfield(cm, 'snrMean') && isfinite(cm.snrMean)
                    n = n + 1;
                    if cm.snrMean >= 2, score = score + 1; end
                    if cm.snrMean < 1, st = 'REVIEW'; end
                end
                if cm.nTrials < 20
                    if strcmp(st, 'PASS'), st = 'PASS_WITH_WARNING'; end
                end
            end
            
            if score == 0 && n > 0
                st = 'REVIEW';
            end
        end
        
        function printSummary(result)
            fprintf('\n=== ERP Analysis: %s ===\n', result.status);
            fn = fieldnames(result.conditions);
            for i = 1:numel(fn)
                c = result.conditions.(fn{i});
                if isfield(c, 'nTrials')
                    fprintf('Condition %s: N=%d', fn{i}, c.nTrials);
                    if isfield(c, 'baselineSdUv')
                        fprintf(', baselineSD=%.1f uV', c.baselineSdUv);
                    end
                    fprintf('\n');
                end
            end
            fn = fieldnames(result.components);
            for i = 1:numel(fn)
                cr = result.components.(fn{i});
                fprintf('Component %s: %s\n', cr.name, cr.status);
                if isfield(cr, 'byCondition')
                    cfn = fieldnames(cr.byCondition);
                    for j = 1:numel(cfn)
                        cm = cr.byCondition.(cfn{j});
                        fprintf('  %s: mean=%.1f uV, peak=%.1f uV @ %d ms, SNR=%.2f\n', ...
                            cfn{j}, cm.meanAmplitudeUv, cm.peakAmplitudeUv, ...
                            round(cm.peakLatencyMs), cm.snrMean);
                    end
                end
                if isfield(cr, 'reliability') && isfield(cr.reliability, 'medianCorrelation')
                    fprintf('  Reliability: r=%.2f (%s)\n', ...
                        cr.reliability.medianCorrelation, cr.reliability.level);
                end
                if isfield(cr, 'bootstrap')
                    fprintf('  Bootstrap CI: [%.1f, %.1f] uV\n', ...
                        cr.bootstrap.ci95Uv(1), cr.bootstrap.ci95Uv(2));
                end
            end
            for i = 1:numel(result.notes)
                fprintf('  NOTE: %s\n', result.notes{i});
            end
            fprintf('\n');
        end
    end
end