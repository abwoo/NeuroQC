classdef FilterProbe
    %FILTERPROBE How much a candidate's filters distort the components.
    %
    %   r = neuroqc.eval.FilterProbe.run(path, srate, contract)
    %
    %   Noise metrics alone always prefer stronger filtering. To stop that,
    %   a noise-free synthetic waveform is passed through exactly the same
    %   EEGLAB filter calls (high-pass, low-pass, notch, resample, and native
    %   filter commands) as the candidate, and compared with the original
    %   (the approach of Zhang, Garrett & Luck, 2024, "Optimal filters for
    %   ERP research"). The waveform has one positive Gaussian per contract
    %   component, centred in its window, sigma = window length / 4.
    %
    %   r.amplitudeError   max over components of |mean amp change| / |true mean|
    %   r.latencyShiftMs   max over components of the peak-latency shift
    %   r.artifactPct      largest opposite-polarity (artifactual) deflection
    %                      in the epoch, relative to the true peak
    %   r.chain            the filter calls applied ('' = none)

    methods (Static)
        function r = run(path, srate, contract)
            r = struct('amplitudeError', 0, 'latencyShiftMs', 0, 'artifactPct', 0, 'chain', '');
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
            if isempty(steps), return; end
            r.chain = strjoin(cellfun(@(s) s.key, steps, 'UniformOutput', false), ' > ');

            pad = 60; % s of zeros on each side: longer than half of any FIR used here
            span = contract.epoch;
            n = round((2 * pad + diff(span)) * srate);
            t0 = pad - span(1); % time of the "event" from the start of the probe
            EEG = probeSet(zeros(1, n), srate);
            tt = (0:n-1) / srate - t0;
            EEG.data = template(tt, contract);
            for k = 1:numel(steps)
                [~, EEG] = evalc('neuroqc.run.Steps.run(steps{k}, EEG, struct(''highpass'', 0))');
            end
            fs = EEG.srate;
            tf = (0:EEG.pnts-1) / fs - t0;
            sel = tf >= span(1) - 1e-9 & tf <= span(2) + 1e-9;
            te = tf(sel);
            y = double(EEG.data(1, sel));
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
            % template is positive: any negativity beyond the template's own
            % (baseline-corrected) minimum is artifactual
            r.artifactPct = max(0, max(-y) - max(0, max(-x))) / peak;
        end
    end
end

function x = template(t, contract)
x = zeros(size(t));
for j = 1:numel(contract.components)
    w = contract.components(j).window;
    mu = mean(w); sigma = diff(w) / 4;
    x = x + exp(-0.5 * ((t - mu) / sigma) .^ 2);
end
end

function EEG = probeSet(data, srate)
EEG = eeg_emptyset();
EEG.data = data; EEG.nbchan = 1; EEG.pnts = size(data, 2); EEG.trials = 1;
EEG.srate = srate; EEG.xmin = 0; EEG.xmax = (EEG.pnts - 1) / srate;
EEG.chanlocs = struct('labels', 'probe');
EEG.setname = 'NeuroQC filter probe';
EEG = eeg_checkset(EEG);
end
