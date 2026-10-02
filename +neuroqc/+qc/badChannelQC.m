function r = badChannelQC(EEG, parameters)
%badChannelQC QC for bad-channel detection step
% Requires parameters.candidateBadChannels (indices) and optional .reasons

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    
    if isempty(EEG)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    labels = {};
    if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs)
        labels = {EEG.chanlocs.labels};
    end
    nch = EEG.nbchan;
    m.channelCount = nch;
    
    if isfield(parameters, 'candidateBadChannels')
        bad = parameters.candidateBadChannels(:)';
    else
        bad = [];
    end
    m.badCount = numel(bad);
    m.badRatio = numel(bad) / max(nch, 1);
    m.badIndices = bad;
    if ~isempty(labels) && ~isempty(bad)
        m.badLabels = labels(bad);
    else
        m.badLabels = {};
    end
    
    if isfield(parameters, 'reasons')
        m.reasons = parameters.reasons;
    end
    
    r.metrics = m;
    
    % Detection step: never FAIL — only flag for human review / later interpolate QC
    if m.badRatio > 0.4
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('%d/%d (%.0f%%) channels flagged — do not blindly interpolate', ...
            m.badCount, nch, 100*m.badRatio);
        r.recommendations{end+1} = 'Inspect montage / recording quality before interpolate step';
    elseif m.badRatio > 0.15
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Bad channel ratio %.0f%% needs review', 100*m.badRatio);
    elseif m.badCount > 0
        r.status = 'PASS_WITH_WARNING';
    end
    
    if isfield(parameters, 'reasons') && isempty(parameters.reasons) && m.badCount > 0
        r.status = 'REVIEW';
        r.warnings{end+1} = 'Bad channels listed without provenance reasons';
    end
end