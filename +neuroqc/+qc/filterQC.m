function r = filterQC(EEGbefore, EEGafter, parameters, contract) %#ok<INUSD>
%filterQC QC for filter steps
% Checks: PSD change, line-noise reduction, baseline drift, edge energy,
% normalized waveform distortion (band-matched).

    r = struct('status', 'PASS', 'metrics', struct(), 'warnings', {{}}, 'recommendations', {{}});
    if isempty(EEGafter)
        r.status = 'NOT_RUN';
        return;
    end
    
    m = struct();
    hp = [];
    lp = [];
    if isfield(parameters, 'highpass'), hp = parameters.highpass; end
    if isfield(parameters, 'lowpass'), lp = parameters.lowpass; end
    m.highpass = hp;
    m.lowpass = lp;
    
    % Discrete-time coefficients if provided
    if isfield(parameters, 'b') && isfield(parameters, 'a')
        m.filterOrder = numel(parameters.b) - 1;
        if isfield(parameters, 'is FIR'), m.isFIR = parameters.isFIR; end
    end
    
    fs = EEGafter.srate;
    nchan = min(8, size(EEGafter.data,1));
    idx = round(linspace(1, size(EEGafter.data,1), nchan));
    
    % PSD metrics
    [psdB, fB] = neuroqc.qc.helpers.psdMedian(EEGbefore, idx);
    [psdA, fA] = neuroqc.qc.helpers.psdMedian(EEGafter, idx);
    
    % Line noise power reduction at 50/60
    for f0 = [50 60]
        if f0 < fs/2
            band = fB >= f0-2 & fB <= f0+2;
            m.(sprintf('line%g_before', f0)) = mean(psdB(band));
            m.(sprintf('line%g_after', f0)) = mean(psdA(fA >= f0-2 & fA <= f0+2));
        end
    end
    
    % Baseline drift: power below 0.5 Hz (or below hp if set)
    driftF = 0.5;
    if ~isempty(hp), driftF = max(0.1, hp); end
    bB = mean(psdB(fB < driftF & fB > 0));
    bA = mean(psdA(fA < driftF & fA > 0));
    m.driftPowerBefore = bB;
    m.driftPowerAfter = bA;
    if bB > 0
        m.driftReductionPct = (1 - bB / max(bA, eps)) * 0 + (1 - bA / bB) * 100;
    else
        m.driftReductionPct = NaN;
    end
    
    % In-band power preservation (for LP: 1..lp; for HP: hp..min(20,nyq))
    if ~isempty(lp)
        inb = fB >= 1 & fB <= lp;
    elseif ~isempty(hp)
        inb = fB >= hp & fB <= min(40, fs/2 - 1);
    else
        inb = fB >= 1 & fB <= min(40, fs/2 - 1);
    end
    if any(inb)
        firstIdx = find(inb, 1, 'first');
        lastIdx = find(inb, 1, 'last');
        lo = fB(firstIdx);
        hi = fB(lastIdx);
        inbA = fA >= lo & fA <= hi;
        if ~any(inbA)
            upper = fs/2 - 1;
            if ~isempty(lp)
                upper = min(lp, fs/2 - 1);
            elseif ~isempty(hp)
                upper = min(40, fs/2 - 1);
            end
            inbA = fA >= 1 & fA <= upper;
        end
        ratio = mean(psdA(inbA)) / max(mean(psdB(inb)), eps);
        m.inbandPowerRatio = ratio;
    else
        m.inbandPowerRatio = NaN;
    end
    
    % Waveform distortion on common band-limited signals
    % Compare after applying the SAME band definition to both (fair metric)
    try
        Xb = double(EEGbefore.data);
        Xa = double(EEGafter.data);
        if size(Xa,2) ~= size(Xb,2)
            n = min(size(Xb,2), size(Xa,2));
            Xb = Xb(:,1:n);
            Xa = Xa(:,1:n);
            commonFs = min(EEGbefore.srate, EEGafter.srate);
        else
            commonFs = EEGbefore.srate;
        end
        if ~isempty(hp) && ~isempty(lp)
            [b, a] = butter(4, [hp, min(lp, commonFs/2-1)] / (commonFs/2), 'bandpass');
        elseif ~isempty(hp)
            [b, a] = butter(4, hp / (commonFs/2), 'high');
        elseif ~isempty(lp)
            [b, a] = butter(4, min(lp, commonFs/2-1) / (commonFs/2), 'low');
        else
            b = []; a = [];
        end
        if ~isempty(b)
            Xb_f = filtfilt(b, a, Xb')';  % zero-phase, match EEGLAB style
            Xa_f = Xa;
        else
            Xb_f = Xb;
            Xa_f = Xa;
        end
        % Correlation-based distortion (robust to residual gain/phase)
        n = min(size(Xb_f, 2), size(Xa_f, 2));
        xb = Xb_f(:, 1:n);
        xa = Xa_f(:, 1:n);
        % Subsample channels x time for speed
        chStep = max(1, floor(size(xb,1)/16));
        tStep = max(1, floor(n/5000));
        xs = xb(1:chStep:end, 1:tStep:end);
        ys = xa(1:chStep:end, 1:tStep:end);
        if std(xs(:)) > 0 && std(ys(:)) > 0
            cc = corrcoef(xs(:), ys(:));
            m.waveformCorrelation = cc(1,2);
            % Polarity-sensitive companion metric (gain-invariant): a full
            % inversion (cc=-1) is real distortion, not zero. Range [0,2],
            % own gate 0.5 => cc >= 0.5. Lives under a DISTINCT key because
            % quality.waveformDistortion means relative L2 everywhere else
            % (CandidateSession / HardConstraints / Pareto / CSV) and the
            % two definitions are complementary, not interchangeable.
            m.polarityDistortion = 1 - cc(1,2);
        else
            m.waveformCorrelation = NaN;
            m.polarityDistortion = NaN;
        end
        % Canonical waveformDistortion: relative L2 on the same band-matched
        % samples - identical definition and scale to quality.waveformDistortion
        % so this key never changes meaning across paths.
        m.waveformDistortion = norm(ys - xs, 'fro') / max(norm(xs, 'fro'), eps);
        
        % Edge artifact: energy fraction in first/last 1 second of output
        edge = max(1, round(fs));
        edgeRatio = norm(Xa(:, 1:min(edge, end)), 'fro') / max(norm(Xa, 'fro'), eps);
        m.edgeEnergyFraction = edgeRatio;
    catch
        m.waveformDistortion = NaN;
        m.polarityDistortion = NaN;
        m.edgeEnergyFraction = NaN;
    end
    
    % Lowpass not applied but expected
    if ~isempty(lp) && lp > fs/2
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('Requested LP %g Hz above Nyquist %g', lp, fs/2);
    end
    
    r.metrics = m;
    
    % REVIEW gate: polarity definition when defined (round-1 semantics:
    % cc < 0.5 -> REVIEW), relative-L2 fallback when polarity is undefined
    % (flat/degenerate signal), same 0.5 level. Names the definition used
    % so a warning can never be mistaken for the other metric.
    if isfinite(m.polarityDistortion) && m.polarityDistortion > 0.5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('High waveform distortion (polarity D=%.2f)', m.polarityDistortion);
        r.recommendations{end+1} = 'Inspect filter transition band / order';
    elseif ~isfinite(m.polarityDistortion) && isfinite(m.waveformDistortion) && ...
            m.waveformDistortion > 0.5
        r.status = 'REVIEW';
        r.warnings{end+1} = sprintf('High waveform distortion (L2 D=%.2f)', m.waveformDistortion);
        r.recommendations{end+1} = 'Inspect filter transition band / order';
    end
    if isfinite(m.inbandPowerRatio) && (m.inbandPowerRatio < 0.7 || m.inbandPowerRatio > 1.3)
        if strcmp(r.status, 'PASS'), r.status = 'PASS_WITH_WARNING'; end
        r.warnings{end+1} = sprintf('In-band power ratio = %.2f', m.inbandPowerRatio);
    end
end