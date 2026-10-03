classdef Injection
    %INJECTION Does a known signal survive the candidate's processing?
    %
    %   [EEGsig, truth] = neuroqc.eval.Injection.prepare(root, contract, ref, opts)
    %   r = neuroqc.eval.Injection.compare(EEGsig, contract, truth, path)
    %
    %   A noise-free copy of the starting dataset is built that contains
    %   only a known signal: for ERP contracts one Gaussian per component
    %   (centred in its window, sigma = window/4, amplitude opts.injectUv)
    %   with a smooth scalp topography centred on the component's ROI (or
    %   on the ROI channels only when channel locations are missing), added
    %   at every scored trial; for spectral contracts a sinusoid at each
    %   band's centre frequency on the band's ROI.
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
    %   Limits: ASR and native commands are re-run on the copy instead of
    %   replayed (their output is not a fixed function of a decision); such
    %   candidates carry a note. The expected re-referenced field uses the
    %   channels present at the end of the pipeline.

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
            if strcmp(contract.analysis, 'spectral')
                W = zeros(nch, numel(contract.bands));
                for b = 1:numel(contract.bands)
                    W(:, b) = topography(root, contract.bands(b).roi);
                    f0 = mean(contract.bands(b).freq);
                    t = (0:root.pnts-1) / fs;
                    S.data = S.data + cast(A * W(:, b) * sin(2 * pi * f0 * t), 'like', S.data);
                end
                truth = struct('kind', 'spectral', 'weights', W, 'labels', {labels}, 'A', A);
                return;
            end
            W = zeros(nch, numel(contract.components));
            for j = 1:numel(contract.components)
                W(:, j) = topography(root, contract.components(j).roi);
            end
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
            truth = struct('kind', 'erp', 'weights', W, 'labels', {labels}, 'A', A, ...
                'onsets', onsets, 'urevents', urs);
        end

        function r = compare(S, contract, truth, path)
            r = struct('source', 'injection', 'amplitudeError', NaN, 'latencyShiftMs', NaN, ...
                'artifactPct', NaN, 'waveformCorr', NaN, 'topoCorr', NaN, 'chain', '', 'note', '');
            Ew = expectedWeights(truth, {S.chanlocs.labels}, path);   % nch_leaf x nComp
            labs = lower({S.chanlocs.labels});
            if strcmp(truth.kind, 'spectral')
                errs = zeros(1, numel(contract.bands)); tc = errs;
                for b = 1:numel(contract.bands)
                    f0 = mean(contract.bands(b).freq);
                    amp = sineAmplitude(S, f0);                       % nch x 1
                    roi = ismember(labs, lower(contract.bands(b).roi));
                    e = truth.A * mean(Ew(roi, b));
                    errs(b) = abs(mean(amp(roi)) / e - 1);
                    tc(b) = safeCorr(amp, truth.A * abs(Ew(:, b)));
                end
                r.amplitudeError = max(errs); r.topoCorr = min(tc); r.latencyShiftMs = 0; r.artifactPct = 0;
                return;
            end
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
                [~, ix] = max(s * xp(w)); [~, iy] = max(s * rec(w)); tw = times(w);
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
for ep = 1:numel(S.epoch)
    lat = S.epoch(ep).eventlatency; typ = S.epoch(ep).eventtype; ue = S.epoch(ep).eventurevent;
    if ~iscell(lat), lat = {lat}; typ = {typ}; ue = {ue}; end
    typ = cellfun(@(x) strtrim(char(string(x))), typ, 'UniformOutput', false);
    z = find(abs(cell2mat(lat)) < 1e-6 & ismember(typ, codes), 1);
    if isempty(z) || isempty(ue{z}), return; end
    k = find(truth.urevents == ue{z}, 1);
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

function w = topography(EEG, roi)
labs = lower({EEG.chanlocs.labels});
inRoi = ismember(labs, lower(roi));
hasXYZ = isfield(EEG.chanlocs, 'X') && all(arrayfun(@(c) ~isempty(c.X) && ~isempty(c.Y) && ~isempty(c.Z), EEG.chanlocs));
if ~hasXYZ
    w = double(inRoi(:)); return;
end
xyz = [[EEG.chanlocs.X]' [EEG.chanlocs.Y]' [EEG.chanlocs.Z]'];
xyz = xyz ./ max(vecnorm(xyz, 2, 2), eps);
c = mean(xyz(inRoi, :), 1); c = c / norm(c);
ang = acos(max(-1, min(1, xyz * c')));
w = exp(-ang .^ 2 / (2 * 0.5 ^ 2));
w = w / mean(w(inRoi));
end

function g = template(t, contract)
g = zeros(numel(contract.components), numel(t));
for j = 1:numel(contract.components)
    win = contract.components(j).window;
    g(j, :) = exp(-0.5 * ((t - mean(win)) / (diff(win) / 4)) .^ 2);
end
end

function E = expectedWeights(truth, leafLabels, path)
% True field at the channels present now, re-referenced like the candidate.
[ok, loc] = ismember(lower(leafLabels), lower(truth.labels));
E = zeros(numel(leafLabels), size(truth.weights, 2));
E(ok, :) = truth.weights(loc(ok), :);
for q = 1:numel(path)
    in = path{q}; mode = ''; chans = {}; ex = false(numel(leafLabels), 1);
    if strcmp(in.type, 'reref')
        mode = in.params.mode; chans = cellstr(in.params.channels);
        if isfield(in.params, 'exclude'), ex = ismember(lower(leafLabels(:)), lower(cellstr(in.params.exclude))); end
    elseif strcmp(in.type, 'native')
        e = neuroqc.live.History.classify(in.params.command);
        if strcmp(e.step, 'reref') && isfield(e.params, 'mode'), mode = e.params.mode; end
    end
    switch mode
        case 'average'   % excluded channels neither enter the average nor change
            inc = ok(:) & ~ex;
            E(~ex, :) = E(~ex, :) - mean(E(inc, :), 1);
        case 'channels'
            [rk, rl] = ismember(lower(chans), lower(truth.labels));
            if any(rk), E(~ex, :) = E(~ex, :) - mean(truth.weights(rl(rk), :), 1); end
    end
end
end

function amp = sineAmplitude(S, f0)
% Least-squares amplitude of a sinusoid at f0 per channel (per epoch, averaged).
X = double(S.data); [nch, n, nt] = size(X);
t = (0:n-1)' / S.srate;
B = [sin(2 * pi * f0 * t) cos(2 * pi * f0 * t)];
amp = zeros(nch, 1);
for k = 1:nt
    beta = B \ X(:, :, k)';
    amp = amp + sqrt(sum(beta .^ 2, 1))';
end
amp = amp / nt;
end

function r = safeCorr(a, b)
a = a(:) - mean(a(:)); b = b(:) - mean(b(:));
d = norm(a) * norm(b);
if d <= eps || numel(a) < 3, r = NaN; else, r = (a' * b) / d; end
end
