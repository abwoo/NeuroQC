classdef DatasetInfo
    % DatasetInfo - Core data structure for EEG dataset metadata
    % Immutable after construction
    
    properties
        filename           % char: source file path
        subject            % char: subject identifier
        samplingRate       % double: Hz
        channelCount       % double: number of channels
        channelLabels      % cell array of char: channel names
        channelLocations   % struct: EEGLAB locs structure (optional)
        duration           % double: seconds
        dataRank           % double: rank of data matrix
        reference          % char: reference type ('original', 'average', 'mastoid', 'linked_mastoid', 'unknown')
        eegEvents          % struct array: EEGLAB events (property name avoids MATLAB 'events' keyword)
        eventTypes         % cell array of char: unique event type codes
        eventCounts        % containers.Map: event type -> count
        isContinuous       % logical: true if continuous, false if epoched
        epochInfo          % struct: if epoched, contains epoch parameters
        eeglabVersion      % char
        matlabVersion      % char
        importedAt         % datetime
        inspection = struct()
        eventReport = struct()
        datasetHash        % char: SHA256 of raw data for provenance
    end
    
    methods
        function obj = DatasetInfo(varargin)
            if nargin == 1 && isstruct(varargin{1})
                s = varargin{1};
                for fn = fieldnames(s)'
                    if isprop(obj, fn{1})
                        obj.(fn{1}) = s.(fn{1});
                    end
                end
            elseif nargin > 0
                % Allow property-value pairs
                for i = 1:2:nargin-1
                    prop = varargin{i};
                    val = varargin{i+1};
                    if isprop(obj, prop)
                        obj.(prop) = val;
                    end
                end
            end
            
            if isempty(obj.importedAt)
                obj.importedAt = datetime('now');
            end
        end
        
        function s = toStruct(obj)
            s = struct();
            for fn = properties(obj)'
                s.(fn{1}) = obj.(fn{1});
            end
        end
        
        function summary = summary(obj)
            fprintf('=== DatasetInfo Summary ===\n');
            fprintf('Subject: %s\n', obj.subject);
            fprintf('File: %s\n', obj.filename);
            fprintf('Sampling Rate: %.1f Hz\n', obj.samplingRate);
            fprintf('Channels: %d\n', obj.channelCount);
            fprintf('Duration: %.2f s\n', obj.duration);
            fprintf('Data Rank: %d\n', obj.dataRank);
            fprintf('Reference: %s\n', obj.reference);
            fprintf('Continuous: %s\n', mat2str(obj.isContinuous));
            fprintf('Event Types: %d\n', numel(obj.eventTypes));
            if ~isempty(obj.eventCounts)
                keys = obj.eventCounts.keys();
                values = obj.eventCounts.values();
                for i = 1:numel(keys)
                    fprintf('  %s: %d\n', keys{i}, values{i});
                end
            end
            fprintf('Imported: %s\n', char(obj.importedAt));
            fprintf('Dataset Hash: %s\n', obj.datasetHash);
        end
    end
end