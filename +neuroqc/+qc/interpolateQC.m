function r = interpolateQC(EEGbefore, EEGafter, parameters) %#ok<INUSD>
%interpolateQC QC for spherical interpolation

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    nch = EEGafter.nbchan;
    m.channelCount = nch;
    
    if isfield(parameters, 'interpolatedChannels')
        interp = parameters.interpolatedChannels(:)';
    else
        interp = [];
    end
    m.interpolatedCount = numel(interp);
    m.interpolatedRatio = numel(interp) / max(nch, 1);
    m.interpolatedIndices = interp;
    
    if isfield(parameters, 'method')
        m.method = parameters.method;
    else
        m.method = 'spherical';
    end
    
    % Data rank should not collapse further due to interpolation of many chans
    m.dataRank = neuroqc.utils.estimateRank(EEGafter.data);
    
    r.metrics = m;
    
    if m.interpolatedRatio > 0.3
        r.status = 'FAIL';
        r.warnings{end+1} = sprintf('Interpolated %.0f%% of channels (>30%% hard limit)', 100*m.interpolatedRatio);
    elseif m.interpolatedRatio > 0.15
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Interpolated %.0f%% of channels', 100*m.interpolatedRatio);
    elseif m.interpolatedCount > 0
        r.status = 'PASS_WITH_WARNING';
    end
    
    if m.dataRank < max(1, 0.5 * nch)
        if ~strcmp(r.status, 'FAIL')
            r.status = 'REVIEW';
        end
        r.warnings{end+1} = sprintf('Data rank low after interpolation (%d / %d)', m.dataRank, nch);
    end
end