classdef DataState
    %DATASTATE What has been done to the current dataset, and what it is now.
    %
    %   s = neuroqc.live.DataState.fromEEG(EEG)
    %
    %   The current state is read from the EEG structure itself (that is
    %   the ground truth: epoched or not, sampling rate, channels, ICA
    %   matrices, IC flags, reference). EEG.history supplies the ordered
    %   processing record and the parameters that were used. Where the two
    %   disagree, or where the history cannot describe the state (for
    %   example ICs removed after interactive flagging), a warning is added
    %   instead of guessing.

    methods (Static)
        function s = fromEEG(EEG)
            assert(isstruct(EEG) && isscalar(EEG) && isfield(EEG, 'data') && ~isempty(EEG.data), ...
                'NeuroQC:NoDataset', 'No EEG dataset with data is loaded in EEGLAB.');
            s = struct();
            s.setname = fieldOr(EEG, 'setname', '');
            s.filename = fullfile(fieldOr(EEG, 'filepath', ''), fieldOr(EEG, 'filename', ''));
            s.nbchan = EEG.nbchan;
            s.srate = EEG.srate;
            s.pnts = EEG.pnts;
            s.trials = EEG.trials;
            s.isEpoched = EEG.trials > 1 || (isfield(EEG, 'epoch') && ~isempty(EEG.epoch));
            s.xmin = EEG.xmin; s.xmax = EEG.xmax;
            s.labels = channelLabels(EEG);
            s.nEvents = numel(fieldOr(EEG, 'event', []));
            [s.eventTypes, s.eventCounts] = eventTypes(EEG);
            s.hasUrevent = isfield(EEG, 'urevent') && ~isempty(EEG.urevent);
            s.reference = referenceOf(EEG);
            s.removedChannels = removedChannels(EEG);
            s.ica = icaState(EEG);
            s.history = neuroqc.live.History.parse(fieldOr(EEG, 'history', ''));
            s.process = s.history(ismember({s.history.kind}, {'process'}));
            s.filters = filterSummary(s.history);
            s.warnings = {};
            s = checkConsistency(s, EEG);
        end

        function print(s)
            neuroqc.utils.log('Dataset "%s": %d channels, %g Hz, %s, %d events.', ...
                s.setname, s.nbchan, s.srate, epochText(s), s.nEvents);
            neuroqc.utils.log('Reference: %s. ICA: %s.', s.reference, s.ica.summary);
            if ~isempty(s.filters.text), neuroqc.utils.log('Filters from history: %s.', s.filters.text); end
            if ~isempty(s.removedChannels)
                neuroqc.utils.log('Removed channels (chaninfo.removedchans): %s', strjoin(s.removedChannels, ', '));
            end
            steps = {s.process.step};
            if isempty(steps)
                neuroqc.utils.log('Processing steps in history: none.');
            else
                neuroqc.utils.log('Processing steps in history (in order): %s', strjoin(steps, ' > '));
            end
            for k = 1:numel(s.warnings), neuroqc.utils.log('WARNING: %s', s.warnings{k}); end
        end
    end
end

function v = fieldOr(s, f, d)
if isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function t = epochText(s)
if s.isEpoched
    t = sprintf('%d epochs [%g %g] s', s.trials, s.xmin, s.xmax);
else
    t = sprintf('continuous %.1f s', s.pnts / s.srate);
end
end

function labels = channelLabels(EEG)
if isfield(EEG, 'chanlocs') && numel(EEG.chanlocs) == EEG.nbchan && isfield(EEG.chanlocs, 'labels')
    labels = arrayfun(@(c) char(string(c.labels)), EEG.chanlocs, 'UniformOutput', false);
else
    labels = arrayfun(@(k) sprintf('%d', k), 1:EEG.nbchan, 'UniformOutput', false);
end
labels = labels(:)';
end

function [types, counts] = eventTypes(EEG)
types = {}; counts = [];
if ~isfield(EEG, 'event') || isempty(EEG.event) || ~isfield(EEG.event, 'type'), return; end
codes = arrayfun(@(e) strtrim(char(string(e.type))), EEG.event, 'UniformOutput', false);
[types, ~, ic] = unique(codes);
counts = accumarray(ic(:), 1)';
types = types(:)';
end

function r = referenceOf(EEG)
r = 'unknown';
if isfield(EEG, 'ref') && ~isempty(EEG.ref)
    if ischar(EEG.ref) || isstring(EEG.ref), r = char(EEG.ref);
    elseif isnumeric(EEG.ref), r = sprintf('channel(s) %s', mat2str(EEG.ref)); end
end
if strcmp(r, 'unknown') && isfield(EEG, 'chanlocs') && isfield(EEG.chanlocs, 'ref') && ~isempty(EEG.chanlocs)
    refs = unique(arrayfun(@(c) char(string(c.ref)), EEG.chanlocs, 'UniformOutput', false));
    refs = refs(~cellfun(@isempty, refs));
    if numel(refs) == 1, r = refs{1}; end
end
end

function names = removedChannels(EEG)
names = {};
if isfield(EEG, 'chaninfo') && isfield(EEG.chaninfo, 'removedchans') && ~isempty(EEG.chaninfo.removedchans)
    rc = EEG.chaninfo.removedchans;
    if isfield(rc, 'labels'), names = arrayfun(@(c) char(string(c.labels)), rc, 'UniformOutput', false); end
end
names = names(:)';
end

function ica = icaState(EEG)
ica = struct('present', false, 'nComponents', 0, 'nChannels', 0, 'flagged', [], ...
    'hasICLabel', false, 'summary', 'none');
