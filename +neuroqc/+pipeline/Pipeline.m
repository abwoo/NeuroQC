classdef Pipeline
    % Pipeline - Ordered list of preprocessing step specs
    % Each step: struct('type', ..., 'parameters', struct(...))
    
    properties
        id              % char e.g. 'P001'
        description     % char
        steps           % struct array: .type, .parameters
        stage           % char: 'A' signal | 'B' channel/artifact | 'C' ica | 'D' erp
        metadata        % struct: free-form (search space values, etc.)
    end
    
    methods
        function obj = Pipeline(id, stage)
            if nargin < 1, id = 'P000'; end
            if nargin < 2, stage = 'A'; end
            obj.id = id;
            obj.stage = stage;
            obj.description = '';
            obj.steps = struct('type', {}, 'parameters', {});
            obj.metadata = struct();
        end
        
        function obj = addStep(obj, type, parameters)
            if nargin < 3, parameters = struct(); end
            obj.steps(end+1) = struct('type', type, 'parameters', parameters);
        end
        
        function n = numSteps(obj)
            n = numel(obj.steps);
        end
        
        function s = toStruct(obj)
            s = struct('id', obj.id, 'stage', obj.stage, ...
                'description', obj.description, 'metadata', obj.metadata);
            stepsCell = cell(1, numel(obj.steps));
            for i = 1:numel(obj.steps)
                stepsCell{i} = obj.steps(i);
            end
            s.steps = stepsCell;
        end
        
        function print(obj)
            fprintf('Pipeline %s (stage %s): %s\n', obj.id, obj.stage, obj.description);
            for i = 1:numel(obj.steps)
                pstr = '';
                if ~isempty(fieldnames(obj.steps(i).parameters))
                    pstr = jsonencode(obj.steps(i).parameters);
                end
                fprintf('  %2d. %-16s %s\n', i, obj.steps(i).type, pstr);
            end
        end
        
        function key = fingerprint(obj)
            % Canonical string for dedup (stable field order without SortKeys)
            parts = cell(1, numel(obj.steps));
            for i = 1:numel(obj.steps)
                parts{i} = sprintf('%s:%s', obj.steps(i).type, ...
                    localEncode(obj.steps(i).parameters));
            end
            key = strjoin(parts, '|');
        end
    end
end

function txt = localEncode(s)
    if ~isstruct(s) || isempty(fieldnames(s))
        txt = '{}';
        return;
    end
    fn = sort(fieldnames(s));
    pieces = cell(1, numel(fn));
    for i = 1:numel(fn)
        v = s.(fn{i});
        if isnumeric(v)
            vs = mat2str(v);
        elseif ischar(v) || isstring(v)
            vs = ['''' char(v) ''''];
        elseif islogical(v) && isscalar(v)
            vs = mat2str(v);
        elseif iscell(v)
            vs = jsonencode(v);
        else
            try
                vs = jsonencode(v);
            catch
                vs = '<unencodable>';
            end
        end
        pieces{i} = sprintf('%s=%s', fn{i}, vs);
    end
    txt = ['{' strjoin(pieces, ',') '}'];
end