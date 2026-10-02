function h = hashEEG(EEG)
%hashEEG Stable content hash of core EEG fields for provenance
%   Hashes: data size, srate, nbchan, trial count, event latencies/types.
%   Includes complete numeric data in bounded chunks and channel/event metadata.

    parts = {};
    parts{end+1} = sprintf('%dx%dx%d', size(EEG.data,1), size(EEG.data,2), size(EEG.data,3));
    parts{end+1} = sprintf('%.10g', EEG.srate);
    parts{end+1} = sprintf('%d', EEG.nbchan);
    parts{end+1} = sprintf('%d', EEG.trials);
    
    if isfield(EEG, 'event') && ~isempty(EEG.event)
        for i = 1:numel(EEG.event)
            t = EEG.event(i).type;
            if isnumeric(t), ts = num2str(t); else, ts = char(string(t)); end
            lat = 0;
            if isfield(EEG.event, 'latency'), lat = EEG.event(i).latency; end
            parts{end+1} = sprintf('%s@%.6f', ts, lat); %#ok<AGROW>
        end
    end
    
    joined = strjoin(parts, '|');
    md = java.security.MessageDigest.getInstance('SHA-256');
    % UTF-8 bytes: uint8(char) truncates non-ASCII code points and would
    % collide distinct event types (Chinese set names, accented labels).
    md.update(unicode2native(joined, 'UTF-8'));
    md.update(uint8(class(EEG.data)));
    if isfield(EEG,'chanlocs'), md.update(unicode2native(jsonencode(EEG.chanlocs),'UTF-8')); end
    if isfield(EEG,'event'), md.update(unicode2native(jsonencode(EEG.event),'UTF-8')); end
    for field={'icaweights','icasphere','icawinv','icachansind','xmin','ref','epoch','etc'}
        if isfield(EEG,field{1})
            md.update(unicode2native(jsonencode(EEG.(field{1})),'UTF-8'));
        end
    end
    for first=1:1000000:numel(EEG.data)
        last=min(first+999999,numel(EEG.data));
        md.update(typecast(EEG.data(first:last),'uint8'));
    end
    b = typecast(md.digest, 'uint8');
    h = lower(reshape(dec2hex(b)', 1, []));
end