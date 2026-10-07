classdef Montage
    %MONTAGE Do the channel labels match the electrode positions?
    %
    %   m = pipecompare.live.Montage.check(EEG)
    %
    %   Scalp EEG changes smoothly over the head, so after an average
    %   reference each channel resembles its nearest neighbours. A channel
    %   that does not is either a bad channel or not where its label (and
    %   so its location) says; a channel that does not resemble its
    %   neighbours but closely resembles channels elsewhere on the head
    %   points to a label mix-up, which also misleads interpolation and
    %   ICLabel (both use the positions).
    %
    %   What is checked: the EEG channels with a location (not EOG, ECG,
    %   ... and not ear or mastoid sites; see pipecompare.simple.Presets),
    %   at least MinChannels of them, on a sample of the data: the first
    %   SampleSeconds of continuous data, or as many epochs as fit in that
    %   time, each epoch's mean removed. The sample is band-passed 1-30 Hz
    %   (in the frequency domain, on PipeCompare's copy) and average
    %   referenced. For each channel, nn = its mean correlation with its
    %   Neighbours nearest channels (straight-line distance between the
    %   positions on the unit sphere).
    %
    %   Flagged: robust z of nn (median and MAD over the channels, the MAD
    %   at least MinMad) below MinZ, or nn below MinCorr while the median
    %   nn is at least MedianForCorr (on sparse caps the neighbours are far
    %   apart and resemble each other less, so there only the z criterion
    %   applies). The worst channel is flagged first and the check runs
    %   again without it as a neighbour (a swapped channel would otherwise
    %   also pull down its neighbours), at most a quarter of the channels.
    %   Each flagged channel is reported with the two channels it
    %   resembles most (or "resembles no channel" when none reaches
    %   LikeCorr: rather a bad channel than a swapped one).
    %
    %   m.labels, m.nn   the channels checked and their neighbour correlation
    %   m.median         median nn
    %   m.flagged        labels of the flagged channels
    %   m.like           per flagged channel, the text of what it resembles
    %   m.text           the warning ('' when nothing is flagged or the
    %                    check could not run; then m.skipped says why)
    %
    %   A warning only: nothing is changed and nothing is blocked. The
    %   last result is kept for the same dataset (Session.fingerprint).

    properties (Constant)
        SampleSeconds = 600
        MaxValues = 2e7       % channels x samples in the sample at most (memory)
        MinChannels = 8
        Neighbours = 3
        MinZ = -3
        MinMad = 0.05         % the spread used for z is at least this (clean data: tiny spread)
        MinCorr = 0.1
        MedianForCorr = 0.3
        LikeCorr = 0.3
    end

    methods (Static)
        function m = check(EEG)
            persistent lastKey lastM
            key = pipecompare.live.Session.fingerprint(EEG);
            if ~isempty(lastKey) && strcmp(key, lastKey), m = lastM; return; end
            m = struct('labels', {{}}, 'nn', [], 'median', NaN, 'flagged', {{}}, 'like', {{}}, 'text', '', 'skipped', '');
            try
                m = compute(EEG, m);
            catch ME
                m.skipped = ME.message;
            end
            lastKey = key; lastM = m;
        end
    end
end

function m = compute(EEG, m)
M = pipecompare.live.Montage;
locs = EEG.chanlocs(:)';
ok = @(v) isnumeric(v) && isscalar(v) && isfinite(v);
located = arrayfun(@(c) isfield(c, 'X') && ok(c.X) && ok(c.Y) && ok(c.Z), locs);
use = find(located & ~pipecompare.simple.Presets.isNonEeg(locs));
if numel(use) < M.MinChannels
    m.skipped = sprintf('fewer than %d EEG channels with locations', M.MinChannels); return;
end
fs = EEG.srate;
maxPts = min(round(M.SampleSeconds * fs), floor(M.MaxValues / numel(use)));
if EEG.trials == 1
    X = single(EEG.data(use, 1:min(EEG.pnts, maxPts)));
else
    nEp = min(EEG.trials, max(1, floor(maxPts / EEG.pnts)));
    X = single(EEG.data(use, :, 1:nEp));
    X = reshape(X - mean(X, 2), numel(use), []);   % each epoch's mean removed, then joined
end
N = size(X, 2);
assert(N >= 10 * fs, 'PipeCompare:Montage', 'less than 10 s of data');
% 1-30 Hz in the frequency domain, channel by channel (no toolbox, little memory)
f = (0:N-1) * fs / N; f = min(f, fs - f);
stop = f < 1 | f > 30;
for c = 1:size(X, 1)
    F = fft(double(X(c, :)));
    F(stop) = 0;
    X(c, :) = real(ifft(F));
end
X = X - mean(X, 1);                                % average reference over the checked channels
X = double(X); X = X - mean(X, 2);
sd = sqrt(sum(X .^ 2, 2));
live = sd > 0;                                     % a flat channel is left to the bad-channel test
Z = X(live, :) ./ sd(live);
R = Z * Z';
use = use(live); labels = {locs(use).labels};
P = [[locs(use).X]' [locs(use).Y]' [locs(use).Z]'];
P = P ./ sqrt(sum(P .^ 2, 2));
D = sqrt(max(0, sum(P .^ 2, 2) + sum(P .^ 2, 2)' - 2 * (P * P')));
D(1:size(D, 1) + 1:end) = Inf;
n = numel(use);
% worst channel first, then again without it: a swapped channel would
% otherwise also pull down the correlation of its own neighbours
out = false(1, n);
while true
    nn = zeros(1, n);
    for i = 1:n
        d = D(i, :); d(out) = Inf;
        [~, o] = sort(d);
        nn(i) = mean(R(i, o(1:M.Neighbours)));
    end
    med = median(nn(~out));
    mad = max(M.MinMad, 1.4826 * median(abs(nn(~out) - med)));
    z = (nn - med) / mad;
    cand = find(~out & (z < M.MinZ | (nn < M.MinCorr & med >= M.MedianForCorr)));
    if isempty(cand) || sum(out) >= floor(n / 4), break; end
    [~, w] = min(nn(cand)); out(cand(w)) = true;
end
flag = find(out);
m.labels = labels; m.nn = nn; m.median = med;
m.flagged = labels(flag);
m.like = cell(1, numel(flag));
for k = 1:numel(flag)
    r = R(flag(k), :); r(flag(k)) = -Inf;
    [v, o] = sort(r, 'descend');
    if v(1) < M.LikeCorr
        m.like{k} = 'resembles no channel: rather a bad channel';
    else
        top = o(1:min(2, sum(v >= M.LikeCorr)));
        m.like{k} = ['most like ' strjoin(arrayfun(@(j) sprintf('%s r = %.2f', labels{j}, R(flag(k), j)), top, ...
            'UniformOutput', false), ', ')];
    end
end
if isempty(flag), return; end
items = arrayfun(@(k) sprintf('%s (r = %.2f with its neighbours; %s)', m.flagged{k}, nn(flag(k)), m.like{k}), ...
    1:numel(flag), 'UniformOutput', false);
m.text = sprintf(['Montage check: %s do%s not resemble %s neighbours (correlation with the nearest ', ...
    'channels; median over the other channels %.2f), so %s label%s may not match where the electrode%s were, or %s bad: %s. A label ', ...
    'mix-up also misleads interpolation and ICLabel; check the montage with whoever recorded the data. The ', ...
    'comparison runs anyway.'], pipecompare.utils.ternary(numel(flag) > 1, 'these channels', 'this channel'), ...
    pipecompare.utils.ternary(numel(flag) > 1, '', 'es'), pipecompare.utils.ternary(numel(flag) > 1, 'their', 'its'), med, ...
    pipecompare.utils.ternary(numel(flag) > 1, 'their', 'its'), pipecompare.utils.ternary(numel(flag) > 1, 's', ''), ...
    pipecompare.utils.ternary(numel(flag) > 1, 's', ''), pipecompare.utils.ternary(numel(flag) > 1, 'they are', 'it is'), ...
    strjoin(items, '; '));
end
