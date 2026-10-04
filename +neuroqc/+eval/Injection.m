classdef Injection
    %INJECTION Does a known signal survive the candidate's processing?
    %
    %   [EEGsig, truth] = neuroqc.eval.Injection.prepare(root, contract, ref, opts)
    %   r = neuroqc.eval.Injection.compare(EEGsig, contract, truth, path)
    %
    %   A noise-free copy of the starting dataset is built that contains
    %   only a known signal: one Gaussian per component (centred in its
    %   window, sigma = window/4, amplitude opts.injectUv) with a smooth
    %   scalp topography centred on the component's ROI over the channels
    %   that have locations (a box over the ROI only when no ROI channel
    %   has one), added at every scored trial.
    %
    %   compare() also returns the gain of each measure (recovered /
    %   expected window mean, or peak; 1 for a latency), by which Rank
    %   divides the SME (docs/METHODS.md, section 2).
    %
    %   The executor applies to this copy exactly the operations and the
    %   data-driven DECISIONS taken on the real data (same filters, same
    %   reference, same bad channels interpolated, same ICA matrices and
    %   removed components, same rejected epochs; see
    %   neuroqc.run.Steps.replayDecision). Because all of these are linear
    %   given the decisions, the processed copy is exactly how the
    %   candidate transfers the signal. It is compared with the expected
    %   signal (the injected one, re-referenced like the candidate - a
    %   change of reference is not distortion):
    %
    %     amplitudeError  max over components |recovered/expected - 1| (window mean)
    %     latencyShiftMs  max peak-latency shift
    %     artifactPct     opposite-polarity deflection beyond the expected one
    %     waveformCorr    min correlation of recovered vs expected waveform
    %     topoCorr        min correlation of recovered vs expected topography
    %
    %   ASR applies the reconstructions it chose on the real data
    %   (neuroqc.run.AsrRecord). Native commands other than mark/remove
    %   workflows are re-run on the copy instead of replayed; such
    %   candidates carry a note. The expected re-referenced field uses the
    %   channels present WHEN each reference was applied (recorded on the
    %   copy by noteReference), so channels removed afterwards do not
    %   change the expected values of the channels that remain.

    methods (Static)
        function [S, truth] = prepare(root, contract, ref, opts)
            if nargin < 4, opts = struct(); end
            if ~isfield(opts, 'injectUv'), opts.injectUv = 5; end
            labels = {root.chanlocs.labels};
            A = opts.injectUv;
            S = root;
            S.data = zeros(size(root.data), 'like', root.data);
            S.icaact = [];
            nch = root.nbchan; fs = root.srate;
            % the field over the whole montage, including channels removed before
            % NeuroQC that a restore step can interpolate back (their expected
            % value after restoring is the true field there)
            [full, labels] = montage(root);
            Wfull = zeros(numel(full), numel(contract.components));
            for j = 1:numel(contract.components)
                Wfull(:, j) = topography(struct('chanlocs', {full}), contract.components(j).roi);
            end
            W = Wfull(1:nch, :);
            tt = (round(contract.epoch(1) * fs):round(contract.epoch(2) * fs)) / fs;
            g = template(tt, contract);                       % nComp x samples
            sig = A * (W * g);                                % nch x samples
            onsets = []; urs = [];
            if root.trials == 1
                codes = contract.allEvents();
                for e = 1:numel(root.event)
                    ev = root.event(e);
                    if ~any(strcmp(strtrim(char(string(ev.type))), codes)), continue; end
                    % every condition event carries the signal (also trials a trial rule
                    % excludes): epoching averages all of them, so the known amplitude must
                    % be present in each, whichever trials the measure later keeps.
                    c0 = round(ev.latency);
                    onsets(end+1) = (c0 - 1) / fs; %#ok<AGROW>
                    if isfield(ev, 'urevent') && ~isempty(ev.urevent), urs(end+1) = ev.urevent; else, urs(end+1) = NaN; end %#ok<AGROW>
                    cols = c0 + round(contract.epoch(1) * fs) + (0:numel(tt)-1);
                    ok = cols >= 1 & cols <= root.pnts;
                    S.data(:, cols(ok)) = S.data(:, cols(ok)) + cast(sig(:, ok), 'like', S.data);
                end
            else
                times = root.xmin + (0:root.pnts-1) / fs;
                [~, i0] = min(abs(times - tt(1)));
                cols = i0 + (0:numel(tt)-1); ok = cols <= root.pnts;
                S.data(:, cols(ok), :) = S.data(:, cols(ok), :) + cast(sig(:, ok), 'like', S.data);
            end
            % onsets/urevents let compare() build the expected average when
            % epochs overlap (neighbouring events inside one epoch window)
            truth = struct('kind', 'erp', 'weights', Wfull, 'labels', {labels}, 'A', A, ...
                'onsets', onsets, 'urevents', urs);
        end

        function S = noteReference(S, inst)
            % Record the channel set a re-reference step is about to use
            % (called on the injected copy before the step runs).
            mode = ''; chans = {}; ex = {};
            if strcmp(inst.type, 'reref')
                mode = inst.params.mode; chans = cellstr(inst.params.channels);
                if isfield(inst.params, 'exclude'), ex = cellstr(inst.params.exclude); end
            elseif strcmp(inst.type, 'native')
                % an EEGLAB pop_reref command: its reference and excluded
                % channels, resolved to labels on the data as they are now
                labs = {S.chanlocs.labels};
                for stmt = neuroqc.run.Native.statements(inst.params.command)
                    e = neuroqc.live.History.classify(stmt{1});
                    if ~strcmp(e.step, 'reref'), continue; end
                    a = neuroqc.run.Native.argsOf(stmt{1}, 'pop_reref');
                    ref = []; if ~isempty(a), ref = a{1}; end
                    if isempty(ref), mode = 'average'; else, mode = 'channels'; chans = toLabels(ref, labs); end
                    k = find(cellfun(@(x) ischar(x) && strcmpi(x, 'exclude'), a(2:end)), 1);
                    if ~isempty(k) && numel(a) > k + 1, ex = toLabels(a{k + 2}, labs); end
                end
            end
            if isempty(mode), return; end
            rec = struct('mode', mode, 'channels', {chans}, 'exclude', {ex}, 'labels', {{S.chanlocs.labels}});
            if ~isfield(S.etc, 'neuroqc') || ~isfield(S.etc.neuroqc, 'refLog'), S.etc.neuroqc.refLog = {}; end
            S.etc.neuroqc.refLog{end+1} = rec;
        end

        function r = compare(S, contract, truth, path)
            r = struct('source', 'injection', 'amplitudeError', NaN, 'latencyShiftMs', NaN, ...
                'artifactPct', NaN, 'waveformCorr', NaN, 'topoCorr', NaN, 'chain', '', 'note', '', ...
                'notApplicable', {{}}, ...   % NaN in an applicable metric = check failed (Rank rejects it)
                'gain', nan(1, numel(contract.components)));   % signal gain per component (see below)
            Ew = expectedWeights(truth, S, path);                    % nch_leaf x nComp
            labs = lower({S.chanlocs.labels});
            if S.trials == 1
                [~, S] = evalc('pop_epoch(S, contract.allEvents(), contract.epoch, ''epochinfo'', ''yes'')');
            end
            times = S.xmin + (0:S.pnts-1) / S.srate;
            bl = times >= contract.baseline(1) - 1e-9 & times <= contract.baseline(2) + 1e-9;
            avg = mean(double(S.data), 3);
            avg = avg - mean(avg(:, bl), 2);
            g = expectedTimeCourse(S, times, contract, truth);
            ex = truth.A * (Ew * g);
            ex = ex - mean(ex(:, bl), 2);
            nJ = numel(contract.components);
            amp = nan(1, nJ); lat = amp; wc = amp; tc = amp; art = amp;
            for j = 1:nJ
                comp = contract.components(j);
                roi = ismember(labs, lower(comp.roi));
                w = times >= comp.window(1) - 1e-9 & times <= comp.window(2) + 1e-9;
                rec = mean(avg(roi, :), 1); xp = mean(ex(roi, :), 1);
                mx = mean(xp(w)); s = sign(mx); if s == 0, s = 1; end
                amp(j) = abs(mean(rec(w)) / mx - 1);
                [px, ix] = max(s * xp(w)); [py, iy] = max(s * rec(w)); tw = times(w);
                % Gain of the measured quantity: the factor by which the
                % pipeline scales a signal in this component's score (a linear
                % functional of the data). Rank divides the SME by it, so a
                % pipeline that shrinks signal and noise alike gains nothing.
                switch comp.measure
                    case 'mean', r.gain(j) = mean(rec(w)) / mx;
                    case 'peakAmplitude', r.gain(j) = py / px;
                    otherwise, r.gain(j) = 1;   % a latency does not scale with amplitude
                end
                lat(j) = 1000 * abs(tw(iy) - tw(ix));
                wc(j) = safeCorr(rec, xp);
                tc(j) = safeCorr(mean(avg(:, w), 2), mean(ex(:, w), 2));
                art(j) = max(0, max(-s * rec) - max(0, max(-s * xp))) / max(abs(xp));
            end
            r.amplitudeError = max(amp); r.latencyShiftMs = max(lat); r.waveformCorr = min(wc);
            r.topoCorr = min(tc); r.artifactPct = max(art);
        end
    end
