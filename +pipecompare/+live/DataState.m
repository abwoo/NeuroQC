classdef DataState
    %DATASTATE What has been done to the current dataset, and what it is now.
    %
    %   s = pipecompare.live.DataState.fromEEG(EEG)
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
                'PipeCompare:NoDataset', 'No EEG dataset with data is loaded in EEGLAB.');
            s = struct();
            s.setname = pipecompare.utils.fieldOr(EEG, 'setname', '');
            s.filename = fullfile(pipecompare.utils.fieldOr(EEG, 'filepath', ''), pipecompare.utils.fieldOr(EEG, 'filename', ''));
            s.nbchan = EEG.nbchan;
            s.srate = EEG.srate;
            s.pnts = EEG.pnts;
            s.trials = EEG.trials;
            s.isEpoched = EEG.trials > 1 || (isfield(EEG, 'epoch') && ~isempty(EEG.epoch));
            s.xmin = EEG.xmin; s.xmax = EEG.xmax;
            s.labels = channelLabels(EEG);
            s.nEvents = numel(pipecompare.utils.fieldOr(EEG, 'event', []));
            [s.eventTypes, s.eventCounts] = eventTypes(EEG);
            s.hasUrevent = isfield(EEG, 'urevent') && ~isempty(EEG.urevent);
            s.reference = referenceOf(EEG);
            s.removedChannels = removedChannels(EEG);
            s.restorableChannels = restorableIdx(EEG);   % indices into chaninfo.removedchans
            s.ica = icaState(EEG);
            s.lineFreq = lineFrequency(EEG);   % 50 or 60 Hz mains, from the data ([] if not clear)
            loc = located(EEG);
            s.nLocated = sum(loc);             % channels with finite X, Y, Z
            s.hasLocations = ~isempty(loc) && all(loc);
            s.unlocated = {};
            if s.nLocated > 0 && ~s.hasLocations, s.unlocated = {EEG.chanlocs(~loc).labels}; end
            [s.lockingTypes, s.lockingCounts] = lockingEvents(EEG);   % event types at time 0 of the epochs
            s.baselineMs = [];                 % window of the last pop_rmbase in the history, if any
            x = EEG.data(:, 1:min(EEG.pnts, round(10 * EEG.srate)), 1);
            s.unitGuess = 'uV';                % EEGLAB convention; 'V' when amplitudes are ~1e-6 smaller
            m = median(abs(double(x(:)))); if m > 0 && m < 1e-3, s.unitGuess = 'V'; end
            s.history = pipecompare.live.History.parse(pipecompare.utils.fieldOr(EEG, 'history', ''));
            s.process = s.history(ismember({s.history.kind}, {'process'}));
            s.filters = filterSummary(s.history);
            for q = numel(s.process):-1:1
                if strcmp(s.process(q).step, 'epoch'), break; end
                if strcmp(s.process(q).step, 'baseline') && isfield(s.process(q).params, 'windowMs') && ...
                        numel(s.process(q).params.windowMs) == 2
                    s.baselineMs = s.process(q).params.windowMs; break;
                end
            end
            s.warnings = {};
            s = checkConsistency(s, EEG);
            s.provenance = provenance(s, EEG);
        end

        function print(s)
            pipecompare.utils.log('Dataset "%s": %d channels, %g Hz, %s, %d events.', ...
                s.setname, s.nbchan, s.srate, epochText(s), s.nEvents);
            pipecompare.utils.log('Reference: %s. ICA: %s.', s.reference, s.ica.summary);
            if ~isempty(s.filters.text), pipecompare.utils.log('Filters from history: %s.', s.filters.text); end
            if ~isempty(s.removedChannels)
                pipecompare.utils.log('Removed channels (chaninfo.removedchans): %s', strjoin(s.removedChannels, ', '));
            end
            steps = {s.process.step};
            if isempty(steps)
                pipecompare.utils.log('Processing steps in history: none.');
            else
                pipecompare.utils.log('Processing steps in history (in order): %s', strjoin(steps, ' > '));
            end
            for k = 1:numel(s.warnings), pipecompare.utils.log('WARNING: %s', s.warnings{k}); end
            P = s.provenance;
            cats = unique({P.category}, 'stable');
            for c = 1:numel(cats)
                n = sum(strcmp({P.category}, cats{c}));
                pipecompare.utils.log('Provenance - %s: %d item(s)', cats{c}, n);
            end
        end
    end
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

