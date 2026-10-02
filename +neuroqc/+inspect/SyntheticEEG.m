classdef SyntheticEEG
    % SyntheticEEG - Golden test data: EEG + blink + line noise + drift + P300
    % Deterministic (seeded) for regression tests
    
    methods (Static)
        function [EEG, truth] = generate(opts)
            if nargin < 1, opts = struct(); end
            defaults = struct( ...
                'srate', 250, ...
                'durationSec', 120, ...
                'nChannels', 32, ...
                'seed', 42, ...
                'nTarget', 60, ...
                'nStandard', 180, ...
                'p300Uv', 8, ...
                'n200Uv', -3, ...
                'lineNoiseUv', 5, ...
                'lineHz', 50, ...
                'driftUv', 15, ...
                'blinkRateHz', 0.2, ...
                'noiseUv', 4, ...
                'badChannels', [], ...
                'fsActual', 250);
            fn = fieldnames(defaults);
            for i = 1:numel(fn)
                if ~isfield(opts, fn{i}), opts.(fn{i}) = defaults.(fn{i}); end
            end
            
            rng(opts.seed);
            fs = opts.fsActual;
            nSamp = round(opts.durationSec * fs);
            nch = opts.nChannels;
            
            labels = channelLabels(nch);
            
            % Pink-ish noise
            data = zeros(nch, nSamp);
            for ch = 1:nch
                white = randn(1, nSamp);
                % crude 1/f via cumulative filtering
                x = filter(1, [1 -0.9], white);
                data(ch, :) = x / (std(x) + eps) * opts.noiseUv * 1e-6;
            end
            
            t = (0:nSamp-1) / fs;
            
            % Drift
            drift = opts.driftUv * 1e-6 * sin(2*pi*0.05*t + rand*2*pi);
            data = data + drift;
            
            % Line noise
            line = opts.lineNoiseUv * 1e-6 * sin(2*pi*opts.lineHz*t);
            data = data + line;
            
            % Events: alternating structure oddball-like
            events = struct('type', {}, 'latency', {}, 'duration', {});
            
            % Start at 10 s, ISI ~1 s
            latS = round(10 * fs);
            isiS = round(1.0 * fs);
            targetCnt = 0;
            standardCnt = 0;
            seq = odddballSequence(opts.nTarget + opts.nStandard, ...
                opts.nTarget / (opts.nTarget + opts.nStandard));
            
            for k = 1:numel(seq)
                if latS + round(1.2*fs) > nSamp, break; end
                if seq(k) == 1 && targetCnt < opts.nTarget
                    typ = 's1002';
                    targetCnt = targetCnt + 1;
                    % Inject P300 + N200 at fronto-parietal channels
                    data = injectERPInto(data, latS, fs, ...
                        opts.p300Uv, opts.n200Uv, labels);
                elseif seq(k) == 0 && standardCnt < opts.nStandard
                    typ = 's1001';
                    standardCnt = standardCnt + 1;
                    % smaller N200 only
                    data = injectERPInto(data, latS, fs, ...
                        0, opts.n200Uv*0.5, labels);
                else
                    latS = latS + isiS;
                    continue;
                end
                events(end+1) = struct('type', typ, 'latency', latS, 'duration', 0); %#ok<AGROW>
                latS = latS + isiS;
            end
            
            % Start marker
            events = [struct('type', 's1000', 'latency', 5, 'duration', 0), events];
            
            % Blinks (frontal)
            blinkPeriod = max(1, round(fs / max(opts.blinkRateHz, 0.01)));
            eogIdx = find(ismember(labels, {'Fp1', 'Fp2', 'VEOG'}));
            if isempty(eogIdx), eogIdx = 1; end
            for b = round(5*fs):blinkPeriod:nSamp-round(0.3*fs)
                width = round(0.15 * fs);
                env = hann(2*width+1)';
                for ei = eogIdx(:)'
                    data(ei, b-width:min(nSamp, b+width)) = ...
                        data(ei, b-width:min(nSamp, b+width)) - 50e-6 * env(1:min(width+1+ (min(nSamp,b+width)-(b-width)), numel(env)));
                end
            end
            
            % Bad channels: flatline / extreme variance
            truth.badChannels = opts.badChannels;
            if isempty(opts.badChannels) && nch >= 10
                truth.badChannels = [7];
            end
            for ch = truth.badChannels
                if ch >= 1 && ch <= nch
                    data(ch, :) = 1e-15 * randn(1, nSamp);
                end
            end
            
            EEG = struct();
            EEG.setname = 'synthetic_oddball';
            EEG.filename = '';
            EEG.filepath = '';
            EEG.subject = 'Synthetic01';
            EEG.group = '';
            EEG.condition = '';
            EEG.comments = 'NeuroQC synthetic golden dataset';
            EEG.nbchan = nch;
            EEG.data = data;
            EEG.pnts = nSamp;
            EEG.trials = 1;
            EEG.srate = fs;
            EEG.xmin = 0;
            EEG.xmax = opts.durationSec - 1/fs;
            EEG.times = t * 1000;
            EEG.xmin = 0;
            EEG.event = events;
            EEG.urevent = events;
            EEG.eventdescription = {};
            EEG.chanlocs = struct('labels', {}, 'X', {}, 'Y', {}, 'Z', {}, 'theta', {}, 'radius', {});
            for i = 1:nch
                [x, y, z] = toyLoc(i, nch);
                EEG.chanlocs(i) = struct('labels', labels{i}, 'X', x, 'Y', y, 'Z', z, ...
                    'theta', atan2d(y, x), 'radius', sqrt(x^2+y^2));
            end
            EEG.ref = 'unknown';
            EEG.chaninfo = [];
            EEG.icaweights = [];
            EEG.icasphere = [];
            EEG.icawinv = [];
            EEG.icasphere = [];
            EEG.icachansind = [];
            EEG.icaact = [];
            EEG.specdata = [];
            EEG.specicaact = [];
            EEG.reject = struct();
            EEG.stats = struct();
            EEG.specdata = [];
            EEG.etc = struct();
            
            truth.fs = fs;
            truth.lineHz = opts.lineHz;
            truth.nTarget = targetCnt;
            truth.nStandard = standardCnt;
            truth.p300Uv = opts.p300Uv;
            truth.opts = opts;
            truth.labels = labels;
        end
    end
