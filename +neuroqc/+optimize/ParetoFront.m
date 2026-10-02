classdef ParetoFront
    % ParetoFront - Non-dominated multi-objective selection
    % Objectives (maximize): reliability, retention, topoStability
    % Objectives (minimize): distortion, interpRatio; SNR is descriptive only
    % NEVER includes experimental effect size / p-values
    % Optional preservation columns are NOT auto-added (enable via GoalProfile only
    % for Layer-3 scalarization; Layer-2 front stays 5-D by default).

    methods (Static)
        function [frontIdx, dominated, reasons, skipped] = select(results, limits, extraDims)
            % results: struct array with .quality (external QC / measure rows)
            % dominated: indices rejected by hard constraints (legacy name)
            % reasons: cellstr of constraint reasons per rejected index (aligned to dominated)
            % extraDims (optional): struct array/cell of {name,sense} quality
            %   dimensions required by the active GoalProfile. The front is
            %   computed over base-5 ∪ extras so Layer-3 can never rank a
            %   candidate outside the Layer-2 front (objective ⊄ front dims
            %   would silently hide the scalarization optimum).
            % skipped (optional): struct('name','applied','n') rows for every
            %   Scope knob that could not run on at least one row (metric
            %   absent). Informational: a configured gate is never silent.
            if nargin < 2, limits = struct(); end
            if nargin < 3, extraDims = {}; end
            if isempty(extraDims), extraDims = {}; end
            if isstruct(extraDims), extraDims = num2cell(extraDims); end

            n = numel(results);
            feasible = true(n, 1);
            reasonsAll = cell(n, 1);
            inertCount = struct();
            for i = 1:n
                [ok, rs, inert] = neuroqc.optimize.HardConstraints.evaluate(results(i).quality, limits);
                feasible(i) = ok;
                if ~ok, reasonsAll{i} = strjoin(rs, '; '); end
                for j = 1:numel(inert)
                    f = inert{j};
                    if isfield(inertCount, f)
                        inertCount.(f) = inertCount.(f) + 1;
                    else
                        inertCount.(f) = 1;
                    end
                end
            end

            skipped = struct('name', {}, 'applied', {}, 'n', {});
            names = fieldnames(inertCount);
            for k = 1:numel(names)
                if inertCount.(names{k}) == 0, continue; end
                skipped(end+1) = struct('name', names{k}, ...
                    'applied', n - inertCount.(names{k}), 'n', n); %#ok<AGROW>
            end

            idx = find(feasible);
            dominated = find(~feasible);
            reasons = reasonsAll(dominated);

            if isempty(idx)
                frontIdx = [];
                return;
            end

            % Default 5-D front, extended only by explicitly requested
            % objective dimensions. Preservation metrics never auto-expand M.
            dims = { ...
                struct('name', 'reliability', 'sense', 'max'), ...
                struct('name', 'retention', 'sense', 'max'), ...
                struct('name', 'topoStability', 'sense', 'max'), ...
                struct('name', 'waveformDistortion', 'sense', 'min'), ...
                struct('name', 'interpRatio', 'sense', 'min')};
            baseNames = cellfun(@(d) d.name, dims, 'UniformOutput', false);
            for k = 1:numel(extraDims)
                d = extraDims{k};
                if ~any(strcmpi(d.name, baseNames))
                    dims{end+1} = struct('name', d.name, 'sense', d.sense); %#ok<AGROW>
                    baseNames{end+1} = d.name; %#ok<AGROW>
                end
            end

            M = zeros(numel(idx), numel(dims));
            for k = 1:numel(idx)
                q = results(idx(k)).quality;
                for j = 1:numel(dims)
                    if strcmpi(dims{j}.sense, 'min')
                        M(k, j) = neuroqc.optimize.ParetoFront.getNeg(q, dims{j}.name);
                    else
                        M(k, j) = neuroqc.optimize.ParetoFront.get(q, dims{j}.name);
                    end
                end
            end

            keep = true(numel(idx), 1);
            for a = 1:numel(idx)
                if ~keep(a), continue; end
                for b = 1:numel(idx)
                    if a == b || ~keep(b), continue; end
                    if all(M(b, :) >= M(a, :)) && any(M(b, :) > M(a, :))
                        keep(a) = false;
                        break;
                    end
                end
            end

            frontIdx = idx(keep);
        end

        function v = nz(x)
            if ~isfinite(x), v = -1e6; else, v = x; end
        end

        function v = get(q, name)
            % Read a quality metric; missing/non-finite -> worst sentinel
            % (logical scalars such as eventLoss are accepted and doubled).
            if isstruct(q) && isfield(q, name) && ...
                    (isnumeric(q.(name)) || islogical(q.(name))) && isscalar(q.(name))
                v = neuroqc.optimize.ParetoFront.nz(double(q.(name)));
            else
                v = -1e6;
            end
        end

        function v = getNeg(q, name)
            % Read a minimize-column metric (pre-negation): finite -> -x so the
            % maximization matrix treats smaller values as better; missing/
            % non-finite -> +1e6 (worst after negation). Never route a missing
            % value through negation or it flips to the best sentinel.
            if isstruct(q) && isfield(q, name) && ...
                    (isnumeric(q.(name)) || islogical(q.(name))) && isscalar(q.(name))
                x = double(q.(name));
                if isfinite(x)
                    v = -x;
                else
                    v = 1e6;
                end
            else
                v = 1e6;
            end
        end

        function printFront(results, frontIdx, dominated, reasons)
            if nargin < 4, reasons = {}; end
            fprintf('\n=== Pareto Front (%d feasible) ===\n', numel(frontIdx));
            fprintf('%-8s %-8s %8s %8s %8s %8s %8s %8s\n', ...
                'ID', 'Status', 'Rel', 'Reten', 'Dist', 'Bad', 'Interp', 'Rank');
            for i = 1:numel(frontIdx)
                q = results(frontIdx(i)).quality;
                fprintf('%-8s %-8s %8s %8s %8s %8s %8s %8s\n', ...
                    results(frontIdx(i)).id, localStatus(results(frontIdx(i))), ...
                    localN(getQ(q, 'reliability')), localN(getQ(q, 'retention')), ...
                    localN(getQ(q, 'waveformDistortion')), localN(getQ(q, 'badRatio')), ...
                    localN(getQ(q, 'interpRatio')), localN(getQ(q, 'rank')));
            end
            if ~isempty(dominated)
                fprintf('Rejected by hard constraints:\n');
                for i = 1:numel(dominated)
                    k = dominated(i);
                    if i <= numel(reasons) && ~isempty(reasons{i})
                        why = reasons{i};
                    else
                        [~, rs] = neuroqc.optimize.HardConstraints.evaluate( ...
                            results(k).quality, struct());
                        why = strjoin(rs, '; ');
                    end
                    fprintf('  %s: %s\n', results(k).id, why);
                end
            end
        end
    end
end

function s = localStatus(rec)
    if isfield(rec, 'status') && ~isempty(rec.status)
        s = char(string(rec.status));
    else
        s = '?';
    end
end

function s = localN(v)
    if ~isnumeric(v) || isempty(v) || ~isfinite(v(1))
        s = 'n/a';
    else
        s = sprintf('%.3f', v(1));
    end
end

function v = getQ(q, name)
    if isstruct(q) && isfield(q, name) && isnumeric(q.(name)) && isscalar(q.(name))
        v = double(q.(name));
    else
        v = NaN;
    end
end
