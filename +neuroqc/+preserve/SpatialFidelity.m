classdef SpatialFidelity
    % SpatialFidelity - Topographic similarity of ROI/ERP maps vs reference
    methods (Static)
        function s = evaluate(candidateMap, referenceMap, labels)
            % candidateMap/referenceMap: nChan x 1 (or nChan x nCond); labels: cellstr
            s = struct('status','NOT_RUN','topoFidelity',NaN,'perCondition',[]);
            if isempty(candidateMap) || isempty(referenceMap)
                return;
            end
            if ~isequal(size(candidateMap), size(referenceMap))
                return;
            end
            if nargin < 3, labels = {}; end
            s.status = 'RUN';
            if isvector(candidateMap) && isvector(referenceMap)
                r = localCorr(candidateMap(:), referenceMap(:));
                s.topoFidelity = r;
                s.perCondition = r;
            else
                nCond = size(candidateMap, 2);
                rs = nan(1, nCond);
                for c = 1:nCond
                    rs(c) = localCorr(candidateMap(:,c), referenceMap(:,c));
                end
                s.perCondition = rs;
                s.topoFidelity = min(rs);
            end
            if ~isempty(labels)
                s.labels = labels;
            end
        end

        function m = roiMean(erp, times, chanlocs, roi, window)
            % Mean waveform over ROI channels within window -> map over channels full window
            % Returns nChan x nTime matrix restricted logic helper
            if nargin < 5 || isempty(window)
                sel = true(size(times));
            else
                sel = times >= window(1) & times <= window(2);
            end
            labels = arrayfun(@(x) string(x.labels), chanlocs, 'UniformOutput', false);
            labels = upper(string(labels(:)));
            roiU = upper(string(roi(:)));
            idx = find(ismember(labels, roiU));
            if isempty(idx)
                m = [];
                return;
            end
            m = erp(idx, :);
            if any(~sel)
                % keep full map; window applied by caller when averaging
            end
        end
    end
end

function r = localCorr(a, b)
    a = a(:); b = b(:);
    if numel(a) ~= numel(b) || numel(a) < 3 || all(a==a(1)) || all(b==b(1))
        r = NaN;
        return;
    end
    C = corrcoef(a, b);
    r = C(1,2);
end
