function r = epochQC(EEG, parameters, contract)
%epochQC QC for epoching — retention balance is critical

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEG)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    
    if EEG.trials <= 1
        r.status = 'REVIEW';
        r.warnings{end+1} = 'Epoch QC called on non-epoched data';
        r.metrics = m;
        return;
    end
    
    m.nTrials = EEG.trials;
    
    % Per-condition trial counts from epoch event info
    counts = struct();
    if isfield(EEG, 'epoch') && ~isempty(EEG.epoch) && ~isempty(EEG.event)
        % Build event type per trial
        if isfield(EEG.epoch, 'eventtype')
            types = neuroqc.erpERPAnalyzer_types(EEG);
            
            if ~isempty(contract) && isprop(contract, 'conditions')
                for ci = 1:numel(contract.conditions)
                    cond = contract.conditions(ci);
                    sel = false(1, EEG.trials);
                    for ei = 1:numel(cond.events)
                        sel = sel | strcmp(types, cond.events{ei});
                    end
                    counts.(cond.name) = sum(sel);
                end
            else
                ut = unique(types);
                for i = 1:numel(ut)
                    counts.(matlab.lang.makeValidName(ut{i})) = sum(strcmp(types, ut{i}));
                end
            end
        end
    end
    m.conditionCounts = counts;
    
    cn = fieldnames(counts);
    if numel(cn) >= 2
        vals = cellfun(@(f) counts.(f), cn);
        m.conditionCounts = counts;
        m.nMin = min(vals);
        m.nMax = max(vals);
        % Absolute count ratio is design-dependent (oddball targets are fewer
        % BY DESIGN). Only flag extreme dropouts; retention imbalance is
        % evaluated in artifactQC against pre-rejection counts.
        m.conditionImbalanceRatio = min(vals) / max(max(vals), 1);
        m.countsByDesign = true;
    else
        m.conditionImbalanceRatio = 1;
    end
    
    r.metrics = m;
    
    if isfield(m, 'nMin') && m.nMin < 5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Condition with very few trials after epoching (min N=%d)', m.nMin);
        r.recommendations{end+1} = 'Check event codes / epoch window / boundary removal';
    elseif isfield(m, 'nMin') && m.nMin < 15
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('Low trial count in one condition (N=%d)', m.nMin);
    end
    
    if EEG.trials < 20
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('Low total trial count: %d', EEG.trials);
    end
end