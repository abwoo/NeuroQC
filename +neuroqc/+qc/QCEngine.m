classdef QCEngine
    % QCEngine - Unified QC evaluation for every processing step
    % status: PASS | PASS_WITH_WARNING | REVIEW | FAIL | NOT_RUN
    
    properties (Constant)
        Statuses = {'PASS', 'PASS_WITH_WARNING', 'REVIEW', 'FAIL', 'NOT_RUN'};
    end
    
    methods (Static)
        function EEG = toVolts(EEG)
            % Normalize a declared-µV dataset to volts for +qc/* helpers.
            if isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && ...
                    isfield(EEG.etc.neuroqc, 'dataUnit') && strcmp(EEG.etc.neuroqc.dataUnit, 'uV')
                EEG = neuroqc.io.Units.convert(EEG, 'uV', 'V');
            end
        end

        function result = evaluate(beforeEEG, afterEEG, stepType, parameters, contract)
            % Evaluate QC for one step.
            % beforeEEG / afterEEG: EEGLAB structs (after may be empty for pre-checks)
            % stepType: char
            % parameters: struct
            % contract: AnalysisContract or []
            
            if nargin < 4, parameters = struct(); end
            if nargin < 5, contract = []; end

            % Unit contract: every +qc/* helper computes in volts and reports
            % µV via an explicit x1e6. Inputs declaring etc.neuroqc.dataUnit
            % = 'uV' (the recipe path converts data to µV) are converted back
            % to V before dispatch so metrics stay µV-sized; undeclared inputs
            % keep the legacy volts assumption.
            if ~isempty(beforeEEG) && isstruct(beforeEEG)
                beforeEEG = neuroqc.qc.QCEngine.toVolts(beforeEEG);
            end
            if ~isempty(afterEEG) && isstruct(afterEEG)
                afterEEG = neuroqc.qc.QCEngine.toVolts(afterEEG);
            end

            result = struct();
            result.step = stepType;
            result.parameters = parameters;
            result.metrics = struct();
            result.warnings = {};
            result.recommendations = {};
            
            try
                switch lower(stepType)
                    case 'resample'
                        r = neuroqc.qc.resampleQC(beforeEEG, afterEEG, parameters);
                    case {'filter', 'highpass', 'lowpass', 'bandpass'}
                        r = neuroqc.qc.filterQC(beforeEEG, afterEEG, parameters, contract);
                    case {'reref', 'reference'}
                        r = neuroqc.qc.referenceQC(beforeEEG, afterEEG, parameters);
                    case {'badchannel', 'bad_channels', 'detect_bad'}
                        r = neuroqc.qc.badChannelQC(afterEEG, parameters);
                    case {'interpolate'}
                        r = neuroqc.qc.interpolateQC(beforeEEG, afterEEG, parameters);
                    case {'ica','run_ica'}
                        r = neuroqc.qc.icaQC(beforeEEG, afterEEG, parameters);
                    case {'ic_remove', 'icrejection','remove_ics','auto_ic_remove'}
                        r = neuroqc.qc.icRemoveQC(beforeEEG, afterEEG, parameters);
                    case {'epoch'}
                        r = neuroqc.qc.epochQC(afterEEG, parameters, contract);
                    case {'artifact', 'artifact_rejection', 'artifact_reject'}
                        r = neuroqc.qc.artifactQC(afterEEG, parameters, contract);
                    case {'baseline'}
                        r = neuroqc.qc.baselineQC(afterEEG, parameters, contract);
                    case {'remove_bad','restore_channels','notch','reject_continuous'}
                        r = neuroqc.qc.workflowQC(beforeEEG,afterEEG,lower(stepType),parameters);
                    otherwise
                        r = struct('status', 'FAIL', 'metrics', struct(), ...
                            'warnings', {{}}, 'recommendations', {{}}, ...
                            'message', sprintf('No QC rule for step "%s" (skipped)', stepType));
                end
            catch ME
                r = struct('status', 'FAIL', 'metrics', struct(), ...
                    'warnings', {{ME.message}}, 'recommendations', {{}}, ...
                    'message', 'QC evaluation threw error');
            end
            
            result.status = r.status;
            result.metrics = r.metrics;
            if isfield(r, 'warnings'), result.warnings = r.warnings; end
            if isfield(r, 'recommendations'), result.recommendations = r.recommendations; end
            if isfield(r, 'message'), result.message = r.message; end
        end
        
        function s = rollup(statusList)
            % Combined status for a list
            if any(strcmpi(statusList, 'FAIL'))
                s = 'FAIL';
            elseif any(strcmpi(statusList, 'REVIEW'))
                s = 'REVIEW';
            elseif any(strcmpi(statusList, 'PASS_WITH_WARNING'))
                s = 'PASS_WITH_WARNING';
            elseif all(strcmpi(statusList, 'PASS')) || isempty(statusList)
                s = 'PASS';
            else
                s = 'NOT_RUN';
            end
        end
        
        function [icIdx, info] = selectICs(probs, classNames, policy)
            % Pure ICLabel policy selection (no data mutation).
            % probs: nIC x nClass probabilities; classNames: 1 x nClass labels.
            if nargin < 3 || isempty(policy), policy = 'conservative'; end
            policy = lower(char(policy));
            assert(any(strcmp(policy, {'conservative', 'moderate'})), ...
                'NeuroQC:ICPolicy', 'policy must be conservative or moderate');
            if ischar(classNames) || isstring(classNames), classNames = cellstr(classNames); end
            nIC = size(probs, 1);
            artifactKeys = {'muscle', 'eye', 'heart', 'line noise', 'channel noise'};
            col = zeros(1, numel(classNames));
            for j = 1:numel(classNames)
                col(j) = j;
            end
            % Map class names (case-insensitive) for artifact columns
            artifactCols = [];
            for j = 1:numel(classNames)
                name = lower(strtrim(char(classNames{j})));
                if any(strcmp(name, artifactKeys))
                    artifactCols(end+1) = j; %#ok<AGROW>
                end
            end
            assert(~isempty(artifactCols), 'NeuroQC:ICPolicy', ...
                'No artifact classes found in classNames');
            switch policy
                case 'conservative'
                    thr = 0.90;
                case 'moderate'
                    thr = 0.80;
            end
            icIdx = [];
            for i = 1:nIC
                mx = max(probs(i, artifactCols));
                if isfinite(mx) && mx >= thr
                    icIdx(end+1) = i; %#ok<AGROW>
                end
            end
            info = struct('policy', policy, 'threshold', thr, ...
                'nIC', nIC, 'nSelected', numel(icIdx), ...
                'artifactCols', artifactCols);
        end

        function printResult(result)
            fprintf('QC [%s]: %s\n', result.step, result.status);
            if isfield(result, 'message') && ~isempty(result.message)
                fprintf('  %s\n', result.message);
            end
            fn = fieldnames(result.metrics);
            for i = 1:numel(fn)
                v = result.metrics.(fn{i});
                if isnumeric(v) && isscalar(v)
                    fprintf('  %s = %.4g\n', fn{i}, v);
                elseif islogical(v) && isscalar(v)
                    fprintf('  %s = %s\n', fn{i}, mat2str(v));
                end
            end
            for i = 1:numel(result.warnings)
                fprintf('  WARN: %s\n', result.warnings{i});
            end
            for i = 1:numel(result.recommendations)
                fprintf('  REC:  %s\n', result.recommendations{i});
            end
        end
    end
end