classdef StageModel
    % StageModel - Discrete preprocessing stage vocabulary + resume support.
    % Two order modes:
    %   'prefix' (default): completed set expands to a canonical prefix freeze.
    %   'set': completed stages are an exact set; remaining steps may appear
    %          in any order via opts.stepOrder. Callers set this explicitly
    %          (GUI exact-set mode, MVP, ResumeOptimizer).
    % Pure combinatorial — no AI.

    methods (Static)
        function st = parseFixedSlots(txt, steps)
            % Parse 'filter=1,epoch=6' into absolute slot pins (GUI + API).
            st = struct();
            if isstring(txt), txt = char(txt); end
            parts = strsplit(txt, ',');
            for k = 1:numel(parts)
                p = strtrim(parts{k});
                if isempty(p), continue; end
                kv = strsplit(p, '=');
                assert(numel(kv) == 2, 'NeuroQC:Config', ...
                    'Fixed slots format: step=position (comma separated), got "%s"', p);
                name = strtrim(kv{1});
                v = str2double(strtrim(kv{2}));
                assert(ismember(name, steps), 'NeuroQC:Config', ...
                    'Fixed slot "%s" is not in Steps to compare', name);
                assert(isfinite(v) && v >= 1 && v == fix(v), 'NeuroQC:Config', ...
                    'Fixed slot position for %s must be a positive integer', name);
                assert(~isfield(st, name), 'NeuroQC:Config', ...
                    'Duplicate fixed slot for %s', name);
                st.(name) = v;
            end
            vals = struct2cell(st);
            if ~isempty(vals)
                nums = cell2mat(vals);  % all positions are numeric scalars
                assert(numel(unique(nums)) == numel(nums), ...
                    'NeuroQC:Config', 'Fixed slot positions must be distinct');
            end
        end

        function [space, frozen] = applyLockSpec(space, lockSpec)
            % Enforce value locks declared in opts.lockSpec (API + GUI path):
            % collapse each locked dimension to its single locked value and
            % return them as a frozen struct for report.fixedParameters.
            frozen = struct();
            if nargin < 2 || isempty(lockSpec), return; end
            assert(isstruct(lockSpec) && isscalar(lockSpec), 'NeuroQC:Config', ...
                'lockSpec must be a scalar struct of dimension=value pairs');
            fn = fieldnames(lockSpec);
            for k = 1:numel(fn)
                f = fn{k}; v = lockSpec.(f);
                assert(isfield(space, f), 'NeuroQC:UnknownDimension', ...
                    'lockSpec dimension %s is not in the search space', f);
                vals = space.(f);
                found = false;
                for i = 1:numel(vals)
                    if isequaln(vals{i}, v), found = true; break; end
                end
                assert(found, 'NeuroQC:Config', ...
                    'lockSpec value for %s is not among the declared search values', f);
                space.(f) = {v};
                frozen.(f) = v;
            end
        end

        function opts=resolveScope(opts)
            if isfield(opts,'startAfter') && ~isempty(opts.startAfter)
                assert(~isfield(opts,'completedStages') || isempty(opts.completedStages),'NeuroQC:AmbiguousHandoff','Use startAfter OR completedStages');
                if strcmp(opts.startAfter,'raw'), opts.completedStages={}; else, opts.completedStages={opts.startAfter}; end
                opts.orderMode='prefix';
                opts=rmfield(opts,'startAfter');
            end
            if ~isfield(opts,'completedStages'), opts.completedStages={}; end
            if ~isfield(opts,'orderMode'), opts.orderMode='prefix'; end
            if ~isfield(opts,'selectedSteps'), opts.selectedSteps={}; end
            if ~isfield(opts,'searchOrder'), opts.searchOrder=false; end
            if ~isfield(opts,'maxOrders'), opts.maxOrders=10000; end
            if ~isfield(opts,'maxPipelines'), opts.maxPipelines=0; end
            if ~isfield(opts,'fixedPositions'), opts.fixedPositions=struct(); end
            assert(isscalar(opts.fixedPositions) && isscalar(opts.searchOrder) && any(opts.searchOrder==[0 1]),'NeuroQC:Config','searchOrder must be logical');
            assert(isscalar(opts.maxOrders) && isfinite(opts.maxOrders) && opts.maxOrders>=1 && opts.maxOrders==fix(opts.maxOrders),'NeuroQC:Config','maxOrders must be a positive integer');
            assert(isscalar(opts.maxPipelines) && isfinite(opts.maxPipelines) && opts.maxPipelines>=0 && opts.maxPipelines==fix(opts.maxPipelines),'NeuroQC:Config','maxPipelines must be a nonnegative integer (0 = full exhaustive)');
            if ischar(opts.selectedSteps) || isstring(opts.selectedSteps), opts.selectedSteps=cellstr(opts.selectedSteps); end
            opts.selectedSteps=cellfun(@(x) lower(char(x)),opts.selectedSteps(:)','UniformOutput',false);
            assert(isempty(setdiff(opts.selectedSteps,neuroqc.pipeline.StageModel.canonicalOrder())),'NeuroQC:UnknownStage','Unknown selected step');
            pins=fieldnames(opts.fixedPositions);
            if ~isempty(pins)
                assert(opts.searchOrder,'NeuroQC:Config','fixedPositions requires searchOrder=true');
                assert(isempty(setdiff(pins,opts.selectedSteps)),'NeuroQC:Config','Position pins must name selected steps');
                slots=cellfun(@(s) opts.fixedPositions.(s),pins);
                assert(all(isfinite(slots) & slots>=1 & slots<=numel(opts.selectedSteps) & slots==fix(slots)) && numel(unique(slots))==numel(slots),'NeuroQC:Config','Positions must be distinct valid integer slots');
            end
            completed=neuroqc.pipeline.StageModel.normalizeCompleted(opts.completedStages,opts.orderMode);
            assert(isempty(intersect(opts.selectedSteps,completed)),'NeuroQC:CompletedStep','Selected steps overlap the completed/frozen stages');
        end
        function validateTransition(types,info,completed)
            assert(~(ismember('interpolate',types) && ismember('remove_bad',types)),'NeuroQC:StepDependency','Choose in-place interpolate OR remove_bad then restore_channels');
            epoched=~info.isContinuous;
            hasICA=ismember('run_ica',completed) && ~ismember('auto_ic_remove',completed);
            changedMix=false;
            for k=1:numel(types)
                type=types{k};
                if any(strcmp(type,{'baseline','artifact_reject','auto_reject','reject_jointprob','reject_kurtosis'})) && ~epoched
                    error('NeuroQC:StepDependency','%s requires epoched input or a preceding epoch step',type);
                end
                if strcmp(type,'reject_continuous') && epoched
                    error('NeuroQC:StepDependency','Continuous rejection cannot run on epochs');
                end
                if strcmp(type,'epoch')
                    assert(~epoched,'NeuroQC:StepDependency','Cannot epoch already epoched data'); epoched=true;
                end
                if any(strcmp(type,{'reref','remove_bad','interpolate','restore_channels'})), changedMix=true; end
                if strcmp(type,'run_ica'), hasICA=true; changedMix=false; end
                if strcmp(type,'auto_ic_remove')
                    assert(hasICA && ~changedMix,'NeuroQC:StepDependency','IC removal requires compatible ICA; recompute ICA after channel/reference changes');
                end
            end
        end
        function [ok, reason] = validateOrderState(steps, info)
            % Position-aware data-state feasibility for ONE concrete order.
            % validateTransition handles type-level state (epoched/ICA/mix);
            % this walks the ordered steps simulating value-level state:
            % running srate (Nyquist at execution position) and the channel
            % set version (bad-channel indices must not go stale).
            ok = true; reason = '';
            srate = info.samplingRate;
            chVersion = 0;   % increments on channel-count-changing selection
            badAt = -1;      % channel version when badchannel detected
            for k = 1:numel(steps)
                type = lower(char(steps(k).type));
                p = steps(k).parameters;
                switch type
                    case 'resample'
                        if isfield(p, 'fs') && isscalar(p.fs) && ...
                                isfinite(p.fs) && p.fs > 0 && p.fs <= srate
                            srate = p.fs;
                        end
                    case 'select_data'
                        if isfield(p, 'channel') && ~isempty(p.channel)
                            chVersion = chVersion + 1;
                        end
                    case 'badchannel'
                        badAt = chVersion;
                    case 'filter'
                        if isfield(p, 'lowpass') && isscalar(p.lowpass) && ...
                                isfinite(p.lowpass) && p.lowpass > 0 && ...
                                p.lowpass >= srate / 2
                            ok = false; reason = 'filter_above_Nyquist_at_position'; return;
                        end
                    case 'notch'
                        if isfield(p, 'frequency') && isscalar(p.frequency) && ...
                                p.frequency > 0 && p.frequency + 2 >= srate / 2
                            ok = false; reason = 'notch_above_Nyquist_at_position'; return;
                        end
                    case {'interpolate', 'remove_bad'}
                        if badAt >= 0 && chVersion ~= badAt
                            ok = false;
                            reason = 'bad_channel_indices_stale_after_channel_selection';
                            return;
                        end
                    case 'reject_continuous'
                        if srate <= 42
                            ok = false;
                            reason = 'continuous_spectral_rejection_requires_sampling_rate_above_42Hz';
                            return;
                        end
                    case 'auto_ic_remove'
                        if srate < 100
                            ok = false; reason = 'ICLabel_requires_100Hz'; return;
                        end
                end
            end
        end
        function names = canonicalOrder()
            % Full EEGLAB preprocess vocabulary: prep (chanloc/select/events)
            % first, then signal steps, then epoched rejection family.
            names = {'chanloc','select_data','select_events','edit_events', ...
                'resample','notch','filter','badchannel','remove_bad', ...
                'interpolate','reject_continuous','reref','run_ica', ...
                'auto_ic_remove','restore_channels','epoch','baseline','artifact_reject', ...
                'auto_reject','reject_jointprob','reject_kurtosis'};
        end

        function m = dimensionStages()
            % Search dimension -> pipeline step types it can emit
            m = struct();
            m.chanloc = {'chanloc'};
            m.selectData = {'select_data'};
            m.selectEvents = {'select_events'};
            m.editEvents = {'edit_events'};
            m.resample = {'resample'};
            m.highpass = {'filter'};
            m.lowpass = {'filter'};
            m.lineNoise = {'notch'};
            m.badChannel = {'badchannel'};
            m.badChannelThreshold = {'badchannel'};
            m.interpolate = {'interpolate','restore_channels'};
            m.reference = {'reref'};
            m.ica = {'run_ica','auto_ic_remove'};
            m.icPolicy = {'auto_ic_remove'};
            m.continuousThresholdDb = {'reject_continuous'};
            m.artifactThresholdUv = {'artifact_reject'};
            m.artifactMethod = {'artifact_reject'};
            m.autoRejectThreshold = {'auto_reject'};
            m.rejectJointprob = {'reject_jointprob'};
            m.rejectKurt = {'reject_kurtosis'};
            m.epochWindow = {'epoch'};
            m.baselineWindow = {'baseline'};
            m.fullWorkflow = {'remove_bad','reject_continuous','auto_ic_remove','restore_channels'};
        end

        function completed = normalizeCompleted(completed, orderMode)
            if nargin < 2 || isempty(orderMode), orderMode = 'prefix'; end
            if isempty(completed), completed = {}; return; end
            if ischar(completed) || isstring(completed), completed = cellstr(completed); end
            completed = cellfun(@(x) lower(char(x)), completed(:)', 'UniformOutput', false);
            completed = unique(completed, 'stable');
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            unknown = setdiff(completed, known);
            if ~isempty(unknown)
                error('NeuroQC:UnknownStage', ...
                    'Unknown completed stage(s): %s. Allowed: %s', ...
                    strjoin(unknown, ', '), strjoin(known, ', '));
            end
            orderMode = lower(char(orderMode));
            if ~any(strcmp(orderMode, {'prefix', 'set'}))
                error('NeuroQC:OrderMode', ...
                    'orderMode must be ''prefix'' or ''set''');
            end
            % prefix: handoff freezes through the latest declared stage.
            % set: exact completed set only (arbitrary remaining order).
            if strcmp(orderMode, 'prefix') && ~isempty(completed)
                cutoff = max(find(ismember(known, completed))); %#ok<MXFND>
                completed = known(1:cutoff);
            end
        end

        function tf = isDone(completed, stage)
            tf = any(strcmpi(completed, stage));
        end

        function validateStepOrder(stepOrder)
            if isempty(stepOrder), return; end
            if ischar(stepOrder) || isstring(stepOrder), stepOrder = cellstr(stepOrder); end
            stepOrder = cellfun(@(x) lower(char(x)), stepOrder(:)', 'UniformOutput', false);
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            unknown = setdiff(stepOrder, known);
            if ~isempty(unknown)
                error('NeuroQC:UnknownStepOrder', ...
                    'Unknown stepOrder stage(s): %s', strjoin(unknown, ', '));
            end
            if numel(unique(stepOrder)) ~= numel(stepOrder)
                error('NeuroQC:DuplicateStepOrder', 'stepOrder contains duplicates');
            end
            neuroqc.pipeline.StageModel.assertStepDependencies(stepOrder);
        end

        function pairs=dependencyPairs()
            pairs = {
                'remove_bad',        'badchannel'
                'interpolate',       'badchannel'
                'restore_channels',  'remove_bad'
                'auto_ic_remove',    'run_ica'
                'baseline',          'epoch'
                'artifact_reject',   'epoch'
                'auto_reject',       'epoch'
                'reject_jointprob',  'epoch'
                'reject_kurtosis',   'epoch'
                'epoch',             'reject_continuous'
            };
        end

        function assertStepDependencies(types)
            % Hard methodological dependencies among steps that will run.
            if ischar(types) || isstring(types), types = cellstr(types); end
            types = cellfun(@(x) lower(char(x)), types(:)', 'UniformOutput', false);
            % after, before
            pairs=neuroqc.pipeline.StageModel.dependencyPairs();
            for i = 1:size(pairs, 1)
                after = pairs{i, 1};
                before = pairs{i, 2};
                ia = find(strcmp(types, after), 1);
                ib = find(strcmp(types, before), 1);
                if ~isempty(ia) && ~isempty(ib) && ia < ib
                    error('NeuroQC:StepDependency', ...
                        'Invalid stepOrder: %s must come after %s', after, before);
                end
            end
        end

        function order = orderPending(specs, stepOrder)
            % specs: cell of {type, params}; return ordered cell.
            % Unlisted steps are interleaved by canonical position (not dumped at end).
            if isempty(specs)
                order = specs;
                return;
            end
            if isempty(stepOrder)
                neuroqc.pipeline.StageModel.assertStepDependencies( ...
                    cellfun(@(s) s{1}, specs, 'UniformOutput', false));
                order = specs;
                return;
            end
            if ischar(stepOrder) || isstring(stepOrder), stepOrder = cellstr(stepOrder); end
            stepOrder = cellfun(@(x) lower(char(x)), stepOrder(:)', 'UniformOutput', false);
            neuroqc.pipeline.StageModel.validateStepOrder(stepOrder);

            n = numel(specs);
            types = cell(1, n);
            for i = 1:n
                types{i} = lower(char(specs{i}{1}));
            end
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            canonPos = zeros(1, n);
            for i = 1:n
                ix = find(strcmp(known, types{i}), 1);
                if isempty(ix), ix = numel(known) + i; end
                canonPos(i) = ix;
            end

            % Key: listed -> stepOrder rank * (n+1); unlisted -> canonical slot
            % interleaved via fractional insert among listed ranks.
            listedRank = nan(1, n);
            for i = 1:n
                ix = find(strcmp(stepOrder, types{i}), 1);
                if ~isempty(ix), listedRank(i) = ix; end
            end
            keys = zeros(1, n);
            tie = zeros(1, n);
            maxCanon = max(canonPos);
            for i = 1:n
                if ~isnan(listedRank(i))
                    keys(i) = listedRank(i) * (n + 1);
                    tie(i) = 1;
                else
                    nBefore = 0;
                    for j = 1:n
                        if ~isnan(listedRank(j)) && canonPos(j) < canonPos(i)
                            nBefore = nBefore + 1;
                        end
                    end
                    keys(i) = nBefore * (n + 1) + (n + 1) / 2;
                    tie(i) = 1 + canonPos(i) / (maxCanon + 1);
                end
            end
            [~, ix] = sortrows([keys(:), tie(:), (1:n)']);
            order = specs(ix);
            neuroqc.pipeline.StageModel.assertStepDependencies( ...
                cellfun(@(s) s{1}, order, 'UniformOutput', false));
        end

        function [space, locked] = applyCompleted(space, completed, frozen, orderMode)
            % Collapse dimensions whose steps are all completed (or forced by resume).
            if nargin < 3 || isempty(frozen), frozen = struct(); end
            if nargin < 4 || isempty(orderMode), orderMode = 'prefix'; end
            completed = neuroqc.pipeline.StageModel.normalizeCompleted(completed, orderMode);
            dimMap = neuroqc.pipeline.StageModel.dimensionStages();
            locked = struct('completedStages', {completed}, 'collapsedDimensions', {{}}, ...
                'orderMode', orderMode);
            % A locked pending dimension is fixed-execution, not skipped.
            unknown=setdiff(fieldnames(frozen),fieldnames(space));
            assert(isempty(unknown),'NeuroQC:UnknownDimension','Unknown locked dimension');
            for field=fieldnames(frozen)'
                space.(field{1})={frozen.(field{1})};
                locked.collapsedDimensions{end+1}=field{1};
            end
            if isempty(completed), return; end

            dims = fieldnames(dimMap);
            for i = 1:numel(dims)
                dim = dims{i};
                if ~isfield(space, dim), continue; end
                stages = dimMap.(dim);
                allDone = all(cellfun(@(s) neuroqc.pipeline.StageModel.isDone(completed, s), stages));
                forceSingle = false;
                if strcmp(dim, 'ica') && neuroqc.pipeline.StageModel.isDone(completed, 'run_ica')
                    forceSingle = true; % ICA already on EEG — do not search ica=false
                    if ~isfield(frozen, 'ica'), frozen.ica = true; end
                end
                if ~allDone && ~forceSingle, continue; end
                if isfield(frozen, dim)
                    space.(dim) = {frozen.(dim)};
                else
                    space.(dim) = space.(dim)(1); %#ok<*AGROW>
                end
                locked.collapsedDimensions{end+1} = dim; %#ok<AGROW>
            end
            locked.collapsedDimensions = unique(locked.collapsedDimensions, 'stable');
        end

        function validateEEG(EEG, completed, orderMode)
            % EEG state must match declared completed stages (fail closed).
            if nargin < 3 || isempty(orderMode), orderMode = 'set'; end
            completed = neuroqc.pipeline.StageModel.normalizeCompleted(completed, orderMode);
            if neuroqc.pipeline.StageModel.isDone(completed, 'run_ica') && ...
                    ~neuroqc.pipeline.StageModel.isDone(completed, 'auto_ic_remove')
                hasIca = isfield(EEG, 'icaweights') && ~isempty(EEG.icaweights);
                if ~hasIca
                    error('NeuroQC:ResumeICA', ...
                        'completedStages includes run_ica but EEG.icaweights is empty');
                end
                assert(isfield(EEG,'icasphere') && size(EEG.icaweights,2)==size(EEG.icasphere,1) && ...
                    all(isfinite(EEG.icaweights),'all') && all(isfinite(EEG.icasphere),'all'),'NeuroQC:ResumeICA','ICA weights/sphere are incompatible');
                if isfield(EEG,'icachansind') && ~isempty(EEG.icachansind), nc=numel(EEG.icachansind); else, nc=EEG.nbchan; end
                assert(size(EEG.icasphere,2)==nc,'NeuroQC:ResumeICA','ICA channels do not match decomposition');
            end
            epoched = (isfield(EEG,'epoch') && ~isempty(EEG.epoch)) || EEG.trials>1;
            if neuroqc.pipeline.StageModel.isDone(completed, 'epoch')
                if ~epoched
                    error('NeuroQC:ResumeEpoch', ...
                        'completedStages includes epoch but EEG is continuous (trials==1)');
                end
            else
                if epoched
                    error('NeuroQC:ResumeContinuous', ...
                        ['EEG is epoched but epoch is not in completedStages. ', ...
                         'Declare epoch as completed, or supply continuous data.']);
                end
            end
        end

        function stages = remaining(completed, space, orderMode)
            % Step types still eligible to appear (dimension-driven, not fullWorkflow-filtered).
            if nargin < 3, orderMode = 'set'; end
            completed = neuroqc.pipeline.StageModel.normalizeCompleted(completed, orderMode);
            dimMap = neuroqc.pipeline.StageModel.dimensionStages();
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            stages = {};
            for i = 1:numel(known)
                stage = known{i};
                if neuroqc.pipeline.StageModel.isDone(completed, stage), continue; end
                owners = {};
                dims = fieldnames(dimMap);
                for j = 1:numel(dims)
                    if any(strcmp(dimMap.(dims{j}), stage)), owners{end+1} = dims{j}; end %#ok<AGROW>
                end
                if isempty(owners)
                    stages{end+1} = stage; %#ok<AGROW>
                    continue;
                end
                open = false;
                for j = 1:numel(owners)
                    d = owners{j};
                    if ~isfield(space, d), open = true; break; end
                    if numel(space.(d)) > 1, open = true; break; end
                    if ~neuroqc.pipeline.StageModel.dimensionCollapsed(d, completed)
                        open = true; break;
                    end
                end
                if open, stages{end+1} = stage; end %#ok<AGROW>
            end
        end

        function tf = dimensionCollapsed(dim, completed)
            dimMap = neuroqc.pipeline.StageModel.dimensionStages();
            stages = dimMap.(dim);
            tf = all(cellfun(@(s) neuroqc.pipeline.StageModel.isDone(completed, s), stages));
        end
    end
end
