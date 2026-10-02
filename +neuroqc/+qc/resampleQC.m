function r = resampleQC(EEGbefore, EEGafter, parameters) %#ok<INUSD>
%resampleQC QC for resampling step
% Checks: duration preserved, event count preserved, latency shift, fs change

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    m.fsBefore = EEGbefore.srate;
    m.fsAfter = EEGafter.srate;
    
    durBefore = neuroqc.qc.helpers.durationSec(EEGbefore);
    durAfter = neuroqc.qc.helpers.durationSec(EEGafter);
    m.durationBefore = durBefore;
    m.durationAfter = durAfter;
    m.durationRelError = abs(durAfter - durBefore) / max(durBefore, eps);
    
    nEvBefore = 0;
    if isfield(EEGbefore, 'event'), nEvBefore = numel(EEGbefore.event); end
    nEvAfter = 0;
    if isfield(EEGafter, 'event'), nEvAfter = numel(EEGafter.event); end
    m.eventCountBefore = nEvBefore;
    m.eventCountAfter = nEvAfter;
    m.eventCountPreserved = (nEvBefore == nEvAfter);
    
    % Latency scale shift (samples scale by fs ratio)
    if nEvBefore > 0 && nEvAfter > 0 && nEvBefore == nEvAfter && ...
            isfield(EEGbefore.event, 'latency') && isfield(EEGafter.event, 'latency')
        latB = [EEGbefore.event.latency];
        latA = [EEGafter.event.latency];
        expected = (latB - 1) * (EEGafter.srate / EEGbefore.srate) + 1;
        m.latencyShiftSamples = median(abs(latA - expected));
        m.latencyShiftMs = m.latencyShiftSamples / EEGafter.srate * 1000;
    else
        m.latencyShiftMs = NaN;
    end
    
    % Amplitude scale check (resampling should not change scale much)
    ab = neuroqc.qc.helpers.robustAmp(EEGbefore.data);
    aa = neuroqc.qc.helpers.robustAmp(EEGafter.data);
    m.ampRatio = aa / max(ab, eps);
    
    r.metrics = m;
    
    if m.durationRelError > 0.01
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Duration changed by %.2f%%', 100*m.durationRelError);
    end
    if ~m.eventCountPreserved
        r.status = 'FAIL';
        r.warnings{end+1} = 'Event count changed during resample';
    end
    if isfinite(m.latencyShiftMs) && m.latencyShiftMs > 2
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Median latency shift %.2f ms', m.latencyShiftMs);
    end
    if m.ampRatio < 0.9 || m.ampRatio > 1.1
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('Amplitude ratio after resample = %.3f', m.ampRatio);
    end
end