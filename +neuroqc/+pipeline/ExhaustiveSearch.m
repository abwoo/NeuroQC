classdef ExhaustiveSearch
    % Enumerate every declared discrete combination. Never prune by score.
    % generate-only: does not execute EEG processing (advice path).
    methods (Static)
        function [pipelines, report] = generate(space, info, contract, opts)
            if nargin < 4, opts = struct(); end
            [space,opts]=neuroqc.pipeline.WorkflowSpec.compile(space,opts);
            opts=neuroqc.pipeline.StageModel.resolveScope(opts);
            if ~isfield(opts, 'completedStages'), opts.completedStages = {}; end
            if ~isfield(opts, 'frozen'), opts.frozen = struct(); end
            if ~isfield(opts, 'orderMode'), opts.orderMode = 'prefix'; end
            if ~isfield(opts, 'stepOrder'), opts.stepOrder = {}; end
            assert(strcmpi(contract.analysisType,'ERP'),'NeuroQC:AnalysisType','This optimizer currently supports ERP contracts only');
            contract.validate(info);
            completed = neuroqc.pipeline.StageModel.normalizeCompleted(opts.completedStages, opts.orderMode);
            neuroqc.pipeline.StageModel.validateStepOrder(opts.stepOrder);
            if ~info.isContinuous
                if ~neuroqc.pipeline.StageModel.isDone(completed, 'epoch')
                    error('NeuroQC:ContinuousRequired', ...
                        'Exhaustive preprocessing requires continuous input unless epoch is in completedStages');
                end
            elseif neuroqc.pipeline.StageModel.isDone(completed, 'epoch')
                error('NeuroQC:ResumeEpoch', ...
                    'completedStages includes epoch but info reports continuous input');
            end
            defaults = neuroqc.pipeline.SearchSpace.defaultERP();
            names = fieldnames(defaults);
            unknown = setdiff(fieldnames(space), names);
            if ~isempty(unknown)
                error('NeuroQC:UnknownDimension', 'Unknown search dimension: %s', strjoin(unknown, ', '));
            end
            for j=1:numel(names)
                if ~isfield(space,names{j}), space.(names{j})=defaults.(names{j}); end
            end
            [space, lockInfo] = neuroqc.pipeline.StageModel.applyCompleted( ...
                space, completed, opts.frozen, opts.orderMode);
            if ~isempty(opts.selectedSteps)
                space.fullWorkflow={true};
                dimMap=neuroqc.pipeline.StageModel.dimensionStages();
                for dim=fieldnames(dimMap)'
                    name=dim{1};
                    if ~strcmp(name,'fullWorkflow') && isempty(intersect(dimMap.(name),opts.selectedSteps))
                        space.(name)=space.(name)(1);
                        lockInfo.collapsedDimensions{end+1}=name;
                    end
                end
            end
            counts = zeros(1,numel(names));
            for j=1:numel(names)
                name=names{j};
                if ~isfield(space,name), space.(name)=defaults.(name); end
                assert(iscell(space.(name)) && ~isempty(space.(name)), ...
                    'NeuroQC:InvalidDimension', '%s must be a nonempty cell array', name);
                counts(j)=numel(space.(name));
            end
            total=prod(counts);
            assert(isfinite(total) && total <= flintmax, 'NeuroQC:SearchSize', 'Search size cannot be represented exactly');
            stepOrder = opts.stepOrder;
            if ischar(stepOrder) || isstring(stepOrder), stepOrder = cellstr(stepOrder); end
            if ~isempty(stepOrder)
                stepOrder = cellfun(@(x) lower(char(x)), stepOrder(:)', 'UniformOutput', false);
            end
            report=struct('mode','exhaustive','totalCombinations',total, ...
                'validPipelines',0,'invalidCombinations',0,'duplicateCombinations',0, ...
                'rejections',struct('combination',{},'reason',{}), ...
                'completedStages',{completed}, ...
                'collapsedDimensions',{lockInfo.collapsedDimensions}, ...
                'selectedSteps',{opts.selectedSteps}, ...
                'orderMode',opts.orderMode, ...
                'stepOrder',{stepOrder},'searchOrder',logical(opts.searchOrder), ...
                'parameterCombinations',total,'enumeratedOrders',0,'rejectedOrderCombinations',0);
            if isfield(opts,'stepModes'), report.stepModes=opts.stepModes; end
            report.fixedParameters=opts.frozen;
            report.fixedPositions=opts.fixedPositions;
            % Preflight budget bound over the full grid, before enumeration.
            report.budget=neuroqc.pipeline.ExhaustiveSearch.estimateBudget(total,opts);
            sampled=opts.maxPipelines>0 && opts.maxPipelines<total;
            if sampled
                sampleMask=neuroqc.pipeline.ExhaustiveSearch.sampleIndices(total,opts.maxPipelines);
                sampleMode='deterministic_hash_topN';
            else
                sampleMask=true(total,1); sampleMode='off';
            end
            report.sampling=struct('enabled',sampled,'requested',opts.maxPipelines, ...
                'kept',sum(sampleMask),'mode',sampleMode);
            buildOrder=stepOrder; if opts.searchOrder, buildOrder={}; end
            if opts.searchOrder
                assert(~isempty(opts.selectedSteps),'NeuroQC:ScopeRequired','Order search requires selectedSteps');
                assert(isempty(setdiff(stepOrder,opts.selectedSteps)),'NeuroQC:StepDependency','Pinned order must refer only to selected steps');
            end
            pipelines=neuroqc.pipeline.Pipeline.empty();
            seen=containers.Map('KeyType','char','ValueType','logical');
            orderCache=containers.Map('KeyType','char','ValueType','any');
            for k=1:total
                if ~sampleMask(k), continue; end
                ix=k-1; candidate=struct();
                for j=1:numel(names)
                    candidate.(names{j})=space.(names{j}){mod(ix,counts(j))+1};
                    ix=floor(ix/counts(j));
                end
                [p,reason]=neuroqc.pipeline.ExhaustiveSearch.build( ...
                    candidate,info,contract,k,completed,buildOrder,opts.selectedSteps,opts.searchOrder);
                if ~isempty(reason)
                    report.invalidCombinations=report.invalidCombinations+1;
                    report.rejections(end+1)=struct('combination',k,'reason',reason);
                    continue;
                end
                orders={1:numel(p.steps)};
                if opts.searchOrder
                    orderKey=strjoin({p.steps.type},'|');
                    if isKey(orderCache,orderKey), orders=orderCache(orderKey);
                    else
                        orders=neuroqc.pipeline.OrderSearch.enumerate({p.steps.type},info,completed,stepOrder,opts.maxOrders,opts.fixedPositions);
                        orderCache(orderKey)=orders;
                    end
                end
                report.enumeratedOrders=report.enumeratedOrders+numel(orders);
                if isempty(orders)
                    report.rejectedOrderCombinations=report.rejectedOrderCombinations+1;
                    report.rejections(end+1)=struct('combination',k,'reason','no_legal_order');
                end
                for oi=1:numel(orders)
                    variant=p; variant.steps=p.steps(orders{oi});
                    if opts.searchOrder, variant.id=sprintf('E%06d_O%06d',k,oi); end
                    variant.metadata.actualOrder={variant.steps.type};
                    variant.metadata.pinnedOrder=stepOrder;
                    % Value-level state is order-dependent (Nyquist at
                    % execution position, bad-channel index staleness);
                    % reject individual orders, not the whole combination.
                    [okOrder,ordReason]=neuroqc.pipeline.StageModel.validateOrderState(variant.steps,info);
                    if ~okOrder
                        report.rejectedOrderCombinations=report.rejectedOrderCombinations+1;
                        report.rejections(end+1)=struct('combination',k,'reason',ordReason);
                        continue;
                    end
                    key=variant.fingerprint();
                    if isKey(seen,key)
                        report.duplicateCombinations=report.duplicateCombinations+1; continue;
                    end
                    seen(key)=true;
                    pipelines(end+1)=variant; %#ok<AGROW>
                end
            end

            report.validPipelines=numel(pipelines);
            report.enumerationComplete=true;
        end
        function b=estimateBudget(total,opts)
            % Preflight bound for the full grid BEFORE enumeration.
            % Bounds, not measurements; assumptions are labeled in the
            % report: one recipe .m ~2KB, ~120s evaluation per pipeline,
            % orders per combination <= maxOrders (searchOrder) else 1.
            % verdict follows the ALGORITHMS 5.4 scale table (<1e3 ok,
            % <1e4 caution, >=1e4 exceeds) on the effective estimate.
            if opts.searchOrder, ordersBound=opts.maxOrders; else, ordersBound=1; end
            upper=total*ordersBound;
            effective=upper;
            if isfield(opts,'maxPipelines') && opts.maxPipelines>0 && opts.maxPipelines<total
                effective=opts.maxPipelines*ordersBound;
            end
            if effective<1e3
                verdict='ok';
            elseif effective<1e4
                verdict='caution';
            else
                verdict='exceeds';
            end
            b=struct('gridCombinations',total, ...
                'ordersPerCombinationBound',ordersBound, ...
                'upperBoundPipelines',upper, ...
                'effectiveEstimatePipelines',effective, ...
                'estimatedRecipeMB',effective*2/1024, ...
                'estimatedEvalHours',effective*120/3600, ...
                'verdict',verdict, ...
                'assumptions','bounds not measurements: 1 recipe .m ~2KB; ~120s evaluation per pipeline; orders bound = maxOrders when searchOrder else 1');
        end
        function mask=sampleIndices(total,keepN)
            % Deterministic top-N subset over odometer indices: rank all
            % indices under a fixed integer multiplicative hash (no RNG,
            % no clock) and keep the first keepN. Same inputs on any
            % machine/run yield the identical subset. Hash collisions tie-
            % break by index so ordering stays total.
            assert(keepN>=1 && keepN==fix(keepN),'NeuroQC:Config','keepN must be a positive integer');
            ix=(1:total)';
            h=mod(double(ix)*2654435761,4294967296);
            [~,ord]=sortrows([h,ix],[1,2]);
            mask=false(total,1);
            mask(ix(ord(1:keepN)))=true;
        end

        function [p,reason] = build(c,info,contract,k,completed,stepOrder,selectedSteps,deferOrder)
            if nargin<8, deferOrder=false; end
            if nargin < 7, selectedSteps={}; end
            if nargin < 5, completed = {}; end
            if nargin < 6, stepOrder = {}; end
            completed = neuroqc.pipeline.StageModel.normalizeCompleted(completed, 'set');
            if ischar(stepOrder) || isstring(stepOrder), stepOrder = cellstr(stepOrder); end
            p=neuroqc.pipeline.Pipeline(sprintf('E%06d',k),'exhaustive');
            reason='';
            skipped={};
            if ~isempty(selectedSteps), skipped=setdiff(neuroqc.pipeline.StageModel.canonicalOrder(),selectedSteps); end
            declaredCompleted=completed;
            completed=union(completed,skipped,'stable');
            % Values of frozen dimensions cannot reject a remaining pipeline.
            if stageDone(completed,'resample'), c.resample=[]; end
            if stageDone(completed,'filter'), c.highpass=0.1; c.lowpass=min(30,info.samplingRate/4); end
            if stageDone(completed,'notch'), c.lineNoise=false; end
            if stageDone(completed,'reref'), c.reference='original'; end
            if stageDone(completed,'badchannel'), c.badChannel='kurtosis'; end
            if stageDone(completed,'restore_channels') && stageDone(completed,'interpolate'), c.interpolate=false; end
            if stageDone(completed,'auto_ic_remove') && stageDone(completed,'run_ica'), c.ica=false; end
            if stageDone(completed,'epoch'), c.epochWindow=[]; end
            if stageDone(completed,'baseline'), c.baselineWindow=[]; end
            if stageDone(completed,'artifact_reject'), c.artifactMethod='peak_to_peak'; c.artifactThresholdUv=100; end
            fs=c.resample;
            if isempty(fs), fs=info.samplingRate; end
            if ~isscalar(fs) || ~isfinite(fs) || fs<=0 || fs>info.samplingRate
                reason='invalid_sampling_rate_or_upsampling'; return;
            end
            % Nyquist checks are position-dependent and run per order in
            % generate() via StageModel.validateOrderState; build() keeps
            % only order-independent band sanity (0<hp<lp, finite scalars).
            if ~stageDone(completed,'filter') && (~isscalar(c.highpass) || ~isscalar(c.lowpass) || ...
                    ~isfinite(c.highpass) || ~isfinite(c.lowpass) || ...
                    c.highpass<=0 || c.highpass>=c.lowpass)
                reason='invalid_filter_band'; return;
            end
            if ~any(strcmp(c.reference,{'original','average','mastoid'}))
                reason='unsupported_reference'; return;
            end
            labels=upper(string(info.channelLabels));
            refs={};
            if strcmp(c.reference,'mastoid')
                pairs={{'A1','A2'},{'M1','M2'},{'TP9','TP10'}};
                for j=1:numel(pairs)
                    if all(ismember(pairs{j},labels)), refs=pairs{j}; break; end
                end
                if isempty(refs), reason='missing_mastoid_pair'; return; end
            end
            if ~any(strcmp(c.badChannel,{'none','kurtosis','probability','spectrum'}))
                reason='unsupported_bad_channel_method_use_kurtosis_probability_spectrum'; return;
            end
            if ~stageDone(completed,'badchannel') && (~isnumeric(c.badChannelThreshold) || ~isscalar(c.badChannelThreshold) || ~isfinite(c.badChannelThreshold) || c.badChannelThreshold<=0)
                reason='invalid_bad_channel_threshold'; return;
            end
            if ~isscalar(c.lineNoise) || ~any(c.lineNoise==[0 50 60])
                reason='lineNoise_must_be_0_50_or_60'; return;
            end
            if ~isscalar(c.ica) || ~isscalar(c.interpolate)
                reason='invalid_boolean_dimension'; return;
            end
            if c.ica && ~stageDone(completed,'run_ica') && ~exist('pop_runica','file') && ~exist('runica','file')
                reason='ICA_dependency_missing'; return;
            end
            if c.interpolate && ~exist('pop_interp','file')
                reason='spherical_interpolation_dependency_missing'; return;
            end
            if c.interpolate && strcmp(c.badChannel,'none') && ~stageDone(completed,'badchannel')
                reason='interpolation_requires_detection'; return;
            end
            if ~any(strcmp(c.artifactMethod,{'peak_to_peak','threshold'}))
                reason='unsupported_artifact_method'; return;
            end
            if ~isscalar(c.artifactThresholdUv) || ~isfinite(c.artifactThresholdUv) || c.artifactThresholdUv<=0
                reason='invalid_artifact_threshold'; return;
            end
            if strcmp(c.artifactMethod,'peak_to_peak') && ~stageDone(completed,'artifact_reject')
                reason='peak_to_peak_not_supported_in_recipe_use_native_EEGLAB_threshold_or_manual_ERPLAB'; return;
            end
            ew=c.epochWindow; bw=c.baselineWindow;
            if isempty(ew), ew=[contract.epoch.start contract.epoch.end]; end
            if isempty(bw), bw=[contract.baseline.start contract.baseline.end]; end
            if numel(ew)~=2 || numel(bw)~=2 || any(~isfinite([ew(:);bw(:)])) || ...
                    ew(1)>=ew(2) || bw(1)>=bw(2) || bw(1)<ew(1) || bw(2)>ew(2)
                reason='invalid_epoch_or_baseline_window'; return;
            end
            finalLabels=labels;
            if c.fullWorkflow && c.interpolate && ~stageDone(completed,'restore_channels') && ...
                    isfield(info.inspection,'neuroqcRestoreLabels')
                finalLabels=upper(string(info.inspection.neuroqcRestoreLabels));
            end
            for j=1:numel(contract.components)
                comp=contract.components(j);
                if comp.window(1)<ew(1) || comp.window(2)>ew(2) || ...
                        ~all(ismember(upper(string(comp.roi)),finalLabels))
                    reason='component_window_or_ROI_unavailable'; return;
                end
            end
            if c.fullWorkflow
                % srate-gated fullWorkflow steps (reject_continuous >42Hz,
                % ICLabel >=100Hz) are checked per order in validateOrderState.
                needed={'pop_runica','pop_subcomp','iclabel','pop_interp','pop_rejcont'};
                owners={'run_ica','auto_ic_remove','auto_ic_remove','restore_channels','reject_continuous'};
                for j=1:numel(needed)
                    if ~stageDone(completed,owners{j}) && ~exist(needed{j},'file'), reason=['dependency_missing_' needed{j}]; return; end
                end
                if (~c.ica && ~stageDone(completed,'run_ica')) || (strcmp(c.badChannel,'none') && ~stageDone(completed,'badchannel'))
                    reason='full_workflow_requires_bad_detection_and_ICA'; return;
                end
                if ~any(strcmp(c.icPolicy,{'conservative','moderate'}))
                    reason='unsupported_IC_policy'; return;
                end
                if ~isscalar(c.continuousThresholdDb) || ~isfinite(c.continuousThresholdDb) || c.continuousThresholdDb<=0
                    reason='invalid_continuous_threshold'; return;
                end
            end

            % Collect pending step specs, then apply optional arbitrary order.
            specs = {};
            % Prep / setup steps (EEGLAB dialogs) — only when dim value is truthy.
            if ~stageDone(completed, 'chanloc') && stepOn(c.chanloc)
                specs{end+1} = {'chanloc', stepParams(c.chanloc)};
            end
            if ~stageDone(completed, 'select_data') && stepOn(c.selectData)
                specs{end+1} = {'select_data', stepParams(c.selectData)};
            end
            if ~stageDone(completed, 'select_events') && stepOn(c.selectEvents)
                specs{end+1} = {'select_events', stepParams(c.selectEvents)};
            end
            if ~stageDone(completed, 'edit_events') && stepOn(c.editEvents)
                specs{end+1} = {'edit_events', stepParams(c.editEvents)};
            end
            if ~stageDone(completed, 'resample') && fs~=info.samplingRate
                specs{end+1} = {'resample', struct('fs',fs)};
            end
            if ~stageDone(completed, 'notch') && c.lineNoise
                specs{end+1} = {'notch', struct('frequency',c.lineNoise)};
            end
            if ~stageDone(completed, 'filter')
                specs{end+1} = {'filter', struct('highpass',c.highpass,'lowpass',c.lowpass)};
            end
            if ~strcmp(c.badChannel,'none')
                if ~stageDone(completed, 'badchannel')
                    specs{end+1} = {'badchannel', struct('method',c.badChannel,'threshold',c.badChannelThreshold)};
                end
                if c.fullWorkflow && ~stageDone(completed, 'remove_bad')
                    specs{end+1} = {'remove_bad', struct()};
                end
            end
            if (~c.fullWorkflow || ~isempty(selectedSteps)) && c.interpolate && ~stageDone(completed, 'interpolate')
                specs{end+1} = {'interpolate', struct('method','spherical')};
            end
            if c.fullWorkflow && ~stageDone(completed, 'reject_continuous')
                specs{end+1} = {'reject_continuous', struct('thresholdDb',c.continuousThresholdDb)};
            end
            if ~stageDone(completed, 'reref')
                specs{end+1} = {'reref', struct('mode',c.reference,'refChannels',{refs})};
            end
            if c.ica
                if ~stageDone(completed, 'run_ica')
                    specs{end+1} = {'run_ica', struct('method','runica')};
                end
                if c.fullWorkflow && ~stageDone(completed, 'auto_ic_remove')
                    specs{end+1} = {'auto_ic_remove', struct('policy',c.icPolicy)};
                end
            end
            if c.fullWorkflow && c.interpolate && ~stageDone(completed, 'restore_channels')
                specs{end+1} = {'restore_channels', struct()};
            end
            if ~stageDone(completed, 'epoch')
                specs{end+1} = {'epoch', struct('window',ew)};
            end
            if ~stageDone(completed, 'baseline')
                specs{end+1} = {'baseline', struct('window',bw)};
            end
            if ~stageDone(completed, 'artifact_reject')
                specs{end+1} = {'artifact_reject', struct('thresholdUv',c.artifactThresholdUv,'method',c.artifactMethod)};
            end
            if stepOn(c.autoRejectThreshold) && ~stageDone(completed, 'auto_reject')
                specs{end+1} = {'auto_reject', stepParams(c.autoRejectThreshold)};
            end
            if stepOn(c.rejectJointprob) && ~stageDone(completed, 'reject_jointprob')
                specs{end+1} = {'reject_jointprob', stepParams(c.rejectJointprob)};
            end
            if stepOn(c.rejectKurt) && ~stageDone(completed, 'reject_kurtosis')
                specs{end+1} = {'reject_kurtosis', stepParams(c.rejectKurt)};
            end

            if ~isempty(selectedSteps)
                specs=specs(cellfun(@(v) ismember(v{1},selectedSteps),specs));
                actualTypes=cellfun(@(v) v{1},specs,'UniformOutput',false);
                if ~isempty(setdiff(selectedSteps,actualTypes))
                    % Selected step(s) produced no executable step for this
                    % discrete value (e.g. resample keep-original, interpolate=false).
                    % Never emit an empty recipe that only runs prepare().
                    reason='no_op_selected_step_value'; return;
                end
            end
            specs = neuroqc.pipeline.StageModel.orderPending(specs, stepOrder);
            if ~deferOrder
                neuroqc.pipeline.StageModel.validateTransition(cellfun(@(v) v{1},specs,'UniformOutput',false),info,declaredCompleted);
            end
            for j = 1:numel(specs)
                p = p.addStep(specs{j}{1}, specs{j}{2});
            end
            p.metadata.candidate=c;
            p.metadata.completedStages=declaredCompleted;
            p.metadata.selectedSteps=selectedSteps;
            p.metadata.stepOrder=stepOrder;
            p.metadata.featurePreservation='NOT_VALIDATED';
        end
    end
end

function tf = stageDone(completed, stage)
    tf = any(strcmpi(completed, stage));
end

function tf = stepOn(v)
    % Dimension value enables a setup/rejection step: false/[] off; true/struct on.
    if islogical(v) && isscalar(v)
        tf = v;
    elseif isnumeric(v) && isscalar(v)
        tf = v ~= 0;
    elseif isstruct(v)
        tf = true;
    elseif ischar(v) || isstring(v)
        tf = ~isempty(v) && ~strcmpi(char(v), 'off') && ~strcmpi(char(v), 'false');
    else
        tf = ~isempty(v);
    end
end

function p = stepParams(v)
    if isstruct(v)
        p = v;
    else
        p = struct();
    end
end
