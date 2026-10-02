classdef ConditionBalance
    % ConditionBalance - Unified condition retention balance metrics (display)
    methods (Static)
        function c = evaluate(quality)
            c = struct('status','NOT_RUN','minConditionRetention',NaN, ...
                'conditionRetentionSpread',NaN);
            if isstruct(quality)
                if isfield(quality,'minConditionRetention')
                    c.minConditionRetention = quality.minConditionRetention;
                end
                if isfield(quality,'conditionRetentionSpread')
                    c.conditionRetentionSpread = quality.conditionRetentionSpread;
                end
                if isfinite(c.minConditionRetention) || isfinite(c.conditionRetentionSpread)
                    c.status = 'RUN';
                end
            end
        end
    end
end