function idx = restorableIdx(EEG)
% Removed EEG channels with a location: they can be restored by spherical
% interpolation (fiducials, unlocated channels and non-EEG channels such
% as EOG or ECG, which the scalp cannot predict, cannot).
idx = [];
if ~isfield(EEG, 'chaninfo') || ~isfield(EEG.chaninfo, 'removedchans') || isempty(EEG.chaninfo.removedchans), return; end
rc = EEG.chaninfo.removedchans;
if ~isfield(rc, 'X') || ~isfield(rc, 'labels'), return; end
nonEeg = pipecompare.simple.Presets.isNonEeg(rc);
for k = 1:numel(rc)
    ty = ''; if isfield(rc, 'type') && ~isempty(rc(k).type), ty = char(string(rc(k).type)); end
    if ~isempty(rc(k).X) && ~strcmpi(ty, 'FID') && ~nonEeg(k), idx(end+1) = k; end %#ok<AGROW>
end
end

function [types, counts] = lockingEvents(EEG)
% The event type at latency 0 of each epoch: the events the data were
% epoched on (empty for continuous data).
types = {}; counts = [];
if EEG.trials <= 1 || ~isfield(EEG, 'epoch') || isempty(EEG.epoch), return; end
lock = cell(1, numel(EEG.epoch));
for k = 1:numel(EEG.epoch)
    ep = EEG.epoch(k);
    lat = ep.eventlatency; ty = ep.eventtype;
    if ~iscell(lat), lat = num2cell(lat); end
    if ischar(ty) || isstring(ty), ty = {char(ty)}; elseif ~iscell(ty), ty = num2cell(ty); end
    z = find(cellfun(@(x) abs(double(x)) < 1000 / EEG.srate / 2 + 1e-6, lat), 1);
    if ~isempty(z), lock{k} = strtrim(char(string(ty{z}))); end
end
lock = lock(~cellfun(@isempty, lock));
[types, ~, ic] = unique(lock, 'stable');
counts = accumarray(ic(:), 1)';
end

function f0 = lineFrequency(EEG)
% Mains frequency of this recording (50 or 60 Hz) from its spectrum: the
% candidate whose power stands out from the neighbouring bins by >= 5x.
% [] when neither does (filtered, or not resolvable at this rate).
f0 = [];
fs = EEG.srate;
if fs < 130, return; end
n = min(EEG.pnts * EEG.trials, round(60 * fs));
X = double(EEG.data(:, 1:n));                   % the first 60 s only (no copy of the whole recording)
X = X - mean(X, 2);
P = mean(abs(fft(X, [], 2)) .^ 2, 1);
f = (0:n-1) * fs / n;
ratio = [0 0];
cand = [50 60];
for k = 1:2
    pk = abs(f - cand(k)) <= 0.5;
    nb = abs(f - cand(k)) > 2 & abs(f - cand(k)) <= 6;
    if any(pk) && any(nb), ratio(k) = max(P(pk)) / median(P(nb)); end
end
[r, k] = max(ratio);
if r >= 5, f0 = cand(k); end
end

function ica = icaState(EEG)
ica = struct('present', false, 'nComponents', 0, 'nChannels', 0, 'flagged', [], ...
    'hasICLabel', false, 'summary', 'none');
if ~isfield(EEG, 'icaweights') || isempty(EEG.icaweights), return; end
ica.present = true;
ica.nComponents = size(EEG.icaweights, 1);
ica.nChannels = numel(pipecompare.utils.fieldOr(EEG, 'icachansind', 1:EEG.nbchan));
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
        case 'filter_other'
            % edges read from the call (as cutoffs, which these functions take)
            lo = e.params.locutoff; hi = e.params.hicutoff;
            if e.params.revfilt && isfinite(lo) && isfinite(hi)
                f.notch(end+1) = mean([lo hi]); parts{end+1} = sprintf('notch %g-%g Hz (%s)', lo, hi, e.fn); %#ok<AGROW>
            elseif isfinite(lo) || isfinite(hi)
                if isfinite(lo), f.highpass(end+1) = lo; parts{end+1} = sprintf('HP %g Hz (%s)', lo, e.fn); end %#ok<AGROW>
                if isfinite(hi), f.lowpass(end+1) = hi; parts{end+1} = sprintf('LP %g Hz (%s)', hi, e.fn); end %#ok<AGROW>
            else
                f.other = f.other + 1; parts{end+1} = sprintf('%s (not parsed)', e.fn); %#ok<AGROW>
            end
        case 'clean_rawdata'
            % its own high-pass: a transition band [start end] whose end is
            % the pass-band edge ('off', or -1 in clean_rawdata's positional
            % form, when not used)
            hp = cleanRawdataHighpass(e.params);
            if (ischar(hp) && strcmpi(hp, 'off')) || isequal(hp, -1)
                parts{end+1} = sprintf('%s (no high-pass)', e.fn); %#ok<AGROW>
            elseif isnumeric(hp) && numel(hp) == 2 && all(isfinite(hp)) && hp(2) > 0
                f.highpass(end+1) = hp(2); parts{end+1} = sprintf('HP %g Hz (%s)', hp(2), e.fn); %#ok<AGROW>
            else
                f.other = f.other + 1; parts{end+1} = sprintf('%s (not parsed)', e.fn); %#ok<AGROW>
            end
    end
