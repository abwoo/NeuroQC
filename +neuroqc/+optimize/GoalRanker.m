classdef GoalRanker
    % GoalRanker - Layer-3 scalarization over a feasible Pareto subset.
    % Never introduces experimental significance; outputs REVIEW candidates.

    methods (Static)
        function rec = rank(results, frontIdx, profile)
            % results: array with .id and .quality (external QC or legacy)
            % frontIdx: feasible Pareto indices (Layer 2)
            % profile: GoalProfile | name | struct | []
            % rec fields: bestOverall, byObjective, scores, profile, status, degenerate
            if nargin < 3, profile = []; end
            profile = neuroqc.optimize.GoalProfile.resolve(profile);
            objs = profile.enabledObjectives();

            rec = struct();
            rec.status = 'REVIEW';
            rec.profileName = profile.name;
            rec.frontIdx = frontIdx(:)';
            rec.byObjective = struct();
            rec.degenerate = struct();
            rec.usable = struct();
            rec.scores = [];
            rec.objectiveNames = {objs.name};
            rec.bestOverall = [];

            if isempty(frontIdx)
                return;
            end
            n = numel(frontIdx);
            m = numel(objs);

            % Build cost matrix (lower better); NaN stays NaN (column-local)
            C = nan(n, m);
            for j = 1:m
                for i = 1:n
                    C(i, j) = objs(j).cost(results(frontIdx(i)).quality);
                end
            end

            % min-max normalize per column among finite values (cost space).
            % All-NaN columns are excluded from weighting entirely so one
            % missing metric cannot poison every row's distance.
            Z = nan(n, m);
            usable = false(1, m);
            degenerate = false(1, m);
            for j = 1:m
                col = C(:, j);
                finite = isfinite(col);
                if ~any(finite)
                    degenerate(j) = true;
                    rec.degenerate.(objs(j).name) = true;
                    continue; % unusable column — excluded from active set
                end
                usable(j) = true;
                lo = min(col(finite));
                hi = max(col(finite));
                if strcmp(objs(j).normalize, 'none')
                    z = col - lo;
                    span = hi - lo;
                    if span < 1e-12
                        % Degenerate column: finite rows tie at 0; missing rows
                        % get the same worst penalty (z=1) as the minmax path
                        % so both normalizations treat absence identically.
                        z(:) = 0;
                        z(~finite) = 1;
                        degenerate(j) = true;
                    else
                        z(~finite) = span; % missing: worst finite distance (finite)
                    end
                else
                    if hi - lo < 1e-12
                        z = zeros(n, 1);
                        z(~finite) = 1;
                        degenerate(j) = true;
                    else
                        z = (col - lo) ./ (hi - lo);
                        z(~finite) = 1; % missing metrics: worst in cost space (finite)
                    end
                end
                Z(:, j) = z;
                rec.degenerate.(objs(j).name) = degenerate(j);
                rec.usable.(objs(j).name) = true;
            end
            for j = 1:m
                if ~usable(j)
                    rec.usable.(objs(j).name) = false;
                end
            end

            w = [objs.weight];
            w(~usable) = 0;
            active = w > 0;
            if ~any(active)
                rec.status = 'MISSING_OBJECTIVES';
                return;
            end
            w = w ./ max(sum(w), eps);
            % weighted ideal-point distance over usable, positive-weight columns
            dist = sqrt(sum((Z(:, active) .^ 2) .* w(active), 2));

            rec.scores = dist;

            [~, iBest] = min(dist);
            if ~isfinite(dist(iBest)), rec.status='MISSING_OBJECTIVES'; return; end
            rec.bestOverall = frontIdx(iBest);
            rec.bestOverallScore = dist(iBest);

            % Per-objective best: extremum in cost among finite, tie-break by distance
            % Precompute unique field names so 'a b' and 'a-b' cannot collide
            % into the same byObjective field (makeValidName alone does that).
            labels = matlab.lang.makeUniqueStrings(matlab.lang.makeValidName({objs.name}));
            for j = 1:m
                label = labels{j};
                if degenerate(j)
                    rec.byObjective.(label) = struct( ...
                        'index', rec.bestOverall, ...
                        'score', dist(iBest), ...
                        'degenerate', true);
                    continue;
                end
                col = C(:, j);
                finite = isfinite(col);
                if ~any(finite)
                    rec.byObjective.(label) = struct( ...
                        'index', rec.bestOverall, 'score', dist(iBest), 'degenerate', true);
                    continue;
                end
                cand = find(finite);
                bestVal = min(col(cand)); % cost: lower better
                tied = cand(abs(col(cand) - bestVal) < 1e-12);
                [~, ti] = min(dist(tied));
                pick = tied(ti);
                rec.byObjective.(label) = struct( ...
                    'index', frontIdx(pick), ...
                    'score', dist(pick), ...
                    'metricKey', objs(j).metricKey, ...
                    'rawCost', col(pick), ...
                    'degenerate', false);
            end

            rec.profile = profile.toStruct();
        end

        function idx = recommend(results, front, profile)
            % Convenience: return only bestOverall index ([] if empty front)
            rec = neuroqc.optimize.GoalRanker.rank(results, front, profile);
            idx = rec.bestOverall;
        end

        function print(rec)
            if isempty(rec.bestOverall)
                fprintf('GoalRanker: no feasible candidates\n');
                return;
            end
            fprintf('GoalRanker [%s] bestOverall=%s score=%.4f status=%s\n', ...
                rec.profileName, rec.bestOverall, rec.bestOverallScore, rec.status);
            fn = fieldnames(rec.byObjective);
            for k = 1:numel(fn)
                b = rec.byObjective.(fn{k});
                flag = '';
                if isfield(b,'degenerate') && b.degenerate, flag = ' (degenerate)'; end
                fprintf('  %-22s -> %s score=%.4f%s\n', fn{k}, b.index, b.score, flag);
            end
        end
    end
end
