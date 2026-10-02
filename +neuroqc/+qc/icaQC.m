function r = icaQC(EEGbefore, EEGafter, parameters) %#ok<INUSD>
%icaQC QC for ICA decomposition

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    
    if isfield(EEGafter, 'icaact') && ~isempty(EEGafter.icaact)
        nIC = size(EEGafter.icaact, 1);
    elseif isfield(EEGafter, 'icaweights') && ~isempty(EEGafter.icaweights)
        nIC = size(EEGafter.icaweights, 1);
    else
        nIC = 0;
    end
    m.nIC = nIC;
    m.nChannels = EEGafter.nbchan;
    
    rankBefore = neuroqc.utils.estimateRank(EEGbefore.data);
    rankAfter = neuroqc.utils.estimateRank(EEGafter.data);
    m.dataRankBefore = rankBefore;
    m.dataRankAfter = rankAfter;
    
    if isfield(parameters, 'targetRank')
        m.targetRank = parameters.targetRank;
    else
        m.targetRank = min(rankAfter, EEGafter.nbchan);
    end
    
    if isfield(parameters, 'method'), m.method = parameters.method; else, m.method = 'runica'; end
    
    % Readiness: rank vs channels
    m.rankChannelGap = EEGafter.nbchan - rankAfter;
    
    r.metrics = m;
    
    if nIC == 0
        r.status = 'FAIL';
        r.warnings{end+1} = 'ICA produced no components';
        return;
    end
    
    if nIC > rankAfter + 1
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('More ICs (%d) than numerical rank (%d)', nIC, rankAfter);
    end
    
    if m.rankChannelGap >= 2
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.recommendations{end+1} = sprintf('Use ICA dim = %d (rank), not %d (channels)', rankAfter, EEGafter.nbchan);
    end
end