end
f.text = strjoin(parts, ' > ');
end

function hp = cleanRawdataHighpass(p)
% The Highpass option of a clean_rawdata call as read from the history.
% clean_artifacts takes its option names in any case, also as
% highpass_band, and uses [0.25 0.75] when the option is left out or [];
% '' when the call's options could not be read.
names = fieldnames(p);
at = find(strcmpi(names, 'Highpass') | strcmpi(names, 'highpass_band'), 1);
if ~isempty(at), hp = p.(names{at}); if isempty(hp), hp = [0.25 0.75]; end
elseif ~isempty(names), hp = [0.25 0.75];
else, hp = ''; end
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
    w{end+1} = sprintf('EEG.srate is %.17g, not an exact integer (common after EDF import); ICLabel fails on such data. PipeCompare rounds it on its own copy.', EEG.srate);
end
if ~s.hasUrevent
    w{end+1} = 'EEG.urevent is empty; PipeCompare will rebuild it (eeg_checkset makeur) on its own copy to track trials.';
end
s.warnings = w;
end

function P = provenance(s, EEG)
% Where each piece of knowledge about the dataset comes from:
%   recorded in EEG.history | executed by PipeCompare (tagged lines) |
%   session command (ALLCOM) not in this dataset's history |
%   inferred from the data structure | cannot be verified
P = struct('category', {}, 'item', {}, 'detail', {});
h = s.history;
for k = 1:numel(h)
    if ~any(strcmp(h(k).kind, {'process','mark','load'})), continue; end
    % lines tagged by PipeCompare, or by NeuroQC (its name up to 0.7)
    if contains(h(k).raw, '% PipeCompare') || contains(h(k).raw, '% NeuroQC') || startsWith(strtrim(h(k).statement), 'EEGica')
        P(end+1) = row('executed by PipeCompare', h(k).step, h(k).statement); %#ok<AGROW>
    else
        P(end+1) = row('recorded in EEG.history', h(k).step, sprintf('line %d: %s', h(k).line, h(k).statement)); %#ok<AGROW>
    end
    if ~isempty(h(k).note) && (contains(h(k).note, 'not in the history') || contains(h(k).note, 'not reproducible'))
        P(end+1) = row('cannot be verified', h(k).step, sprintf('line %d: %s', h(k).line, h(k).note)); %#ok<AGROW>
    end
end
global ALLCOM %#ok<GVMIS>
if iscell(ALLCOM)
    histText = char(EEG.history); histText = histText(:)';
    for k = numel(ALLCOM):-1:1
        c = strtrim(char(ALLCOM{k}));
        e = pipecompare.live.History.classify(c);
        if ~strcmp(e.kind, 'process') || contains(histText, c), continue; end
        P(end+1) = row('session command (ALLCOM) not in this dataset''s history', e.step, ...
            [c ' (may concern another dataset)']); %#ok<AGROW>
    end
end
steps = {s.process.step};
if s.isEpoched && ~any(strcmp(steps, 'epoch'))
    P(end+1) = row('inferred from the data', 'epoch', sprintf('%d epochs present; no pop_epoch in the history', s.trials));
end
if s.ica.present && ~any(strcmp(steps, 'ica'))
    P(end+1) = row('inferred from the data', 'ica', 'ICA matrices present; no ICA call in the history');
end
if ~isempty(s.ica.flagged)
    P(end+1) = row('inferred from the data', 'ic_flags', sprintf('ICs flagged in EEG.reject.gcompreject: %s', mat2str(s.ica.flagged)));
end
if ~isempty(s.removedChannels) && ~any(strcmp(steps, 'channels')) && ~any(strcmp(steps, 'badchannels'))
    P(end+1) = row('inferred from the data', 'channels', ['removed (chaninfo.removedchans): ' strjoin(s.removedChannels, ', ')]);
end
if any(strcmpi(s.reference, {'average', 'averef'})) && ~any(strcmp(steps, 'reref'))   % (pop_averef writes averef)
    P(end+1) = row('inferred from the data', 'reref', 'EEG.ref says average; no pop_reref in the history');
end
if isempty(h)
    P(end+1) = row('cannot be verified', '', 'EEG.history is empty: earlier processing is unknown');
end
end

function r = row(c, i, d)
r = struct('category', c, 'item', i, 'detail', d);
end

function tf = located(EEG)
% channels with finite X, Y and Z
if ~isfield(EEG, 'chanlocs') || isempty(EEG.chanlocs) || ~isfield(EEG.chanlocs, 'X'), tf = false(1, EEG.nbchan); return; end
ok = @(v) isnumeric(v) && isscalar(v) && isfinite(v);
tf = arrayfun(@(c) ok(c.X) && ok(c.Y) && ok(c.Z), EEG.chanlocs);
end
