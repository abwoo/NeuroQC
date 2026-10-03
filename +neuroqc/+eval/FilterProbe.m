classdef FilterProbe
    %FILTERPROBE How much a candidate's filters distort the measured signal.
    %
    %   r = neuroqc.eval.FilterProbe.run(path, srate, contract)
    %
    %   Noise metrics alone always prefer stronger filtering. A noise-free
    %   synthetic signal is therefore passed through exactly the same EEGLAB
    %   filter calls as the candidate (high-pass, low-pass, notch,
    %   resample, native filter commands) and compared with the original
    %   (approach of Zhang, Garrett & Luck, 2024, "Optimal filters for ERP
    %   research").
    %
    %   ERP: one positive Gaussian per contract component, centred in its
    %   window, sigma = window length / 4.
    %     amplitudeError  max over components |mean amp change| / |true mean|
    %     latencyShiftMs  max over components of the peak-latency shift
    %     artifactPct     opposite-polarity deflection beyond the template's
    %                     own, relative to its peak
    %     waveformCorr    correlation of filtered and true epoch waveform
    %   Spectral: a sinusoid at each band's centre frequency.
    %     amplitudeError  max over bands |1 - output/input amplitude|
    %
    %   Only linear filtering is probed here. Data-dependent steps (ICA
    %   removal, ASR, rejection, interpolation) need neuroqc.eval.Injection.

    methods (Static)
        function r = run(path, srate, contract)
            r = struct('source', 'filter probe', 'amplitudeError', 0, 'latencyShiftMs', 0, ...
                'artifactPct', 0, 'waveformCorr', 1, 'topoCorr', NaN, 'chain', '', ...
                'notApplicable', {{'topoCorr'}});   % one probe channel: no topography
            steps = neuroqc.eval.FilterProbe.filterSteps(path);
            if isempty(steps), return; end
            r.chain = strjoin(cellfun(@(s) s.key, steps, 'UniformOutput', false), ' > ');
            if strcmp(contract.analysis, 'spectral')
                errs = zeros(1, numel(contract.bands));
                for b = 1:numel(contract.bands)
                    f0 = mean(contract.bands(b).freq);
                    n = round(120 * srate);  % 120 s, analyse the central 60 s
                    t = (0:n-1) / srate;
                    [y, fs] = applyChain(steps, sin(2 * pi * f0 * t), srate);
                    ty = (0:numel(y)-1) / fs;
                    mid = ty >= 30 & ty <= 90;
                    X = [sin(2 * pi * f0 * ty(mid))' cos(2 * pi * f0 * ty(mid))'];
                    beta = X \ y(mid)';
                    errs(b) = abs(1 - norm(beta));
                end
                r.amplitudeError = max(errs); r.waveformCorr = NaN; r.notApplicable = {'topoCorr', 'waveformCorr'};
                return;
            end
            pad = 60; % s of zeros on each side: longer than half of any FIR used here
            span = contract.epoch;
            n = round((2 * pad + diff(span)) * srate);
            t0 = pad - span(1);
            tt = (0:n-1) / srate - t0;
            [y, fs] = applyChain(steps, template(tt, contract), srate);
            tf = (0:numel(y)-1) / fs - t0;
            sel = tf >= span(1) - 1e-9 & tf <= span(2) + 1e-9;
            te = tf(sel); y = y(sel);
            x = template(te, contract);
            bl = te >= contract.baseline(1) - 1e-9 & te <= contract.baseline(2) + 1e-9;
            y = y - mean(y(bl)); x = x - mean(x(bl));
            peak = max(abs(x));
            amp = zeros(1, numel(contract.components)); lat = amp;
            for j = 1:numel(contract.components)
                w = contract.components(j).window;
                in = te >= w(1) - 1e-9 & te <= w(2) + 1e-9;
                mt = mean(x(in)); mf = mean(y(in));
                amp(j) = abs(mf - mt) / max(abs(mt), eps);
                [~, ix] = max(x(in)); [~, iy] = max(y(in));
                tw = te(in);
                lat(j) = 1000 * abs(tw(iy) - tw(ix));
            end
            r.amplitudeError = max(amp);
            r.latencyShiftMs = max(lat);
            r.artifactPct = max(0, max(-y) - max(0, max(-x))) / peak;
            c = corrcoef(x, y); r.waveformCorr = c(1, 2);
        end

        function steps = filterSteps(path)
            steps = {};
            for k = 1:numel(path)
                in = path{k};
                if any(strcmp(in.type, {'highpass','lowpass','linenoise','resample'}))
                    steps{end+1} = in; %#ok<AGROW>
                elseif strcmp(in.type, 'native')
                    e = neuroqc.live.History.classify(in.params.command);
                    if any(strcmp(e.step, {'highpass','lowpass','bandpass','linenoise','resample','filter_other'}))
                        steps{end+1} = in; %#ok<AGROW>
                    end
                end
            end
        end
    end
end

function [y, fs] = applyChain(steps, x, srate)
EEG = eeg_emptyset();
EEG.data = x; EEG.nbchan = 1; EEG.pnts = numel(x); EEG.trials = 1;
EEG.srate = srate; EEG.xmin = 0; EEG.xmax = (EEG.pnts - 1) / srate;
EEG.chanlocs = struct('labels', 'probe'); EEG.setname = 'NeuroQC probe';
EEG = eeg_checkset(EEG);
for k = 1:numel(steps)
    [~, EEG] = evalc('neuroqc.run.Steps.run(steps{k}, EEG, struct(''highpass'', 0))');
end
y = double(EEG.data(1, :)); fs = EEG.srate;
end

function x = template(t, contract)
x = zeros(size(t));
for j = 1:numel(contract.components)
    w = contract.components(j).window;
    mu = mean(w); sigma = diff(w) / 4;
    x = x + exp(-0.5 * ((t - mu) / sigma) .^ 2);
end
end
