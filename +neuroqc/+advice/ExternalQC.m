classdef ExternalQC
    % ExternalQC - Import user-measured quality metrics for ranking.
    % Processing stays in EEGLAB; NeuroQC only ranks recipes against these metrics.

    methods (Static)
        function q = defaultQuality()
            q = struct( ...
                'status', 'PASS', ...
                'rank', NaN, ...
                'retention', NaN, ...
                'waveformDistortion', NaN, ...
                'interpRatio', NaN, ...
                'badRatio', NaN, ...
                'reliability', NaN, ...
                'topoStability', NaN, ...
                'eventLoss', false, ...
                'baselineSd', NaN, ...
                'snr', NaN, ...
                'topoFidelity', NaN, ...
                'latencyShiftMs', NaN, ...
                'amplitudeError', NaN, ...
                'bandEnergyError', NaN, ...
                'minConditionRetention', NaN, ...
                'conditionRetentionSpread', NaN);
        end

        function results = fromFile(path, pipelines)
            assert(isfile(path), 'NeuroQC:ExternalQC', 'QC file not found: %s', path);
            [~, ~, ext] = fileparts(path);
            if strcmpi(ext, '.csv')
                T = readtable(path, 'TextType', 'char');
                s = table2struct(T);
            elseif strcmpi(ext, '.json')
                raw = jsondecode(fileread(path));
                if isstruct(raw) && isfield(raw, 'results')
                    s = raw.results;
                else
                    s = raw;
                end
                if isstruct(s) && ~isfield(s, 'id') && isfield(s, 'ids') && isfield(s, 'quality')
                    s = arrayfun(@(k) struct('id', s.ids{k}, 'quality', s.quality{k}), ...
                        1:numel(s.ids), 'UniformOutput', false);
                    s = [s{:}];
                end
            else
                error('NeuroQC:ExternalQC', 'Use .csv or .json for external QC');
            end
            results = neuroqc.advice.ExternalQC.fromStruct(s, pipelines);
        end

        function results = fromStruct(s, pipelines)
            n = numel(pipelines);
            results = struct('id', {}, 'pipeline', {}, 'run', {}, 'quality', {}, 'status', {});
            if isempty(s)
                error('NeuroQC:ExternalQC', 'Empty QC source');
            end
            if iscolumn(s), s = s(:)'; end
            assert(numel(s) >= 1, 'NeuroQC:ExternalQC', 'Empty QC source');
            byId = containers.Map('KeyType', 'char', 'ValueType', 'any');
            hasId = all(isfield(s, 'id'));
            if hasId
                for i = 1:numel(s)
                    key=char(string(s(i).id));
                    assert(~isKey(byId,key),'NeuroQC:ExternalQC','Duplicate QC candidate ID');
                    byId(key) = s(i);
                end
            elseif numel(s) ~= n
                error('NeuroQC:ExternalQC', ...
                    'QC rows (%d) must match pipelines (%d) when no id column', ...
                    numel(s), n);
            end
            matchedCount = 0;
            for k = 1:n
                p = pipelines(k);
                row = [];
                if hasId
                    if isKey(byId, p.id)
                        row = byId(p.id);
                        matchedCount = matchedCount + 1;
                    end
                else
                    row = s(k);
                    matchedCount = matchedCount + 1;
                end
                if isempty(row)
                    % Unmatched pipeline: keep 1:1 index alignment with MISSING_QC
                    q = neuroqc.advice.ExternalQC.defaultQuality();
                    q.status = 'MISSING_QC';
                    results(k) = struct( ...
                        'id', p.id, ...
                        'pipeline', p, ...
                        'run', struct('external', true, 'missing', true), ...
                        'quality', q, ...
                        'status', 'MISSING_QC');
                else
                    q = neuroqc.advice.ExternalQC.mergeQuality(row);
                    if isfield(row, 'status') && ~isempty(row.status)
                        q.status = char(string(row.status));
                    end
                    results(k) = struct( ...
                        'id', p.id, ...
                        'pipeline', p, ...
                        'run', struct('external', true), ...
                        'quality', q, ...
                        'status', q.status);
                end
            end
            if hasId
                assert(matchedCount >= 1, 'NeuroQC:ExternalQC', ...
                    'No QC rows matched generated pipeline ids');
            end
        end

        function q = mergeQuality(row)
            %mergeQuality Map an external QC row onto the canonical quality struct.
            %  waveformDistortion must be the relative-L2 definition
            %  (CandidateSession.measure, [0,Inf)); the correlation-based
            %  polarity metric (filterQC.polarityDistortion, [0,2]) is a
            %  different measurement and must not be imported under this key.
            q = neuroqc.advice.ExternalQC.defaultQuality();
            if isfield(row, 'quality') && isstruct(row.quality)
                src = row.quality;
            else
                src = row;
            end
            names = fieldnames(q);
            for i = 1:numel(names)
                f = names{i};
                if isfield(src, f)
                    v = src.(f);
                    if ischar(v) || isstring(v)
                        q.(f) = char(v);
                    elseif islogical(v)
                        q.(f) = logical(v);
                    elseif isnumeric(v) && isscalar(v)
                        if strcmp(f, 'status')
                            q.status = char(string(v));
                        else
                            q.(f) = double(v);
                        end
                    end
                end
            end
            if ischar(q.status) || isstring(q.status)
                q.status = char(q.status);
            else
                q.status = 'PASS';
            end
        end
    end
end
