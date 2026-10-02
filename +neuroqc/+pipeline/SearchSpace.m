classdef SearchSpace
    % SearchSpace - Methodologically constrained preprocessing candidates
    % Discrete, literature-grounded values only — never continuous free search
    
    methods (Static)
        function space = defaultERP()
            space = struct();
            % Prep / EEGLAB setup steps — default off (enable via EEGLAB dialog)
            space.chanloc = {false};
            space.selectData = {false};
            space.selectEvents = {false};
            space.editEvents = {false};
            space.resample = {[], 250, 500};           % [] = keep original
            space.highpass = {0.1, 0.5, 1.0};
            space.lowpass = {20, 30, 40};
            space.reference = {'original', 'average', 'mastoid'};
            space.badChannelThreshold = {5};
            space.badChannel = {'kurtosis'};            % methods
            space.interpolate = {false, true};
            space.artifactThresholdUv = {75, 100, 120};
            space.artifactMethod = {'threshold'};
            space.ica = {false, true};
            space.epochWindow = {[]};                   % from contract
            space.baselineWindow = {[]};                % from contract
            space.fullWorkflow = {false};
            space.icPolicy = {'conservative'};
            space.continuousThresholdDb = {10};
            space.lineNoise = {false};                   % notch on/off
            space.autoRejectThreshold = {false};         % pop_autorej (epoched) off by default
            space.rejectJointprob = {false};             % epoched JP rejection off
            space.rejectKurt = {false};                  % epoched kurt rejection off
        end
        
        function space = fromResume(filepath, completedStages, frozen)
            % Load search space and collapse dimensions already finished in EEGLAB.
            if nargin < 2, completedStages = {}; end
            if nargin < 3, frozen = struct(); end
            space = neuroqc.pipeline.SearchSpace.fromConfig(filepath);
            space = neuroqc.pipeline.StageModel.applyCompleted(space, completedStages, frozen);
        end

        function space = fromConfig(filepath)
            % Load JSON config into search space struct of cell arrays
            raw = jsondecode(fileread(filepath));
            space = struct();
            fn = fieldnames(raw);
            for i = 1:numel(fn)
                v = raw.(fn{i});
                if any(strcmp(fn{i}, {'description','notes'})), continue; end
                if iscell(v)
                    space.(fn{i}) = v(:)';
                elseif isnumeric(v) || islogical(v)
                    if isempty(v), space.(fn{i}) = {[]};
                    elseif any(strcmp(fn{i}, {'epochWindow','baselineWindow'})), space.(fn{i}) = {v};
                    else, space.(fn{i}) = num2cell(v(:)'); end
                else
                    space.(fn{i}) = {v};
                end
                if strcmp(fn{i}, 'resample')
                    for j = 1:numel(space.resample)
                        if isequaln(space.resample{j}, NaN), space.resample{j} = []; end
                    end
                end
            end
        end
        
        function space = adaptToDataset(space, datasetInfo, contract)
            % Shrink candidates based on data + goal (P300 → lower LP)
            if ~isempty(datasetInfo) && datasetInfo.samplingRate <= 250
                space.resample = {[], datasetInfo.samplingRate};
            end
            
            % If only late positive components, prefer LP <= 30
            if ~isempty(contract) && isprop(contract, 'components') && ~isempty(contract.components)
                hasLate = false;
                for i = 1:numel(contract.components)
                    if contract.components(i).window(1) >= 0.25
                        hasLate = true;
                    end
                end
                if hasLate
                    space.lowpass = space.lowpass(cellfun(@(x) x <= 30, space.lowpass));
                    if isempty(space.lowpass), space.lowpass = {30}; end
                end
            end
            
            % Mastoid reference only if candidates exist
            if ~isempty(datasetInfo) && isprop(datasetInfo, 'channelLabels')
                labels = upper(datasetInfo.channelLabels);
                hasMastoid = any(ismember(labels, {'A1','A2','M1','M2','TP9','TP10'}));
                if ~hasMastoid
                    space.reference = space.reference(~strcmpi(space.reference, 'mastoid'));
                    if isempty(space.reference), space.reference = {'original', 'average'}; end
                end
            end
        end
    end
end