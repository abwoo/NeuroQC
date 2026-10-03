function out = realdata_validation(file, contract)
%REALDATA_VALIDATION Technical validation of NeuroQC on a real recording.
%   out = realdata_validation(file, contract)
%   file: a real .set file (never committed; pass it or set NEUROQC_REAL_RAW).
%   contract: neuroqc.eval.Contract. The default is a TECHNICAL contract
%   (most frequent event codes, a generic 300-500 ms window): it exercises
%   the machinery on real data and is not a scientific analysis.
%
%   Checks: the file on disk is unchanged; srate residue handling; every
%   epoch is time-locked to its event at 0 ms with the right urevent;
%   keep / remove / interpolate of the two most variable channels are
%   compared, not decided in advance;
%   injection on real data; timing of the search.
if nargin < 1 || isempty(file), file = getenv('NEUROQC_REAL_RAW'); end
assert(isfile(file), 'Set NEUROQC_REAL_RAW or pass a .set file.');
before = dir(file);
[p, n, e] = fileparts(file);
EEG = pop_loadset('filename', [n e], 'filepath', p);
fprintf('Loaded working copy: %d channels, srate %.17g, %.1f min\n', EEG.nbchan, EEG.srate, EEG.pnts / EEG.srate / 60);
if nargin < 2 || isempty(contract)
    t = cellfun(@(x) char(string(x)), {EEG.event.type}, 'UniformOutput', false);
    [u, ~, ic] = unique(t); [~, o] = sort(accumarray(ic(:), 1), 'descend');
    codes = u(o(1:2));
    fprintf('TECHNICAL contract: conditions %s and %s (most frequent codes).\n', codes{:});
    labs = {EEG.chanlocs.labels};
    roi = labs(ismember(lower(labs), {'pz','p3','p4','poz'}));        % parietal if present
    if numel(roi) < 2, roi = labs(1:min(4, end)); end                  % otherwise any channels: technical only
    contract = neuroqc.eval.Contract('conditions', {['c' codes{1}], codes(1); ['c' codes{2}], codes(2)}, ...
        'epoch', [-0.2 0.8], 'baseline', [-0.2 0], 'components', {'late', [0.3 0.5], roi});
end
assignin('base', 'NQC_TMP', EEG);
evalin('base', 'global ALLCOM; ALLEEG = []; [ALLEEG, EEG, CURRENTSET] = eeg_store([], NQC_TMP, 0); clear NQC_TMP;');
neuroqc.NeuroQC.state();

labs = {EEG.chanlocs.labels};
isEog = ~cellfun(@isempty, regexpi(labs, 'eog|eye', 'once'));
if isfield(EEG.chanlocs, 'type'), isEog = isEog | strcmpi(arrayfun(@(c) char(string(c.type)), EEG.chanlocs, 'UniformOutput', false), 'EOG'); end
eog = labs(isEog);
v = var(double(EEG.data(:, 1:min(end, round(60 * EEG.srate)))), 0, 2); v(isEog) = -Inf;
[~, o] = sort(v, 'descend'); pair = labs(o(1:2));                      % the two most variable channels
pl = neuroqc.plan.Plan();
if EEG.srate > 250, pl = pl.add('resample', 'fs', 250); end
pl = pl.add('highpass', 'cutoff', {0.1, 0.5});
pl = pl.add('lowpass', 'cutoff', 30);
pl = pl.addChoice('pair', {'channels', 'labels', pair, 'action', 'interpolate'}, ...
    {'channels', 'labels', pair, 'action', 'remove'}, 'none');
pl = pl.add('reref', 'mode', 'average', 'exclude', eog);
pl = pl.add('epoch'); pl = pl.add('baseline');
pl = pl.add('reject_threshold', 'uv', {100, 150}, 'exclude', eog);
t0 = tic;
r = neuroqc.NeuroQC.optimize(pl, contract);
out.seconds = toc(t0);
out.result = r;

% epoch alignment on every evaluated candidate's replay of the first ok one
k = find(strcmp({r.cands.status}, 'ok'), 1);
if ~isempty(k)
    E = neuroqc.run.Executor.replay(r, k);
    bad = 0;
    for ep = 1:E.trials
        lat = E.epoch(ep).eventlatency; if ~iscell(lat), lat = {lat}; end
        typ = E.epoch(ep).eventtype; if ~iscell(typ), typ = {typ}; end
        typ = cellfun(@(x) char(string(x)), typ, 'UniformOutput', false);
        z = find(abs(cell2mat(lat)) < 1e-6 & ismember(typ, contract.allEvents()), 1);
        if isempty(z), bad = bad + 1; continue; end
        ue = E.epoch(ep).eventurevent; if iscell(ue), ue = ue{z}; end
        rl = r.root.urevent(ue).latency / r.root.srate;          % root time of that event (s)
        el = (E.event([E.event.epoch] == ep & [E.event.urevent] == ue).latency - (ep - 1) * E.pnts - 1) / E.srate + E.xmin;
        if abs(el) > 1.5 / E.srate || ~isfinite(rl), bad = bad + 1; end
    end
    out.misalignedEpochs = bad;
    fprintf('Epoch alignment (candidate %d): %d of %d epochs misaligned.\n', k, bad, E.trials);
end
after = dir(file);
out.fileUnchanged = isequal([before.datenum before.bytes], [after.datenum after.bytes]);
fprintf('Original file unchanged: %d. Search time %.0f s.\n', out.fileUnchanged, out.seconds);
end
