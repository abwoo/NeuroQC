classdef TemporalFidelity
    % TemporalFidelity - Latency / amplitude / waveform shape vs reference ERP
    methods (Static)
        function t = evaluate(candidateERP, referenceERP, contract)
            % candidateERP/referenceERP: struct with .times (s), .erp (chan x time x cond optional)
            % or .waveforms (chan x time) ROI-meaned already in .roiWave (1 x time)
            % contract used for component windows.
            t = struct('status','NOT_RUN','component',struct(), ...
                'maxLatencyShiftMs',NaN,'maxAmplitudeError',NaN,'minCorrelation',NaN);
            if isempty(candidateERP) || isempty(referenceERP)
                return;
            end
            if ~isfield(candidateERP,'roiWave') || ~isfield(referenceERP,'roiWave')
                return;
            end
            if ~isfield(candidateERP,'times') || ~isfield(referenceERP,'times')
                return;
            end
            ct = candidateERP.times;
            rt = referenceERP.times;
            cw = candidateERP.roiWave;
            rw = referenceERP.roiWave;
            if numel(ct) ~= numel(cw) || numel(rt) ~= numel(rw)
                return;
            end
            t.status = 'RUN';
            t.component = struct();
            lat = [];
            amp = [];
            cor = [];
            comps = contract.components;
            for k = 1:numel(comps)
                w = comps(k).window;
                cs = ct >= w(1) & ct <= w(2);
                rs = rt >= w(1) & rt <= w(2);
                if nnz(cs) < 3 || nnz(rs) < 3
                    t.component.(matlab.lang.makeValidName(comps(k).name)) = ...
                        struct('status','WINDOW_UNAVAILABLE');
                    continue;
                end
                cseg = double(cw(cs));
                rseg = double(rw(rs));
                ctseg = ct(cs);
                rtseg = rt(rs);
                % baseline remove if prestimulus present
                if any(ctseg < 0), cseg = cseg - mean(cseg(ctseg < 0)); end
                if any(rtseg < 0), rseg = rseg - mean(rseg(rtseg < 0)); end
                [~, ic] = max(abs(cseg));
                [~, ir] = max(abs(rseg));
                latMs = abs(ctseg(ic) - rtseg(ir)) * 1000;
                cAmp = cseg(ic);
                rAmp = rseg(ir);
                ampErr = abs(cAmp - rAmp) / max(abs(rAmp), eps);
                if numel(cseg) >= 3 && std(cseg) > 0 && std(rseg) > 0
                    C = corrcoef(cseg(:), rseg(:));
                    cr = C(1,2);
                else
                    cr = NaN;
                end
                name = matlab.lang.makeValidName(comps(k).name);
                t.component.(name) = struct( ...
                    'latencyShiftMs', latMs, ...
                    'amplitudeError', ampErr, ...
                    'correlation', cr, ...
                    'status', 'OK');
                lat(end+1) = latMs; %#ok<AGROW>
                amp(end+1) = ampErr; %#ok<AGROW>
                cor(end+1) = cr; %#ok<AGROW>
            end
            if ~isempty(lat), t.maxLatencyShiftMs = max(lat); end
            if ~isempty(amp), t.maxAmplitudeError = max(amp); end
            if ~isempty(cor), t.minCorrelation = min(cor); end
            if ~isempty(lat)
                t.status = 'RUN';
            else
                t.status = 'NO_COMPONENTS_EVALUATED';
            end
        end
    end
end