end

% ---------------------------------------------------------------------
function L = toLabels(x, labs)
% channel indices or labels -> labels
if isnumeric(x), L = labs(x); else, L = cellstr(x); end
L = L(:)';
end

function g = expectedTimeCourse(S, times, contract, truth)
% Average over the kept epochs of every injected template that falls in
% each epoch, so overlapping epochs (events closer than the epoch length)
% are expected, not read as distortion. Falls back to the single template
% when the epochs cannot be mapped to injected events.
g = template(times, contract);
if ~isfield(truth, 'onsets') || isempty(truth.onsets) || ~isfield(S, 'epoch') || isempty(S.epoch), return; end
codes = contract.allEvents();
span = [times(1) times(end)];
G = zeros(size(g)); n = 0;
lock = neuroqc.eval.Measure.lockingEvents(S, codes);
for ep = 1:numel(S.epoch)
    if lock(ep) == 0 || ~isfield(S.event, 'urevent') || isempty(S.event(lock(ep)).urevent), return; end
    k = find(truth.urevents == S.event(lock(ep)).urevent, 1);
    if isempty(k), return; end
    L = truth.onsets(k);
    near = find(truth.onsets >= L + span(1) - diff(span) & truth.onsets <= L + span(2) + diff(span));
    for o = near
        rel = times + L - truth.onsets(o);              % time relative to that onset
        inWin = rel >= contract.epoch(1) - 1e-9 & rel <= contract.epoch(2) + 1e-9;   % injected span
        G = G + template(rel, contract) .* inWin;
    end
    n = n + 1;
