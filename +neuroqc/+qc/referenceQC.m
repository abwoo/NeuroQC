function r = referenceQC(EEGbefore, EEGafter, parameters) %#ok<INUSD>
%referenceQC QC for re-referencing

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    if isfield(parameters, 'mode'), m.mode = parameters.mode; else, m.mode = 'unknown'; end
    
    data = double(EEGafter.data);
    if ndims(data) == 3, data = reshape(data, size(data,1), []); end
    
    % Average reference check: channel mean across channels ~ 0
    meanAcross = mean(data, 1);
    m.globalMeanUv = mean(meanAcross) * 1e6;
    m.globalMeanAbsUv = mean(abs(meanAcross)) * 1e6;
    
    if strcmpi(m.mode, 'average')
        m.avgRefResidual = std(meanAcross);
        if m.avgRefResidual > 1e-6 * max(std(data(:)), 1)
            % should be ~0 numerically
            if m.avgRefResidual > 1e-3
                r.status = 'REVIEW';
                r.warnings{end+1} = 'Average reference residual not near zero';
            end
        end
    end
    
    % EOG channels should not enter average reference if excluded specified
    if isfield(parameters, 'keepCollapsedBaseline') % placeholder no-op
    end
    if isfield(parameters, 'exclude')
        labels = {EEGafter.chanlocs.labels};
        for i = 1:numel(parameters.exclude)
            if ~ismember(parameters.exclude{i}, labels)
                r.warnings{end+1} = sprintf('Reference exclude channel missing: %s', parameters.exclude{i});
                if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
            end
        end
    end
    
    % Variance change summary
    vb = var(double(EEGbefore.data), 0, 2);
    va = var(double(EEGafter.data), 0, 2);
    m.medianVarRatio = median(va) / max(median(vb), eps);
    
    r.metrics = m;
end