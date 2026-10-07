function EEG = selectPoints(EEG, opt, val)
%SELECTPOINTS pop_select(EEG, opt, val) on continuous data, for opt 'time'
%   (keep [start end] in s) or 'nopoint' (remove rows of [first last]
%   samples), without its Command Window output. EEGLAB 2024.0 and older
%   stop there on recent MATLAB releases ("Colon operands must be real
%   scalars" in eegrej, fixed in EEGLAB 2024.1); the same cut is then made
%   here: the samples, and the events in the samples kept.
try
    [~, EEG] = evalc('pop_select(EEG, opt, val)');
catch ME
    if ~strcmp(ME.identifier, 'MATLAB:colon:operandsNotRealScalar'), rethrow(ME); end
    t = EEG.xmin + (0:EEG.pnts - 1) / EEG.srate;
    if strcmp(opt, 'time')
        keep = t >= val(1) & t <= val(2);
    else
        keep = true(1, EEG.pnts);
        for k = 1:size(val, 1), keep(max(1, val(k, 1)):min(EEG.pnts, val(k, 2))) = false; end
    end
    newIdx = cumsum(keep);
    if ~isempty(EEG.event)
        lat = [EEG.event.latency];
        s = min(max(round(lat), 1), EEG.pnts);
        in = keep(s);
        newLat = newIdx(s(in)) + (lat(in) - s(in));
        EEG.event = EEG.event(in);
        for k = 1:numel(EEG.event), EEG.event(k).latency = newLat(k); end
    end
    EEG.data = EEG.data(:, keep);
    if ~isempty(EEG.icaact), EEG.icaact = EEG.icaact(:, keep); end
    EEG.pnts = nnz(keep);
    EEG.xmin = 0;
    EEG.xmax = EEG.xmin + (EEG.pnts - 1) / EEG.srate;
    EEG.times = [];
    [~, EEG] = evalc('eeg_checkset(EEG)');
end
end