end

function seq = odddballSequence(n, pTarget)
    % Random sequence with roughly pTarget fraction of 1s
    rng(43);
    seq = zeros(1, n);
    nT = round(n * pTarget);
    seq(1:nT) = 1;
    seq = seq(randperm(n));
    for i = 3:n
        if all(seq(i-2:i) == 1)
            seq(i) = 0;
        end
    end
end

function data = injectERPInto(data, onset, fs, p300Uv, n200Uv, labels)
    nSamp = size(data, 2);

    % N200 Gaussian at 200 ms
    tN = (0:round(0.4*fs)) / fs;
    n200 = n200Uv * 1e-6 * exp(-0.5 * ((tN - 0.20) / 0.04).^2);
    i0 = onset;
    i1 = min(nSamp, onset + numel(n200) - 1);
    if i0 >= 1 && i0 <= nSamp
        segLen = i1 - i0 + 1;
        for ch = 1:numel(labels)
            w = 1.0;
            if startsWith(labels{ch}, 'F'), w = 1.2; end
            if startsWith(labels{ch}, 'P') || startsWith(labels{ch}, 'O'), w = 0.6; end
            data(ch, i0:i1) = data(ch, i0:i1) + w * n200(1:segLen);
        end
    end

    % P300 Gaussian at 400 ms (parietal)
    if p300Uv ~= 0
        tP = (0:round(0.5*fs)) / fs;
        p300 = p300Uv * 1e-6 * exp(-0.5 * ((tP - 0.40) / 0.08).^2);
        i0 = onset;
        i1 = min(nSamp, onset + numel(p300) - 1);
        if i0 >= 1 && i0 <= nSamp
            segLen = i1 - i0 + 1;
            for ch = 1:numel(labels)
                w = 0.3;
                if startsWith(labels{ch}, 'P') || startsWith(labels{ch}, 'CP'), w = 1.3; end
                if startsWith(labels{ch}, 'C'), w = 1.0; end
                if startsWith(labels{ch}, 'F'), w = 0.5; end
                data(ch, i0:i1) = data(ch, i0:i1) + w * p300(1:segLen);
            end
        end
    end
end

function labels = channelLabels(n)
    base = {'Fp1','Fp2','F7','F3','Fz','F4','F8','FC5','FC1','FC2', ...
        'FC6','T7','C3','Cz','C4','T8','TP9','CP5','CP1','CP2', ...
        'CP6','TP10','P7','P3','Pz','P4','P8','O1','Oz','O2','AF7','AF8'};
    if n <= numel(base)
        labels = base(1:n);
    else
        labels = [base, arrayfun(@(k) sprintf('X%d', k), numel(base)+1:n, 'UniformOutput', false)];
    end
end

function [x, y, z] = toyLoc(i, n)
    ang = 2*pi*(i-1)/n;
    r = 0.8;
    x = r * cos(ang);
    y = r * sin(ang);
    z = 0.3 * sin(pi * (i-1) / max(n-1,1));
end