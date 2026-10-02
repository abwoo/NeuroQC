classdef Sensitivity
    % Sensitivity - Parameter sensitivity tables (not single "best" value)
    
    methods (Static)
        function tableOut = analyze(results, paramName, paramGetter)
            % results: array with .pipeline and .quality
            % paramName: label string
            % paramGetter: function_handle(pipeline) -> param value
            vals = {};
            rows = struct('value', {}, 'snr', {}, 'reliability', {}, ...
                'baselineSd', {}, 'retention', {}, 'distortion', {}, 'n', {});
            
            for i = 1:numel(results)
                v = paramGetter(results(i).pipeline);
                vs = char(string(v));
                found = false;
                for k = 1:numel(vals)
                    if strcmp(char(vals{k}), vs)
                        found = true;
                        idx = k;
                        break;
                    end
                end
                if ~found
                    vals{end+1} = v; %#ok<AGROW>
                    idx = numel(vals);
                    rows(idx) = struct('value', v, 'snr', [], 'reliability', [], ...
                        'baselineSd', [], 'retention', [], 'distortion', [], 'n', 0);
                end
                q = results(i).quality;
                % External QC sources may omit optional metrics; store NaN
                % instead of erroring on a missing field.
                rows(idx).snr(end+1) = optNum(q, 'snr');
                rows(idx).reliability(end+1) = optNum(q, 'reliability');
                rows(idx).baselineSd(end+1) = optNum(q, 'baselineSd');
                rows(idx).retention(end+1) = optNum(q, 'retention');
                rows(idx).distortion(end+1) = optNum(q, 'waveformDistortion');
                rows(idx).n = rows(idx).n + 1;
            end
            
            tableOut = struct('parameter', paramName, 'levels', {vals}, 'stats', rows);
        end
        
        function printSensitivity(s)
            fprintf('\n=== Sensitivity: %s ===\n', s.parameter);
            fprintf('%-10s %6s %6s %8s %8s %8s\n', ...
                'Level', 'N', 'SNR', 'Rel', 'BaseSD', 'Dist');
            for i = 1:numel(s.levels)
                r = s.stats(i);
                fprintf('%-10s %6d %6s %8s %8s %8s\n', ...
                    char(string(s.levels{i})), r.n, ...
                    amean(r.snr), amean(r.reliability), ...
                    amean(r.baselineSd), amean(r.distortion));
            end
        end
    end
end

function s = amean(v)
    v = v(isfinite(v));
    if isempty(v), s = 'n/a'; else, s = sprintf('%.3f', mean(v)); end
end

function v = optNum(q, name)
    if isfield(q, name) && isnumeric(q.(name)) && isscalar(q.(name))
        v = double(q.(name));
    else
        v = NaN;
    end
end