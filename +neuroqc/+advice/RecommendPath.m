classdef RecommendPath
    % RecommendPath - Primary NeuroQC entry: generate recipes, rank with
    % external QC (or leave unranked), export EEGLAB scripts.
    % NEVER executes EEG processing inside NeuroQC.

    methods (Static)
        function out = run(source, contract, space, opts)
            if nargin < 4, opts = struct(); end
            required = {'outputDir'};
            for k = 1:numel(required)
                assert(isfield(opts, required{k}), ...
                    'NeuroQC:Config', 'Missing option %s', required{k});
            end
            if isfolder(opts.outputDir)
                entries = dir(opts.outputDir);
                names = {entries.name};
                names = names(~ismember(names, {'.', '..'}));
                assert(isempty(names), ...
                    'NeuroQC:OutputExists', ...
                    'Output directory exists and is not empty: %s', opts.outputDir);
            end
            if isfield(opts, 'lockSpec') && isstruct(opts.lockSpec) && ...
                    isscalar(opts.lockSpec) && ~isempty(fieldnames(opts.lockSpec))
                % Value locks: collapse space here so API callers get the same
                % enforcement the GUI applies via effectiveSpace(); merge into
                % frozen so search.json records them under fixedParameters.
                [space, locked] = neuroqc.pipeline.StageModel.applyLockSpec(space, opts.lockSpec);
                if ~isfield(opts, 'frozen'), opts.frozen = struct(); end
                ln = fieldnames(locked);
                for k = 1:numel(ln)
                    opts.frozen.(ln{k}) = locked.(ln{k});
                end
            end
            [space,opts]=neuroqc.pipeline.WorkflowSpec.compile(space,opts);
            opts=neuroqc.pipeline.StageModel.resolveScope(opts);
            assert(~isempty(opts.selectedSteps),'NeuroQC:ScopeRequired','Select one or more next steps explicitly (selectedSteps)');
            if ~isfield(opts, 'frozen'), opts.frozen = struct(); end
            if ~isfield(opts, 'stepOrder'), opts.stepOrder = {}; end
            if ~isfield(opts, 'goalProfile'), opts.goalProfile = []; end
            if ~isfield(opts, 'dataUnit'), opts.dataUnit = ''; end

            completed = neuroqc.pipeline.StageModel.normalizeCompleted( ...
                opts.completedStages, opts.orderMode);
            opts.completedStages = completed;

            EEG = neuroqc.advice.RecommendPath.loadSource(source);
            if ~isempty(opts.dataUnit)
                % Unit is recorded for recipe export only — no conversion/processing.
                assert(any(strcmp(opts.dataUnit, {'V', 'uV'})), ...
                    'NeuroQC:DataUnitRequired', 'dataUnit must be V or uV');
            end
            neuroqc.pipeline.StageModel.validateEEG(EEG, completed);

            inputHash = neuroqc.utils.hashEEG(EEG);
            info = neuroqc.io.EEGImporter.fromEEG(EEG);
            info.inspection.hasERPLABEventList=isfield(EEG,'EVENTLIST') && isfield(EEG.EVENTLIST,'bdf');
            info=neuroqc.advice.RecommendPath.prepareInfo(info,opts);
            if any(ismember(opts.selectedSteps,{'epoch','baseline','artifact_reject','auto_reject','reject_jointprob','reject_kurtosis'}))
                assert(isfield(opts,'trialSelection'),'NeuroQC:FormalRuleRequired','Supply trialSelection: existing, explicit indices/ranges, or all only if already screened');
            end
            assert(any(strcmp(opts.dataUnit,{'V','uV'})),'NeuroQC:DataUnitRequired','Declare dataUnit V or uV');
            if isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && ...
                    isfield(EEG.etc.neuroqc, 'restoreLocations')
                info.inspection.neuroqcRestoreLabels = {EEG.etc.neuroqc.restoreLocations.labels};
            end

            genOpts = struct( ...
                'completedStages', {completed}, ...
                'frozen', opts.frozen, ...
                'orderMode', opts.orderMode, ...
                'stepOrder', {opts.stepOrder}, 'selectedSteps',{opts.selectedSteps}, ...
                'searchOrder',opts.searchOrder,'maxOrders',opts.maxOrders,'fixedPositions',opts.fixedPositions);
            if isfield(opts,'stepModes'), genOpts.stepModes=opts.stepModes; end
            [pipelines, report] = neuroqc.pipeline.ExhaustiveSearch.generate( ...
                space, info, contract, genOpts);
            assert(~isempty(pipelines), 'NeuroQC:NoValidPipelines', ...
                'All declared combinations invalid: %s', ...
                strjoin(unique({report.rejections.reason}), '; '));

            if ~isfolder(opts.outputDir), mkdir(opts.outputDir); end
            recipeDir = fullfile(opts.outputDir, 'recipes');
            exportOpts = opts; exportOpts.inputHash=inputHash;
            neuroqc.advice.EEGLABRecipe.writeAll(recipeDir, pipelines, contract, exportOpts);

            environment = struct( ...
                'matlab', version, ...
                'neuroqc', neuroqc.NeuroQC.version(), ...
                'mode', 'recommend', ...
                'completedStages', {completed}, ...
                'orderMode', opts.orderMode, ...
                'stepOrder', {opts.stepOrder});

            out = struct();
            out.mode = 'recommend';
            out.recipeOptions=opts;
            out.recipeContract=neuroqc.advice.RecommendPath.contractSnapshot(contract);
            out.search = report;
            out.pipelines = pipelines;
            out.recipesDir = recipeDir;
            out.environment = environment;
            out.inputHash = inputHash;
            out.completedStages = completed;
            out.orderMode = opts.orderMode;
            out.stepOrder = opts.stepOrder;
            out.goalProfile = opts.goalProfile;
            out.status = 'NEEDS_EXTERNAL_QC';
            out.results = struct('id', {}, 'pipeline', {}, 'run', {}, 'quality', {}, 'status', {});
            out.frontIdx = [];
            out.rejectedIdx = [];
            out.constraintReasons = {};
            out.recommendedIdx = [];
            out.goalRecommendation = struct();
            out.outputDir = opts.outputDir;
            out.exportedRecipes = arrayfun(@(p) fullfile(recipeDir, ...
                sprintf('recipe_%s.m', p.id)), pipelines, 'UniformOutput', false);

            % Optional external QC ranking (user measured metrics in EEGLAB)
            if isfield(opts, 'externalQC') && ~isempty(opts.externalQC)
                out = neuroqc.advice.RecommendPath.applyExternalQC(out, ...
                    opts.externalQC, contract, opts.goalProfile);
            end

            neuroqc.advice.RecommendPath.writeSummary(out, opts.outputDir, contract, space, opts);
            fprintf('RECOMMEND_STATUS=%s pipelines=%d recipes=%s\n', ...
                out.status, numel(pipelines), recipeDir);
        end

        function out = applyExternalQC(out, externalQC, contract, goalProfile)
            out=neuroqc.advice.RecommendPath.bindEvaluationContract(out,contract);
            if ischar(externalQC) || isstring(externalQC)
                results = neuroqc.advice.ExternalQC.fromFile(char(externalQC), out.pipelines);
            else
                results = neuroqc.advice.ExternalQC.fromStruct(externalQC, out.pipelines);
            end
            assert(~isempty(results), 'NeuroQC:ExternalQC', ...
                'No QC rows matched generated pipelines');
            assert(numel(results) == numel(out.pipelines), 'NeuroQC:ExternalQC', ...
                'QC results (%d) must align 1:1 with pipelines (%d)', ...
                numel(results), numel(out.pipelines));
            for k = 1:numel(results)
                assert(strcmp(results(k).id, out.pipelines(k).id), ...
                    'NeuroQC:ExternalQC', 'QC results misaligned with pipelines at %d', k);
            end
            limits = struct();
            if ~isempty(contract) && isprop(contract, 'qualityThresholds')
                limits = contract.qualityThresholds;
            end
            % Front must cover every dimension the active profile ranks on,
            % otherwise a profile objective outside the fixed 5-D front can
            % never win (Layer-3 would only see Layer-2 survivors).
            prof = neuroqc.optimize.GoalProfile.resolve(goalProfile);
            objs = prof.enabledObjectives();
            extraDims = cell(1, numel(objs));
            for k = 1:numel(objs)
                extraDims{k} = struct('name', objs(k).metricKey, 'sense', objs(k).sense);
            end
            [front, rejected, reasons, skipped] = neuroqc.optimize.ParetoFront.select(results, limits, extraDims);
            goalRec = neuroqc.optimize.GoalRanker.rank(results, front, prof);
            out.results = results;
            out.frontIdx = front;
            out.rejectedIdx = rejected;
            out.constraintReasons = reasons;
            out.recommendedIdx = goalRec.bestOverall;
            out.goalRecommendation = goalRec;
            % Scope knobs this QC source cannot evaluate (e.g. no rank
            % column). Surfaced in the GUI instead of staying silently inert.
            if isempty(skipped)
                if isfield(out, 'constraintSkipped'), out = rmfield(out, 'constraintSkipped'); end
            else
                out.constraintSkipped = skipped;
            end
            if isempty(front)
                out.status = 'NO_FEASIBLE_SOLUTION';
            elseif ~isempty(goalRec.status) && ~strcmp(goalRec.status, 'REVIEW')
                out.status = goalRec.status;
            else
                out.status = 'REVIEW';
            end
            out.metricScope = 'external_qc_imported_not_revalidated';
        end

        function s=contractSnapshot(contract)
            s=contract.toStruct();
            % Descriptive metadata must not invalidate otherwise identical goals.
            % qualityThresholds is excluded too: it only re-ranks evaluated
            % candidates (Re-rank), so it must never invalidate receipts or
            % force a regeneration.
            s=rmfield(s,{'createdAt','notes','subject','qualityThresholds'});
        end

        function out=bindEvaluationContract(out,contract)
            s=neuroqc.advice.RecommendPath.contractSnapshot(contract);
            if isfield(out,'recipeContract')
                for field={'analysisType','conditions','ignoreEvents','epoch','baseline','channelSelection'}
                    f=field{1};
                    assert(isequaln(s.(f),out.recipeContract.(f)),'NeuroQC:ContractMismatch', ...
                        'Analysis settings changed since recipe generation (%s); generate a fresh session',f);
                end
            end
            if isfield(out,'evaluationContract')
                assert(isequaln(s,out.evaluationContract),'NeuroQC:ContractMismatch', ...
                    'QC goals changed between comparison batches; do not mix metrics from different goals');
            else
                % Components may be supplied at the first Compare, then stay fixed.
                out.evaluationContract=s;
            end
        end

        function info=prepareInfo(info,opts)
            if isfield(opts,'stripRefSuffix') && opts.stripRefSuffix
                info.channelLabels=regexprep(info.channelLabels,'-Ref$','', 'ignorecase');
            end
            if isfield(opts,'includeChannels') && ~isempty(opts.includeChannels)
                assert(all(ismember(upper(string(opts.includeChannels)),upper(string(info.channelLabels)))),'NeuroQC:Channels','Requested channels missing');
                info.channelLabels=cellstr(opts.includeChannels); info.channelCount=numel(info.channelLabels);
            end
        end

        function writeSummary(out, folder, contract, space, opts)
            if ~isfolder(folder), mkdir(folder); end
            recipeIds = {out.pipelines.id};
            steps = cell(1, numel(out.pipelines));
            for k = 1:numel(out.pipelines)
                st = out.pipelines(k).steps;
                steps{k} = {st.type};
            end
            sj = struct();
            sj.mode = 'recommend';
            sj.status = out.status;
            sj.search = out.search;
            sj.recipesDir = out.recipesDir;
            sj.completedStages = out.completedStages;
            sj.orderMode = out.orderMode;
            sj.stepOrder = out.stepOrder;
            sj.candidateIds = recipeIds;
            sj.stepSequence = steps;
            sj.recommendedIdx = out.recommendedIdx;
            sj.frontIdx = out.frontIdx;
            sj.environment = out.environment;
            sj.inputHash = out.inputHash;
            if isfield(out, 'goalRecommendation'), sj.goalRecommendation = out.goalRecommendation; end
            if isfield(out, 'constraintReasons'), sj.constraintReasons = out.constraintReasons; end
            if isfield(out, 'constraintSkipped'), sj.constraintSkipped = out.constraintSkipped; end
            if isfield(out, 'metricScope'), sj.metricScope = out.metricScope; end
            if isfield(out, 'executionMode'), sj.executionMode=out.executionMode; end
            if isfield(out, 'parallelRequested'), sj.parallelRequested=out.parallelRequested; end
            if isfield(out, 'searchCoverage'), sj.searchCoverage=out.searchCoverage; end
            sj.note = ['NeuroQC recommends discrete recipes only. ', ...
                'Run recipes in EEGLAB; import QC metrics to rank.'];
            if isfield(out, 'constraintSkipped') && ~isempty(out.constraintSkipped)
                sj.note = sprintf('%s Not evaluated by this QC source: %s.', ...
                    sj.note, strjoin({out.constraintSkipped.name}, ', '));
            end
            f = fopen(fullfile(folder, 'search.json'), 'w');
            cleanup = onCleanup(@() fclose(f));
            fprintf(f, '%s', jsonencode(sj, 'PrettyPrint', true));

            % comparison.csv — recipe inventory (+ quality when external QC present)
            n = numel(out.pipelines);
            id = recipeIds(:);
            stepSeq = cell(n, 1);
            for k = 1:n
                stepSeq{k} = strjoin({out.pipelines(k).steps.type}, '>');
            end
            onFront = false(n, 1);
            goalScore = nan(n, 1);
            status = repmat({''}, n, 1);
            retention = nan(n, 1);
            reliability = nan(n, 1);
            distortion = nan(n, 1);
            interpRatio = nan(n, 1);
            badRatio = nan(n, 1);
            rankVal = nan(n, 1);
            topoStability = nan(n, 1);
            eventLoss = false(n, 1);
            snr = nan(n, 1);
            baselineSd = nan(n, 1);
            if ~isempty(out.results)
                % results are 1:1 with pipelines (id-aligned) after applyExternalQC
                resToPipe = nan(1, numel(out.results));
                for r = 1:numel(out.results)
                    m = find(strcmp(id, out.results(r).id), 1);
                    if ~isempty(m), resToPipe(r) = m; end
                end
                for k = 1:n
                    match = find(strcmp({out.results.id}, id{k}), 1);
                    if isempty(match), continue; end
                    q = out.results(match).quality;
                    status{k} = out.results(match).status;
                    if isfield(q, 'retention'), retention(k) = q.retention; end
                    if isfield(q, 'reliability'), reliability(k) = q.reliability; end
                    if isfield(q, 'waveformDistortion'), distortion(k) = q.waveformDistortion; end
                    if isfield(q, 'interpRatio'), interpRatio(k) = q.interpRatio; end
                    if isfield(q, 'badRatio'), badRatio(k) = q.badRatio; end
                    if isfield(q, 'rank'), rankVal(k) = q.rank; end
                    if isfield(q, 'topoStability'), topoStability(k) = q.topoStability; end
                    if isfield(q, 'eventLoss'), eventLoss(k) = logical(q.eventLoss); end
                    if isfield(q, 'snr'), snr(k) = q.snr; end
                    if isfield(q, 'baselineSd'), baselineSd(k) = q.baselineSd; end
                end
                if ~isempty(out.frontIdx)
                    for fi = out.frontIdx(:)'
                        pipeIdx = resToPipe(fi);
                        if ~isnan(pipeIdx) && pipeIdx <= n, onFront(pipeIdx) = true; end
                    end
                end
                if isfield(out.goalRecommendation, 'scores') && ~isempty(out.goalRecommendation.scores)
                    g = out.goalRecommendation;
                    for k = 1:numel(g.frontIdx)
                        pipeIdx = resToPipe(g.frontIdx(k));
                        if ~isnan(pipeIdx) && pipeIdx <= n, goalScore(pipeIdx) = g.scores(k); end
                    end
                end
            else
                status(:) = {'NEEDS_QC'};
            end
            % Why a candidate lost: hard-constraint reason, else execution failure.
            constraintReason = repmat({''}, n, 1);
            failMsg = repmat({''}, n, 1);
            if isfield(out, 'rejectedIdx') && isfield(out, 'constraintReasons') && ~isempty(out.results)
                for k = 1:min(numel(out.rejectedIdx), numel(out.constraintReasons))
                    ri = out.rejectedIdx(k);
                    if ri < 1 || ri > numel(out.results), continue; end
                    m = find(strcmp(id, out.results(ri).id), 1);
                    if isempty(m), continue; end
                    txt = out.constraintReasons{k};
                    if iscell(txt), txt = strjoin(txt, '; '); end
                    constraintReason{m} = char(txt);
                end
            end
            if isfield(out, 'trialFailures')
                for k = 1:numel(out.trialFailures)
                    m = find(strcmp(id, out.trialFailures(k).id), 1);
                    if isempty(m), continue; end
                    failMsg{m} = char(out.trialFailures(k).message);
                end
            end
            T = table(id, stepSeq, onFront, goalScore, status, retention, reliability, ...
                distortion, interpRatio, badRatio, rankVal, topoStability, eventLoss, snr, baselineSd, ...
                constraintReason, failMsg, ...
                'VariableNames', {'id', 'stepSequence', 'front', 'goalScore', ...
                'status', 'retention', 'reliability', 'waveformDistortion', ...
                'interpRatio', 'badRatio', 'rank', 'topoStability', 'eventLoss', ...
                'snr', 'baselineSd', 'constraintReason', 'failMsg'});
            writetable(T, fullfile(folder, 'comparison.csv'));

            % Persist workspace bundle for resume/import without re-processing
            pipelines = out.pipelines; %#ok<NASGU>
            search = out.search; %#ok<NASGU>
            environment = out.environment; %#ok<NASGU>
            inputHash = out.inputHash; %#ok<NASGU>
            if ~isempty(contract), contractOut = contract; else, contractOut = []; end %#ok<NASGU>
            if ~isempty(space), spaceOut = space; else, spaceOut = struct(); end %#ok<NASGU>
            optsOut = opts; %#ok<NASGU>
            save(fullfile(folder, 'recommend_bundle.mat'), ...
                'pipelines', 'search', 'environment', 'inputHash', ...
                'contractOut', 'spaceOut', 'optsOut', '-v7.3');
        end

        function EEG = loadSource(source)
            if ischar(source) || isstring(source)
                [folder, name, ext] = fileparts(char(source));
                EEG = pop_loadset('filename', [name ext], 'filepath', folder);
            else
                EEG = source;
            end
            assert(isstruct(EEG) && isfield(EEG, 'srate'), ...
                'NeuroQC:Source', 'Invalid EEG source');
            assert(all(isfinite(EEG.data(:))), 'NeuroQC:NonFinite', ...
                'Input contains NaN/Inf');
        end
    end
end
