function r = baselineQC(EEG, parameters, contract) %#ok<INUSD>
%baselineQC QC for baseline correction
% Metrics: baseline mean ~ 0, baseline SD (noise proxy)

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEG)
        r.status = 'NOT_RUN';
        return;
    end
    
    if nargin < 3, contract = []; end
    if EEG.trials <= 1
        r.status = 'REVIEW';
        r.warnings{end+1} = 'Baseline QC on continuous data';
        return;
    end
    
    % Window indices
    if ~isempty(contract) && isprop(contract, 'baseline')
        t0 = contract.baseline.start;
        t1 = contract.baseline.end;
    elseif isfield(parameters, 'window')
        t0 = parameters.window(1);
        t1 = parameters.window(2);
    else
        t0 = EEG.xmin;
        t1 = min(0, EEG.xmax);
    end
    
    times = (0:EEG.pnts-1) / EEG.srate + EEG.xmin;
    sel = times >= t0 & times <= t1;
    if ~any(sel)
        r.status = 'REVIEW';
        r.warnings{end+1} = 'Baseline window empty';
        return;
    end
    
    data = double(EEG.data(:, sel, :));
    baseMean = mean(data(:));
    baseSD = std(data(:));
    
    m = struct();
    m.baselineWindow = [t0 t1];
    m.baselineMeanUv = baseMean * 1e6;
    m.baselineSdUv = baseSD * 1e6;
    m.baselineMeanAbsUv = mean(abs(mean(data, 2)), 'all') * 1e6;
    
    r.metrics = m;
    
    if abs(m.baselineMeanUv) > 5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Baseline mean = %.1f uV (should be near 0)', m.baselineMeanUv);
    elseif abs(m.baselineMeanUv) > 1
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('Baseline mean residual = %.1f uV', m.baselineMeanUv);
    end
end