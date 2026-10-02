classdef EEGImporter
    % EEGImporter - Load EEGLAB .set/.fdt and build DatasetInfo + inspection
    
    methods (Static)
        function [EEG, info] = importFile(filepath, opts)
            % Import .set file and produce DatasetInfo
            if nargin < 2, opts = struct(); end
            if ~isfield(opts, 'subject'), opts.subject = ''; end
            if ~isfield(opts, 'runInspection'), opts.runInspection = true; end
            
            if ~exist(filepath, 'file')
                error('NeuroQC:FileNotFound', 'File not found: %s', filepath);
            end
            
            if ~exist('pop_loadset', 'file')
                error('NeuroQC:EEGLABRequired', ...
                    'pop_loadset not found. Start EEGLAB first: eeglab');
            end
            
            EEG = pop_loadset(filepath);
            
            if isempty(opts.subject)
                [~, base] = fileparts(filepath);
                opts.subject = base;
            end
            
            info = neuroqc.io.EEGImporter.fromEEG(EEG, filepath, opts);
            
            if opts.runInspection
                info.inspection = neuroqc.inspect.DatasetInspector.inspect(EEG);
                info.eventReport = neuroqc.inspect.EventInspector.inspect(EEG);
            end
        end
        
        function info = fromEEG(EEG, filepath, opts)
            % Build DatasetInfo from an EEGLAB EEG struct
            if nargin < 2, filepath = ''; end
            if nargin < 3, opts = struct(); end
            if ~isfield(opts, 'subject'), opts.subject = 'unknown'; end
            
            s = struct();
            s.filename = filepath;
            s.subject = opts.subject;
            s.samplingRate = EEG.srate;
            s.channelCount = EEG.nbchan;
            
            if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs)
                s.channelLabels = {EEG.chanlocs.labels};
            else
                s.channelLabels = arrayfun(@(k) sprintf('Ch%d', k), 1:EEG.nbchan, 'UniformOutput', false);
            end
            
            if isfield(EEG, 'chanlocs')
                s.channelLocations = EEG.chanlocs;
            end
            
            if EEG.trials > 1 || (isfield(EEG,'epoch') && ~isempty(EEG.epoch))
                s.duration = EEG.pnts * EEG.trials / EEG.srate;
                s.isContinuous = false;
                s.epochInfo = struct('trials', EEG.trials, 'pnts', EEG.pnts, ...
                    'xmin', EEG.xmin, 'xmax', EEG.xmax);
            else
                s.duration = EEG.pnts / EEG.srate;
                s.isContinuous = true;
                s.epochInfo = struct();
            end
            
            s.dataRank = neuroqc.utils.estimateRank(EEG.data);
            s.reference = neuroqc.io.EEGImporter.inferReference(EEG);
            
            if isfield(EEG, 'event')
                s.eegEvents = EEG.event;
                [s.eventTypes, s.eventCounts] = neuroqc.io.EEGImporter.eventStats(EEG.event);
            else
                s.eegEvents = struct([]);
                s.eventTypes = {};
                s.eventCounts = containers.Map('KeyType', 'char', 'ValueType', 'double');
            end
            
            s.eeglabVersion = neuroqc.utils.eeglabVersionSafe();
            s.matlabVersion = version();
            s.datasetHash = neuroqc.utils.hashEEG(EEG);
            
            info = neuroqc.io.DatasetInfo(s);
        end
        
        function ref = inferReference(EEG)
            ref = 'unknown';
            if ~isfield(EEG, 'ref') || isempty(EEG.ref)
                ref = 'unknown';
                return;
            end
            r = EEG.ref;
            if isnumeric(r)
                ref = 'numeric';
            elseif ischar(r) || isstring(r)
                r = char(r);
                if strcmpi(r, 'average')
                    ref = 'average';
                elseif contains(lower(r), 'mastoid') || strcmpi(r, 'A1') || strcmpi(r, 'A2')
                    ref = 'mastoid';
                else
                    ref = r;
                end
            end
        end
        
        function [types, counts] = eventStats(events)
            if isempty(events)
                types = {};
                counts = containers.Map('KeyType', 'char', 'ValueType', 'double');
                return;
            end
            n = numel(events);
            codes = cell(n, 1);
            for i = 1:n
                t = events(i).type;
                if isnumeric(t), codes{i} = num2str(t);
                elseif ischar(t), codes{i} = t;
                else, codes{i} = char(string(t));
                end
            end
            types = unique(codes);
            counts = containers.Map('KeyType', 'char', 'ValueType', 'double');
            for i = 1:numel(types)
                counts(types{i}) = sum(strcmp(codes, types{i}));
            end
        end
        
        function printInfo(info)
            info.summary();
        end
    end
end