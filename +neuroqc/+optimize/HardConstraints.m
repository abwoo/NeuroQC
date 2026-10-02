classdef HardConstraints
    % HardConstraints - binary pass/fail gates before Pareto ranking
    % FAIL pipelines never compete on "looks most significant"
    
    methods (Static)
        function [ok, reasons, inert] = evaluate(q, limits)
            if nargin < 2, limits = struct(); end
            % maxDistortion gates quality.waveformDistortion = relative L2
            % between condition-average waveforms (CandidateSession.measure);
            % 0.5 means a 50% norm change. It is NOT filterQC's
            % polarityDistortion (1-cc) - that metric has its own gate.
            defaults = struct( ...
                'maxInterpRatio', 0.30, ...
                'maxBadRatio', 0.30, ...
                'minRetention', 0.30, ...
                'allowEventLoss', false, ...
                'minRank', 4, ...
                'maxDistortion', 0.5, ...
                'maxConditionRetentionSpread', 0.25, ...
                'maxProbeAmplitudeError',0.35,'maxProbeLatencyShiftMs',20,'minProbeCorrelation',0.9);
            fn = fieldnames(defaults);
            for i = 1:numel(fn)
                if ~isfield(limits, fn{i}), limits.(fn{i}) = defaults.(fn{i}); end
            end
            % Scope knobs whose gate cannot run on this row. Reported, never
            % rejected: a configured threshold must not be silently inert.
            inert = neuroqc.optimize.HardConstraints.inertKnobs(q, limits);

            reasons = {};
            ok = true;
            
            % rank / topoStability are optional (not exported by comparison.csv;
            % rank has no portable definition across QC sources).
            required = {'retention','waveformDistortion','interpRatio','badRatio', ...
                'reliability'};
            for i = 1:numel(required)
                name = required{i};
                if ~isfield(q,name) || ~isscalar(q.(name)) || ~isfinite(q.(name))
                    ok = false; reasons{end+1} = ['missing_metric_' name];
                end
            end
            if isfield(q,'preservationGate') && ~isempty(q.preservationGate)
                % Accept char/string gates too: q.preservationGate(:)' on a
                % char would splice a char row into the reasons cell.
                pg = q.preservationGate;
                if ischar(pg) || isstring(pg), pg = cellstr(pg); end
                pg = pg(~cellfun(@isempty, pg));
                if ~isempty(pg)
                    ok=false; reasons=[reasons {'preservation_gate_failed'} pg(:)'];
                end
            end
            if ~ok, return; end
            if isfield(q,'minConditionRetention') && isfinite(q.minConditionRetention) && q.minConditionRetention < limits.minRetention
                ok=false; reasons{end+1}='low_condition_retention';
            end
            if isfield(q,'conditionRetentionSpread') && isfinite(q.conditionRetentionSpread) && q.conditionRetentionSpread > limits.maxConditionRetentionSpread
                ok=false; reasons{end+1}='condition_retention_imbalance';
            end
            if isfield(q,'filterGuard')
                g=q.filterGuard;
                if ~all(isfinite([g.maxAmplitudeError,g.maxLatencyShiftMs,g.minCorrelation])) || ...
                    g.maxAmplitudeError>limits.maxProbeAmplitudeError || ...
                    g.maxLatencyShiftMs>limits.maxProbeLatencyShiftMs || g.minCorrelation<limits.minProbeCorrelation
                    ok=false; reasons{end+1}='temporal_filter_probe_distortion';
                end
            end
            if isfield(q, 'status') && strcmpi(q.status, 'FAIL')
                ok = false;
                reasons{end+1} = 'pipeline_status_FAIL';
            end
            if isfield(q, 'interpRatio') && q.interpRatio > limits.maxInterpRatio
                ok = false;
                reasons{end+1} = sprintf('interp_ratio=%.2f', q.interpRatio);
            end
            if isfield(q, 'badRatio') && q.badRatio > limits.maxBadRatio
                ok = false;
                reasons{end+1} = sprintf('bad_ratio=%.2f', q.badRatio);
            end
            if isfield(q, 'retention') && isfinite(q.retention) && q.retention < limits.minRetention
                ok = false;
                reasons{end+1} = sprintf('retention=%.2f', q.retention);
            end
            if limits.allowEventLoss == false && isfield(q, 'eventLoss') && q.eventLoss
                ok = false;
                reasons{end+1} = 'event_loss';
            end
            if isfield(q, 'rank') && isfinite(q.rank) && q.rank < limits.minRank
                ok = false;
                reasons{end+1} = sprintf('rank=%d', q.rank);
            end
            if isfield(q, 'waveformDistortion') && isfinite(q.waveformDistortion) && ...
                    q.waveformDistortion > limits.maxDistortion
                ok = false;
                reasons{end+1} = sprintf('distortion=%.2f', q.waveformDistortion);
            end
        end

        function names = inertKnobs(q, limits)
            % Scope Constraints knobs that cannot be evaluated for this row
            % (metric absent or non-finite). The required metrics behind
            % maxDistortion / maxInterpRatio / maxBadRatio / minRetention are
            % not listed: a missing one already rejects with missing_metric_*.
            if nargin < 2, limits = struct(); end
            if ~isfield(limits, 'allowEventLoss'), limits.allowEventLoss = false; end
            names = {};
            if ~neuroqc.optimize.HardConstraints.isUsable(q, 'rank')
                names{end+1} = 'minRank';
            end
            if ~neuroqc.optimize.HardConstraints.isUsable(q, 'conditionRetentionSpread')
                names{end+1} = 'maxConditionRetentionSpread';
            end
            % An armed allowEventLoss gate rejects any row that loses events;
            % with allowEventLoss=1 nothing can be lost, so silence is correct.
            armed = isfield(limits, 'allowEventLoss') && ...
                (islogical(limits.allowEventLoss) || isnumeric(limits.allowEventLoss)) && ...
                ~limits.allowEventLoss;
            if armed && ~neuroqc.optimize.HardConstraints.isUsable(q, 'eventLoss')
                names{end+1} = 'allowEventLoss';
            end
        end

        function tf = isUsable(q, name)
            tf = false;
            if ~isstruct(q) || ~isfield(q, name), return; end
            v = q.(name);
            if islogical(v) && isscalar(v), tf = true; return; end
            if isnumeric(v) && isscalar(v), tf = isfinite(v); end
        end
    end
end