end
if n > 0, g = G / n; end
end

function [full, labels] = montage(root)
% channel labels and positions: the data's channels, then the restorable
% channels removed before NeuroQC
f = {'labels', 'X', 'Y', 'Z'};
pick = @(c) cell2struct(cellfun(@(n) fieldOrEmpty(c, n), f, 'UniformOutput', false), f, 2);
full = arrayfun(pick, root.chanlocs);
if isfield(root, 'etc') && isstruct(root.etc) && isfield(root.etc, 'neuroqc') && isfield(root.etc.neuroqc, 'preRemoved')
    full = [full(:); arrayfun(pick, root.etc.neuroqc.preRemoved(:))]';
end
full = full(:)';
labels = {full.labels};
end

function v = fieldOrEmpty(c, n)
if isfield(c, n), v = c.(n); else, v = []; end
end

function w = topography(EEG, roi)
% A smooth field centred on the ROI (Gaussian in the angle on the unit
% sphere, sigma 0.5 rad), normalised to mean 1 over the ROI. Channels
% without coordinates (often EOG/ECG) get no field outside the ROI and the
% ROI's mean field inside it; the field is not reduced to a box because of
% them. A box over the ROI is used only when no ROI channel has a position.
labs = lower({EEG.chanlocs.labels});
inRoi = ismember(labs, lower(roi)); inRoi = inRoi(:);
has = located(EEG.chanlocs); has = has(:);
if ~any(has & inRoi)
    w = double(inRoi); return;
