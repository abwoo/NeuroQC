classdef RankFidelity
    % RankFidelity - Effective rank retention relative to reference data
    methods (Static)
        function r = evaluate(candidateData, referenceData)
            r = struct('status','NOT_RUN','rank',NaN,'referenceRank',NaN,'rankDelta',NaN);
            if isempty(candidateData) || isempty(referenceData)
                return;
            end
            try
                r.rank = neuroqc.utils.estimateRank(candidateData);
                r.referenceRank = neuroqc.utils.estimateRank(referenceData);
                r.rankDelta = r.rank - r.referenceRank;
                r.status = 'RUN';
            catch
                r.status = 'FAIL';
            end
        end
    end
end