if ~isfield(EEG, 'icaweights') || isempty(EEG.icaweights), return; end
ica.present = true;
ica.nComponents = size(EEG.icaweights, 1);
ica.nChannels = numel(fieldOr(EEG, 'icachansind', 1:EEG.nbchan));
if isfield(EEG, 'reject') && isfield(EEG.reject, 'gcompreject') && ~isempty(EEG.reject.gcompreject)
    ica.flagged = find(EEG.reject.gcompreject);
end
ica.hasICLabel = isfield(EEG, 'etc') && isfield(EEG.etc, 'ic_classification') && ...
    isfield(EEG.etc.ic_classification, 'ICLabel');
ica.summary = sprintf('%d components on %d channels', ica.nComponents, ica.nChannels);
if ~isempty(ica.flagged)
    ica.summary = sprintf('%s; %d flagged for removal (%s)', ica.summary, numel(ica.flagged), mat2str(ica.flagged));
end
if ica.hasICLabel, ica.summary = [ica.summary '; ICLabel present']; end
end

function f = filterSummary(h)
% Effective pass band implied by pop_eegfiltnew entries, in order.
f = struct('highpass', [], 'lowpass', [], 'notch', [], 'other', 0, 'text', '');
parts = {};
for k = 1:numel(h)
    e = h(k);
    if ~strcmp(e.kind, 'process'), continue; end
    switch e.step
        case 'highpass', f.highpass(end+1) = e.params.locutoff; parts{end+1} = sprintf('HP %g Hz', e.params.locutoff); %#ok<AGROW>
        case 'lowpass', f.lowpass(end+1) = e.params.hicutoff; parts{end+1} = sprintf('LP %g Hz', e.params.hicutoff); %#ok<AGROW>
        case 'bandpass'
            f.highpass(end+1) = e.params.locutoff; f.lowpass(end+1) = e.params.hicutoff;
            parts{end+1} = sprintf('BP %g-%g Hz', e.params.locutoff, e.params.hicutoff); %#ok<AGROW>
        case 'linenoise'
            if isfield(e.params, 'locutoff')
                f.notch(end+1) = mean([e.params.locutoff e.params.hicutoff]);
                parts{end+1} = sprintf('notch %g-%g Hz', e.params.locutoff, e.params.hicutoff); %#ok<AGROW>
            else
                parts{end+1} = sprintf('line-noise removal (%s)', e.fn); %#ok<AGROW>
            end
        case {'filter_other','clean_rawdata'}
            f.other = f.other + 1; parts{end+1} = sprintf('%s (not parsed)', e.fn); %#ok<AGROW>
    end
end
f.text = strjoin(parts, ' > ');
end

function s = checkConsistency(s, EEG)
h = s.history;
w = {};
if isempty(h)
    w{end+1} = 'EEG.history is empty: the processing record is unknown; the state shown is read from the data only.';
end
steps = {s.process.step};
% Epoch state: data vs history
if s.isEpoched && ~any(strcmp(steps, 'epoch'))
    w{end+1} = 'Data are epoched but the history contains no pop_epoch entry (epoched on import or history incomplete).';
elseif ~s.isEpoched && any(strcmp(steps, 'epoch'))
    w{end+1} = 'History contains pop_epoch but the data are continuous (history may belong to another dataset).';
end
% ICA: present vs history; IC removals whose indices are not recorded
icaIdx = find(strcmp(steps, 'ica'));
if s.ica.present && isempty(icaIdx)
    w{end+1} = 'ICA weights are present but no ICA call is in the history (weights imported or transferred).';
end
if numel(icaIdx) > 1
    w{end+1} = sprintf('ICA was run %d times; only the last decomposition is in the data.', numel(icaIdx));
end
for k = find(strcmp(steps, 'icremove'))
    if ~isempty(s.process(k).note)
        w{end+1} = sprintf('History line %d: %s', s.process(k).line, s.process(k).note); %#ok<AGROW>
    end
end
if ~isempty(icaIdx)
    lastIca = icaIdx(end);
    after = steps(lastIca+1:end);
    if s.ica.present && any(ismember(after, {'channels','badchannels','clean_rawdata'}))
        w{end+1} = 'Channels were removed after the last ICA: the decomposition no longer matches the channel set.';
    end
    if s.ica.present && ~any(strcmp(after, 'icremove'))
        w{end+1} = 'The latest ICA decomposition has not been followed by component removal (pop_subcomp).';
    end
end
% Notes the parser attached (ALLEEG references etc.)
for k = 1:numel(h)
    if contains(h(k).note, 'not reproducible')
        w{end+1} = sprintf('History line %d refers to ALLEEG/CURRENTSET: %s', h(k).line, strtrim(h(k).statement)); %#ok<AGROW>
    end
end
% Data scale: EEGLAB convention is microvolts
x = EEG.data(:, 1:min(EEG.pnts, round(10*EEG.srate)), 1);
med = median(abs(double(x(:))));
if med > 0 && med < 1e-3
    w{end+1} = sprintf('Median |amplitude| is %.2g: data look like volts, not microvolts. Amplitude thresholds (e.g. 100 uV) would be meaningless.', med);
end
if EEG.srate ~= round(EEG.srate) && abs(EEG.srate - round(EEG.srate)) < 1e-6
    w{end+1} = sprintf('EEG.srate is %.17g, not an exact integer (common after EDF import); ICLabel fails on such data. NeuroQC rounds it on its own copy.', EEG.srate);
end
if ~s.hasUrevent
    w{end+1} = 'EEG.urevent is empty; NeuroQC will rebuild it (eeg_checkset makeur) on its own copy to track trials.';
end
s.warnings = w;
end