end
xyz = [[EEG.chanlocs(has).X]' [EEG.chanlocs(has).Y]' [EEG.chanlocs(has).Z]'];
xyz = xyz ./ max(vecnorm(xyz, 2, 2), eps);
c = mean(xyz(inRoi(has), :), 1); c = c / norm(c);
ang = acos(max(-1, min(1, xyz * c')));
w = zeros(numel(labs), 1);
w(has) = exp(-ang .^ 2 / (2 * 0.5 ^ 2));
w = w / mean(w(has & inRoi));
w(~has & inRoi) = 1;
end

function tf = located(chanlocs)
% channels with finite X, Y and Z
ok = @(v) isnumeric(v) && isscalar(v) && isfinite(v);
tf = arrayfun(@(c) isfield(c, 'X') && ok(c.X) && ok(c.Y) && ok(c.Z), chanlocs);
end

function g = template(t, contract)
g = zeros(numel(contract.components), numel(t));
for j = 1:numel(contract.components)
    win = contract.components(j).window;
    g(j, :) = exp(-0.5 * ((t - mean(win)) / (diff(win) / 4)) .^ 2);
end
end

function E = expectedWeights(truth, S, path)
% True field at the channels present now, re-referenced like the candidate.
% Each reference is applied over the channels present at that moment
% (S.etc.neuroqc.refLog); channels absent then but restored later are
% interpolated from re-referenced data and carry the same offset.
leafLabels = {S.chanlocs.labels};
log = {};
if isfield(S, 'etc') && isfield(S.etc, 'neuroqc') && isfield(S.etc.neuroqc, 'refLog')
    log = S.etc.neuroqc.refLog;
else
    % no record (copy not produced by the executor): assume the reference
    % saw the final channel set
    for q = 1:numel(path)
        rec = neuroqc.eval.Injection.noteReference(struct('chanlocs', {S.chanlocs}, 'etc', struct()), path{q});
        if isfield(rec.etc, 'neuroqc'), log = [log rec.etc.neuroqc.refLog]; end %#ok<AGROW>
    end
end
F = truth.weights;                              % all starting channels x nComp
labs0 = lower(truth.labels(:));
for q = 1:numel(log)
    r = log{q};
    ex = ismember(labs0, lower(r.exclude));
    switch r.mode
        case 'average'   % excluded channels neither enter the average nor change
            inc = ismember(labs0, lower(r.labels)) & ~ex;
            F(~ex, :) = F(~ex, :) - mean(F(inc, :), 1);
        case 'channels'
            rk = ismember(labs0, lower(r.channels));
            if any(rk), F(~ex, :) = F(~ex, :) - mean(F(rk, :), 1); end
    end
end
[ok, loc] = ismember(lower(leafLabels), labs0);
E = zeros(numel(leafLabels), size(F, 2));
E(ok, :) = F(loc(ok), :);
end


function r = safeCorr(a, b)
a = a(:) - mean(a(:)); b = b(:) - mean(b(:));
d = norm(a) * norm(b);
if d <= eps || numel(a) < 3, r = NaN; else, r = (a' * b) / d; end
end
