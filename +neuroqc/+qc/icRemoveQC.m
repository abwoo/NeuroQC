function r = icRemoveQC(EEGbefore, EEGafter, parameters)
%icRemoveQC QC for IC removal — guards against over-cleaning

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    
    if isfield(parameters, 'removedICs')
        removed = parameters.removedICs(:)';
    elseif isfield(EEGafter, 'etc') && isfield(EEGafter.etc, 'neuroqc_removedICs')
        removed = EEGafter.etc.neuroqc_removedICs(:)';
    else
        removed = [];
    end
    
    nIC = 0;
    if isfield(EEGbefore, 'icaweights') && ~isempty(EEGbefore.icaweights)
        nIC = size(EEGbefore.icaweights, 1);
    elseif isfield(EEGafter, 'icaweights') && ~isempty(EEGafter.icaweights)
        nIC = size(EEGafter.icaweights, 1);
    end
    
    m.nIC = nIC;
    m.removedCount = numel(removed);
    m.removedICs = removed;
    if nIC > 0
        m.removedFraction = numel(removed) / nIC;
    else
        m.removedFraction = NaN;
    end
    
    % Signal change fraction
    if ~isempty(EEGbefore) && ~isempty(EEGafter)
        Xb = double(EEGbefore.data);
        Xa = double(EEGafter.data);
        n = min(size(Xb,2), size(Xa,2));
        m.signalChangeFraction = norm(Xa(:,1:n) - Xb(:,1:n), 'fro') / max(norm(Xb(:,1:n), 'fro'), eps);
    else
        m.signalChangeFraction = NaN;
    end
    
    if isfield(parameters, 'eogCorr'), m.eogCorr = parameters.eogCorr; end
    if isfield(parameters, 'iclabelProb'), m.iclabelProb = parameters.iclabelProb; end
    
    r.metrics = m;
    
    if isfinite(m.removedFraction) && m.removedFraction > 0.5
        r.status = 'FAIL';
        r.warnings{end+1} = sprintf('Removed %d/%d ICs (%.0f%%) — likely over-cleaning', ...
            m.removedCount, nIC, 100*m.removedFraction);
    elseif isfinite(m.removedFraction) && m.removedFraction > 0.3
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Removed %d/%d ICs (%.0f%%)', m.removedCount, nIC, 100*m.removedFraction);
    elseif m.removedCount > 0
        r.status = 'PASS_WITH_WARNING';
    end
    
    if isfinite(m.signalChangeFraction) && m.signalChangeFraction > 0.5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('IC removal changed signal by %.0f%%', 100*m.signalChangeFraction);
    end
end