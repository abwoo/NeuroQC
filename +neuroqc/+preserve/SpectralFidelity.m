classdef SpectralFidelity
    % SpectralFidelity - Band energy relative error vs reference (display-oriented)
    methods (Static)
        function s = evaluate(candidateERP, referenceERP, band)
            % band: [lo hi] Hz; ERP timeseries treated as slow; uses pwelch if available
            s = struct('status','NOT_RUN','band',band,'bandEnergyError',NaN);
            if nargin < 3 || isempty(band)
                band = [1 10];
            end
            if isempty(candidateERP) || isempty(referenceERP) || ...
                    ~isfield(candidateERP,'roiWave') || ~isfield(referenceERP,'roiWave')
                return;
            end
            fsC = localFs(candidateERP);
            fsR = localFs(referenceERP);
            if isempty(fsC) || isempty(fsR)
                return;
            end
            eC = localBandEnergy(candidateERP.roiWave, fsC, band);
            eR = localBandEnergy(referenceERP.roiWave, fsR, band);
            if ~isfinite(eC) || ~isfinite(eR) || eR <= 0
                return;
            end
            s.status = 'RUN';
            s.bandEnergyError = abs(eC - eR) / eR;
        end
    end
end

function fs = localFs(w)
    fs = [];
    if isempty(w), return; end
    % Prefer explicit srate; otherwise derive from times (ms) as 1000/dt.
    if isstruct(w)
        if isfield(w, 'srate') && isnumeric(w.srate) && isscalar(w.srate) && ...
                isfinite(w.srate) && w.srate > 0
            fs = double(w.srate);
            return;
        end
        if isfield(w, 'times') && isnumeric(w.times) && numel(w.times) > 1
            t = double(w.times(:));
            dt = mean(diff(t)) / 1000; % ms -> s
            if isfinite(dt) && dt > 0
                fs = 1 / dt;
                return;
            end
        end
    end
    % Last-resort fallback when neither srate nor times is usable.
    fs = 250;
end

function e = localBandEnergy(x, fs, band)
    x = double(x(:));
    n = numel(x);
    if n < 8, e = NaN; return; end
    nfft = 2^nextpow2(min(n, 512));
    try
        [p, f] = pwelch(x, hamming(min(n,256)), [], nfft, fs);
    catch
        p = abs(fft(x, nfft)).^2;
        f = (0:nfft-1)*fs/nfft;
    end
    sel = f >= band(1) & f <= band(2);
    e = sum(p(sel));
end
