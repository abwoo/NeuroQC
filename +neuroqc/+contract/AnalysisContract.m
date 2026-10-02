classdef AnalysisContract
    % AnalysisContract - Formal specification of analysis goals
    % This is the central anchor that drives pipeline generation and evaluation
    
    properties
        analysisType        % char: 'ERP', 'timefreq', 'connectivity'
        paradigm            % char: 'oddball', 'nback', 'rsvp', 'custom'
        subject             % char
        conditions          % struct array: each with .name, .events (cell), .description
        ignoreEvents        % cell array of char: event codes to exclude
        epoch               % struct: .start, .end (seconds relative to event)
        baseline            % struct: .start, .end (seconds, relative to epoch start)
        components          % struct array: ERP components of interest
        channelSelection    % struct: .include, .exclude, .roi (cell arrays)
        qualityThresholds   % struct: custom QC thresholds for this analysis
        notes               % char: free-text notes
        createdAt           % datetime
        version             % char: contract schema version
    end
    
    properties (Dependent)
        conditionNames
        componentNames
        targetChannels
    end
    
    methods
        function obj = AnalysisContract(varargin)
            obj.analysisType = 'ERP';
            obj.paradigm = 'custom';
            obj.conditions = struct('name', {}, 'events', {}, 'description', {});
            obj.ignoreEvents = {};
            obj.epoch = struct('start', -0.2, 'end', 1.0);
            obj.baseline = struct('start', -0.2, 'end', 0);
            obj.components = struct('name', {}, 'window', {}, 'roi', {}, 'type', {});
            obj.channelSelection = struct('include', {{}}, 'exclude', {{}}, 'roi', {{}});
            obj.qualityThresholds = struct();
            obj.notes = '';
            obj.createdAt = datetime('now');
            obj.version = '1.0';
            
            if nargin == 1 && isstruct(varargin{1})
                s = varargin{1};
                for fn = fieldnames(s)'
                    if isprop(obj, fn{1})
                        obj.(fn{1}) = s.(fn{1});
                    end
                end
            end
        end
        
        function names = get.conditionNames(obj)
            names = {obj.conditions.name};
        end
        
        function names = get.componentNames(obj)
            names = {obj.components.name};
        end
        
        function chans = get.targetChannels(obj)
            if ~isempty(obj.channelSelection.roi)
                chans = obj.channelSelection.roi;
            else
                chans = obj.channelSelection.include;
            end
        end
        
        function obj = addCondition(obj, name, events, description)
            tmp = struct();
            tmp.name = name;
            tmp.events = events;
            tmp.description = description;
            obj.conditions(end+1) = tmp;
        end
        
        function obj = addComponent(obj, name, window, roi, type)
            % window: [start end] in seconds
            % roi: cell array of channel labels
            % type: 'peak' or 'mean' amplitude
            if nargin < 5, type = 'mean'; end
            tmp = struct();
            tmp.name = name;
            tmp.window = window;
            tmp.roi = roi;
            tmp.type = type;
            obj.components(end+1) = tmp;
        end
        
        function obj = setEpoch(obj, start, end_)
            obj.epoch.start = start;
            obj.epoch.end = end_;
        end
        
        function obj = setBaseline(obj, start, end_)
            obj.baseline.start = start;
            obj.baseline.end = end_;
        end
        
        function validate(obj, datasetInfo)
            % Validate contract against dataset
            errors = {};
            warnings = {};
            
            % Check events exist
            for ci = 1:numel(obj.conditions)
                c = obj.conditions(ci);
                for ei = 1:numel(c.events)
                    e = c.events{ei};
                    if ~ismember(e, datasetInfo.eventTypes)
                        errors{end+1} = sprintf('Event "%s" for condition "%s" not found in dataset', e, c.name); %#ok<AGROW>
                    end
                end
            end
            
            % Check ignore events
            for ei = 1:numel(obj.ignoreEvents)
                e = obj.ignoreEvents{ei};
                if ~ismember(e, datasetInfo.eventTypes)
                    warnings{end+1} = sprintf('Ignore event "%s" not found in dataset', e); %#ok<AGROW>
                end
            end
            
            % Check epoch window within data bounds
            if obj.epoch.start < 0 && abs(obj.epoch.start) > datasetInfo.duration
                warnings{end+1} = 'Epoch pre-stimulus window may exceed continuous data bounds'; %#ok<AGROW>
            end
            
            % Check component windows within epoch
            for ci = 1:numel(obj.components)
                comp = obj.components(ci);
                if comp.window(1) < obj.epoch.start || comp.window(2) > obj.epoch.end
                    warnings{end+1} = sprintf('Component "%s" window outside epoch bounds', comp.name); %#ok<AGROW>
                end
            end
            
            % Check ROI channels exist
            if ~isempty(obj.channelSelection.roi)
                for chi = 1:numel(obj.channelSelection.roi)
                    ch = obj.channelSelection.roi{chi};
                    if ~ismember(ch, datasetInfo.channelLabels)
                        errors{end+1} = sprintf('ROI channel "%s" not found in dataset', ch); %#ok<AGROW>
                    end
                end
            end
            
            if ~isempty(errors)
                error('AnalysisContract validation failed:\n%s', strjoin(errors, '\n'));
            end
            
            if ~isempty(warnings)
                for wi = 1:numel(warnings)
                    warning('NeuroQC:ContractValidation', '%s', warnings{wi});
                end
            end
        end
        
        function s = toStruct(obj)
            mc = metaclass(obj);
            s = struct();
            for i = 1:numel(mc.PropertyList)
                p = mc.PropertyList(i);
                if p.Dependent || p.Constant
                    continue;
                end
                s.(p.Name) = obj.(p.Name);
            end
        end
        
        function saveJSON(obj, filepath)
            s = obj.toStruct();
            s.createdAt = char(s.createdAt);
            txt = jsonencode(s, 'PrettyPrint', true);
            fid = fopen(filepath, 'w');
            if fid == -1
                error('Cannot open file for writing: %s', filepath);
            end
            fwrite(fid, txt, 'char');
            fclose(fid);
        end
        
        function summary(obj)
            fprintf('=== AnalysisContract ===\n');
            fprintf('Type: %s\n', obj.analysisType);
            fprintf('Paradigm: %s\n', obj.paradigm);
            fprintf('Subject: %s\n', obj.subject);
            fprintf('Conditions (%d):\n', numel(obj.conditions));
            for ci = 1:numel(obj.conditions)
                c = obj.conditions(ci);
                fprintf('  %s: events=%s\n', c.name, strjoin(c.events, ','));
            end
            fprintf('Ignore Events: %s\n', strjoin(obj.ignoreEvents, ', '));
            fprintf('Epoch: [%.2f, %.2f] s\n', obj.epoch.start, obj.epoch.end);
            fprintf('Baseline: [%.2f, %.2f] s\n', obj.baseline.start, obj.baseline.end);
            fprintf('Components (%d):\n', numel(obj.components));
            for ci = 1:numel(obj.components)
                comp = obj.components(ci);
                fprintf('  %s: window=[%.2f, %.2f], roi=%s, type=%s\n', ...
                    comp.name, comp.window(1), comp.window(2), ...
                    strjoin(comp.roi, ','), comp.type);
            end
        end
    end
    
    methods (Static)
        function obj = fromJSON(filepath)
            % Load from JSON file
            s = jsondecode(fileread(filepath));
            s.createdAt = datetime(s.createdAt);
            obj = neuroqc.contract.AnalysisContract(s);
        end
        
        function obj = fromEEGLAB(EEG, subject)
            % Auto-generate contract from EEGLAB dataset
            obj = AnalysisContract();
            obj.subject = subject;
            obj.ignoreEvents = {'boundary'};
        end
    end
end