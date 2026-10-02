function r = artifactQC(EEG, parameters, contract) %#ok<INUSD>
%artifactQC QC for trial artifact rejection
% Focus: retention rate, residual noise, condition imbalance — NOT ERP size

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEG)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    
    if isfield(parameters, 'retainedIndices')
        retained = parameters.retainedIndices;
        m.nRetained = numel(retained);
    else
        m.nRetained = EEG.trials;
        retained = 1:EEG.trials;
    end
    
    if isfield(parameters, 'nInitial')
        m.nInitial = parameters.nInitial;
        m.retentionRate = m.nRetained / max(parameters.nInitial, 1);
    else
        m.nInitial = m.nRetained;
        m.retentionRate = 1;
    end
    
    if isfield(parameters, 'thresholdUv'), m.thresholdUv = parameters.thresholdUv; end
    if isfield(parameters, 'method'), m.method = parameters.method; end
    
    % Residual peak-to-peak noise on retained data
    data = double(EEG.data);
    if ndims(data) == 3
        % trials x ch: p2p per channel x trial
        pt = squeeze(max(data, [], 2) - min(data, [], 2)); % ch x trials
        m.medianPeakToPeakUv = median(pt(:)) * 1e6;
    else
        m.medianPeakToPeakUv = median(max(data,[],2) - min(data,[],2)) * 1e6;
    end
    
    % Condition-specific retention if contract provided
    if ~isempty(contract) && isprop(contract, 'conditions') && ~isempty(contract.conditions)
        if isfield(EEG, 'epoch') && ~isempty(EEG.epoch) && isfield(EEG.epoch, 'eventtype')
            types = neuroqc.erpERPAnalyzer_types(EEG);
            % Note: retained already applied if EEG only has retained trials.
            % For balance we need initial vs retained — parameters.preRejectTypes
            if isfield(parameters, 'preRejectTypes')
                preTypes = parameters.preRejectTypes;
                postTypes = types;
                bal = struct();
                for ci = 1:numel(contract.conditions)
                    cond = contract.conditions(ci);
                    selPre = false(size(preTypes));
                    selPost = false(size(postTypes));
                    for ei = 1:numel(cond.events)
                        selPre = selPre | strcmp(preTypes, cond.events{ei});
                        selPost = selPost | strcmp(postTypes, cond.events{ei});
                    end
                    nPre = sum(selPre);
                    nPost = sum(selPost);
                    bal.(cond.name) = struct('initial', nPre, 'retained', nPost, ...
                        'retention', nPost / max(nPre, 1));
                end
                m.conditionRetention = bal;
                fn = fieldnames(bal);
                if numel(fn) >= 2
                    rates = zeros(numel(fn), 1);
                    for ri = 1:numel(fn)
                        rates(ri) = bal.(fn{ri}).retention;
                    end
                    m.conditionRetentionSpread = max(rates) - min(rates);
                end
            end
        end
    end
    
    r.metrics = m;
    
    if m.retentionRate < 0.3
        r.status = 'FAIL';
        r.warnings{end+1} = sprintf('Trial retention %.0f%% (<30%%)', 100*m.retentionRate);
    elseif m.retentionRate < 0.5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Low trial retention %.0f%%', 100*m.retentionRate);
    elseif m.retentionRate < 0.7
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('Moderate trial retention %.0f%%', 100*m.retentionRate);
    end
    
    if isfield(m, 'conditionRetentionSpread') && m.conditionRetentionSpread > 0.25
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Condition retention spread = %.2f (e.g. Target 42%% vs Standard 91%%)', ...
            m.conditionRetentionSpread);
    end
end