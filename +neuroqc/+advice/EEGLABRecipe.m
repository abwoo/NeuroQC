classdef EEGLABRecipe
    % EEGLABRecipe - Export pipelines as plain EEGLAB pop_* scripts.
    % No NeuroQC runner required; the user executes the script in EEGLAB.

    methods (Static)
        function script = fromPipeline(pipeline, contract, opts)
            if nargin < 3, opts = struct(); end
            L = {sprintf('function EEG = recipe_%s(EEG)',pipeline.id), ...
                '% EEGLAB candidate: pass the original handoff EEG; output is a separate copy.'};
            if isfield(opts,'preHandoffCommands') && ~isempty(opts.preHandoffCommands)
                cmds = cellstr(opts.preHandoffCommands);
                for ci = 1:numel(cmds)
                    line = strrep(char(cmds{ci}), '%', '%%');
                    L{end+1} = sprintf('%% pre-handoff (already applied in the input EEG; do NOT re-run): %s', line); %#ok<AGROW>
                end
            end
            if isfield(opts,'inputHash')
                L{end+1}=sprintf("assert(strcmp(neuroqc.utils.hashEEG(EEG),'%s'),'NeuroQC:SourceMismatch','Use the original handoff dataset, not another candidate output');",opts.inputHash);
            end
            safe=struct();
            for field={'dataUnit','trialSelection','stripRefSuffix','includeChannels','lookupFile','cropSeconds','pendingBadChannels','originalChanlocs'}
                if isfield(opts,field{1}), safe.(field{1})=opts.(field{1}); end
            end
            codes={};
            for i=1:numel(contract.conditions), codes=[codes contract.conditions(i).events]; end
            safe.codes=codes;
            if any(strcmp({pipeline.steps.type},'epoch')), assert(~isempty(codes),'NeuroQC:NoTrigger','Contract has no epoch triggers'); end
            safe.trialSteps=isfield(opts,'trialSelection') || any(ismember({pipeline.steps.type},{'epoch','baseline','artifact_reject','auto_reject','reject_jointprob','reject_kurtosis'}));
            encoded=strrep(jsonencode(safe),char(39),[char(39) char(39)]);
            L{end+1}=sprintf('opts=jsondecode(''%s'');',encoded);
            L{end+1}='EEG=neuroqc.advice.RecipeInput.prepare(EEG,opts);';
            L{end+1}='badIdx=[];';
            L{end+1}='if isfield(EEG.etc.neuroqc,''badChannels''), badIdx=EEG.etc.neuroqc.badChannels; end';
            L{end+1}=sprintf('EEG.etc.neuroqc.recipeId=''%s'';',pipeline.id);
            for k = 1:numel(pipeline.steps)
                step = pipeline.steps(k);
                L{end+1} = ''; %#ok<AGROW>
                L{end+1} = sprintf('%% step %d: %s', k, step.type); %#ok<AGROW>
                lines = neuroqc.advice.EEGLABRecipe.stepLines(step, contract, opts);
                for j = 1:numel(lines)
                    L{end+1} = lines{j}; %#ok<AGROW>
                end
                L{end+1} = 'EEG = eeg_checkset(EEG);'; %#ok<AGROW>
            end
            L{end+1} = '';
            L{end+1} = "EEG.setname = [EEG.setname '_REVIEW'];";
            L{end+1} = "EEG.etc.neuroqc.status = 'REVIEW';";
            L{end+1} = '% Inspect continuous data, ICs, ERP, and rejected trials in EEGLAB before use.';
            L{end+1} = 'end';
            for k = 1:numel(L)
                L{k} = char(string(L{k}));
            end
            script = strjoin(L, newline);
        end

        function writeRecipe(folder, pipeline, contract, opts)
            if nargin < 4, opts = struct(); end
            if ~isfolder(folder), mkdir(folder); end
            name = sprintf('recipe_%s.m', pipeline.id);
            fid = fopen(fullfile(folder, name), 'w');
            assert(fid > 0, 'NeuroQC:Export', 'Cannot write %s', name);
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid, '%s\n', neuroqc.advice.EEGLABRecipe.fromPipeline(pipeline, contract, opts));
        end

        function writeAll(folder, pipelines, contract, opts)
            if nargin < 4, opts = struct(); end
            if ~isfolder(folder), mkdir(folder); end
            for k = 1:numel(pipelines)
                neuroqc.advice.EEGLABRecipe.writeRecipe(folder, pipelines(k), contract, opts);
            end
            idx = {pipelines.id};
            names = cellfun(@(id) sprintf('recipe_%s.m', id), idx, 'UniformOutput', false);
            f = fopen(fullfile(folder, 'recipes_index.m'), 'w');
            cleanup = onCleanup(@() fclose(f));
            fprintf(f, 'function list = recipes_index()\n');
            fprintf(f, '%% Candidate recipe scripts exported by NeuroQC (EEGLAB-side execution).\n');
            fprintf(f, 'list = {...\n');
            for k = 1:numel(names)
                fprintf(f, '  ''%s''; ...\n', names{k});
            end
            fprintf(f, '};\nend\n');
        end

        function lines = stepLines(step, contract, opts)
            if nargin < 3, opts = struct(); end
            lines = {};
            p = step.parameters;
            switch lower(step.type)
                case 'chanloc'
                    lines{end+1} = neuroqc.advice.EEGLABRecipe.capturedCall(p,'pop_chanedit');
                    lines{end+1} = 'EEG = eeg_checkset(EEG, ''chanlocsize'');';
                case 'select_data'
                    if isfield(p,'com') && ~isempty(p.com)
                        lines{end+1}=neuroqc.advice.EEGLABRecipe.capturedCall(p,'pop_select');
                    elseif isfield(p, 'kind') && strcmp(p.kind, 'time') && isfield(p, 'range') && numel(p.range) == 2
                        lines{end+1} = sprintf('EEG = pop_select(EEG, ''time'', [%.6g %.6g]);', p.range(1), p.range(2));
                    elseif isfield(p, 'kind') && strcmp(p.kind, 'channel') && isfield(p, 'channels') && ~isempty(p.channels)
                        ch = cellfun(@(c) ['''' char(c) ''''], cellstr(p.channels), 'UniformOutput', false);
                        lines{end+1} = sprintf('EEG = pop_select(EEG, ''channel'', {%s});', strjoin(ch, ', '));
                    elseif isfield(p, 'time') && numel(p.time) == 2
                        lines{end+1} = sprintf('EEG = pop_select(EEG, ''time'', [%.6g %.6g]);', p.time(1), p.time(2));
                    elseif isfield(p, 'channels') && ~isempty(p.channels)
                        ch = cellfun(@(c) ['''' char(c) ''''], cellstr(p.channels), 'UniformOutput', false);
                        lines{end+1} = sprintf('EEG = pop_select(EEG, ''channel'', {%s});', strjoin(ch, ', '));
                    else
                        error('NeuroQC:CapturedParametersRequired','Configure select_data completely before generating a batch');
                    end
                case 'select_events'
                    if isfield(p,'com') && ~isempty(p.com)
                        lines{end+1}=neuroqc.advice.EEGLABRecipe.capturedCall(p,'pop_selectevent');
                    elseif isfield(p, 'types') && ~isempty(p.types)
                        ty = cellfun(@(c) ['''' char(c) ''''], cellstr(p.types), 'UniformOutput', false);
                        lines{end+1} = sprintf('EEG = pop_selectevent(EEG, ''type'', {%s}, ''deleteevents'', ''on'');', strjoin(ty, ', '));
                    else
                        error('NeuroQC:CapturedParametersRequired','Configure select_events completely before generating a batch');
                    end
                case 'edit_events'
                    if isfield(p, 'com') && ~isempty(p.com)
                        lines{end+1} = neuroqc.advice.EEGLABRecipe.capturedCall(p,'pop_editeventvals');
                    else
                        error('NeuroQC:CapturedParametersRequired','Capture event edits before generating a batch');
                    end
                case 'auto_reject'
                    thr = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'threshold',1000);
                    lines{end+1} = 'assert(EEG.trials > 1, ''NeuroQC:EpochedRequired'', ''pop_autorej requires epochs'');';
                    lines{end+1} = sprintf('[EEG, rmep] = pop_autorej(EEG, ''threshold'', %g, ''nogui'', ''on'');', thr);
                    lines{end+1} = 'EEG.etc.neuroqc.rejectedEpochs = rmep;';
                case 'reject_jointprob'
                    base = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'threshold',5);
                    lo = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'locthresh',base);
                    gl = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'globthresh',base);
                    lines{end+1} = 'assert(EEG.trials > 1, ''NeuroQC:EpochedRequired'', ''pop_jointprob requires epochs'');';
                    channels=neuroqc.advice.EEGLABRecipe.rejectionChannels(p,lo,gl);
                    lines{end+1} = sprintf('[EEG, locthresh, globthresh] = pop_jointprob(EEG, 1, %s, %g, %g, 0, 0, 0, [], 0);',channels, lo, gl);
                    lines{end+1} = 'rejIdx = find(EEG.reject.rejjp);';
                    lines{end+1} = 'EEG.etc.neuroqc.rejectedEpochs = rejIdx;';
                    lines{end+1} = 'if ~isempty(rejIdx), EEG = pop_rejepoch(EEG, rejIdx, 0); end';
                case 'reject_kurtosis'
                    base = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'threshold',5);
                    lo = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'locthresh',base);
                    gl = neuroqc.advice.EEGLABRecipe.positiveParameter(p,'globthresh',base);
                    lines{end+1} = 'assert(EEG.trials > 1, ''NeuroQC:EpochedRequired'', ''pop_rejkurt requires epochs'');';
                    channels=neuroqc.advice.EEGLABRecipe.rejectionChannels(p,lo,gl);
                    lines{end+1} = sprintf('[EEG, locthresh, globthresh] = pop_rejkurt(EEG, 1, %s, %g, %g, 0, 0, 0, [], 0);',channels, lo, gl);
                    lines{end+1} = 'rejIdx = find(EEG.reject.rejkurt);';
                    lines{end+1} = 'EEG.etc.neuroqc.rejectedEpochs = rejIdx;';
                    lines{end+1} = 'if ~isempty(rejIdx), EEG = pop_rejepoch(EEG, rejIdx, 0); end';
                case 'resample'
                    if isfield(p, 'fs') && ~isempty(p.fs)
                        lines{end+1} = sprintf('EEG = pop_resample(EEG, %g);', p.fs);
                    else
                        lines{end+1} = '% resample: keep original rate (no-op)';
                    end
                case 'notch'
                    if isfield(p, 'frequency') && p.frequency
                        lines{end+1} = sprintf('EEG = pop_eegfiltnew(EEG, %g, %g, [], true, [], 0);', ...
                            max(p.frequency - 2, 0), p.frequency + 2);
                        lines{end+1} = sprintf('%% narrow stop around %g Hz (adjust FIR as needed)', p.frequency);
                    else
                        lines{end+1} = '% notch: off';
                    end
                case 'filter'
                    lines{end+1} = sprintf('EEG = pop_eegfiltnew(EEG, %g, %g);', p.highpass, p.lowpass);
                case 'badchannel'
                    if isfield(p, 'method') && ~strcmp(p.method, 'none')
                        methods=struct('kurtosis','kurt','probability','prob','spectrum','spec');
                        assert(isfield(methods,p.method),'NeuroQC:Method','Unsupported bad-channel method');
                        threshold=5; if isfield(p,'threshold'), threshold=p.threshold; end
                        lines{end+1}=sprintf('[~, badIdx] = pop_rejchan(EEG, ''elec'', 1:EEG.nbchan, ''threshold'', %g, ''norm'', ''on'', ''measure'', ''%s'');',threshold,methods.(p.method));
                        lines{end+1} = 'badIdx = badIdx(:)'';';
                        lines{end+1} = 'EEG.etc.neuroqc.badChannels = badIdx;';
                    else
                        lines{end+1} = 'badIdx = [];';
                        lines{end+1} = 'EEG.etc.neuroqc.badChannels = badIdx;';
                        lines{end+1} = '% bad channel detection: none';
                    end
                case 'remove_bad'
                    lines{end+1}='assert(isfield(EEG.etc.neuroqc,''badChannels''),''NeuroQC:BadChannelsRequired'',''Run detection or provide pendingBadChannels'');';
                    lines{end+1}='EEG.etc.neuroqc.originalChanlocs=EEG.chanlocs;';
                    lines{end+1} = 'if ~isempty(badIdx)';
                    lines{end+1} = '    EEG.etc.neuroqc.originalChanlocs = EEG.chanlocs;';
                    lines{end+1} = '    keepIdx = setdiff(1:EEG.nbchan, badIdx);';
                    lines{end+1} = '    EEG = pop_select(EEG, ''channel'', keepIdx);';
                    lines{end+1} = 'else';
                    lines{end+1} = '    keepIdx = 1:EEG.nbchan;';
                    lines{end+1} = 'end';
                case 'interpolate'
                    lines{end+1}='assert(isfield(EEG.etc.neuroqc,''badChannels''),''NeuroQC:BadChannelsRequired'',''Run detection or provide pendingBadChannels'');';
                    lines{end+1} = 'if ~isempty(badIdx)';
                    lines{end+1} = '    EEG.etc.neuroqc.interpolatedLabels={EEG.chanlocs(badIdx).labels};';
                    lines{end+1} = '    EEG = pop_interp(EEG, badIdx, ''spherical'');';
                    lines{end+1} = 'end';
                case 'restore_channels'
                    lines{end+1}='assert(isfield(EEG.etc.neuroqc,''originalChanlocs''),''NeuroQC:LocationsRequired'',''Supply originalChanlocs from before channel removal'');';
                    lines{end+1} = 'if isfield(EEG, ''etc'') && isfield(EEG.etc, ''neuroqc'') && isfield(EEG.etc.neuroqc, ''originalChanlocs'')';
                    lines{end+1} = '    EEG.etc.neuroqc.interpolatedLabels=setdiff({EEG.etc.neuroqc.originalChanlocs.labels},{EEG.chanlocs.labels});';
                    lines{end+1} = '    EEG = pop_interp(EEG, EEG.etc.neuroqc.originalChanlocs, ''spherical'');';
                    lines{end+1} = 'end';
                case 'reject_continuous'
                    assert(isfield(p,'thresholdDb'),'NeuroQC:Method','Native pop_rejcont uses dB; configure continuousThresholdDb');
                    lines{end+1}=sprintf('EEG=pop_rejcont(EEG,''elecrange'',1:EEG.nbchan,''freqlimit'',[20 min(40,EEG.srate/2-1)],''threshold'',%g,''epochlength'',0.5,''contiguous'',4,''addlength'',0.25,''taper'',''hamming'',''eegplot'',''off'',''verbose'',''off'');',p.thresholdDb);
                case 'reref'
                    mode = 'original';
                    if isfield(p, 'mode'), mode = p.mode; end
                    switch mode
                        case 'average'
                            lines{end+1} = "EEG = pop_reref(EEG, []);";
                        case 'mastoid'
                            chans = {};
                            if isfield(p, 'refChannels') && ~isempty(p.refChannels)
                                chans = cellfun(@char, p.refChannels, 'UniformOutput', false);
                            end
                            if isempty(chans)
                                lines{end+1} = "EEG = pop_reref(EEG, {'M1','M2'}); % adjust mastoid labels";
                            else
                                lines{end+1} = sprintf("EEG = pop_reref(EEG, {%s});", ...
                                    strjoin(cellfun(@(c) ['''' c ''''], chans, 'UniformOutput', false), ', '));
                            end
                        otherwise
                            lines{end+1} = '% reference: original (no re-reference)';
                    end
                case 'run_ica'
                    method = 'runica';
                    if isfield(p, 'method'), method = p.method; end
                    assert(strcmp(method,'runica'),'NeuroQC:Method','Only runica is supported');
                    lines{end+1}='savedRng=rng; rngCleanup=onCleanup(@() rng(savedRng)); rng(42,''twister'');';
                    lines{end+1} = sprintf('EEG = pop_runica(EEG, ''icatype'', ''%s'', ''rndreset'', ''no'');', method);
                    lines{end+1} = 'EEG = eeg_checkset(EEG);';
                case 'auto_ic_remove'
                    policy = 'conservative';
                    if isfield(p, 'policy'), policy = p.policy; end
                    if strcmp(policy, 'moderate'), thrStr = '0.80'; else, thrStr = '0.90'; end
                    lines{end+1} = "assert(~isempty(EEG.icaweights), 'NeuroQC:NoICA', 'Run ICA before auto_ic_remove');";
                    lines{end+1} = "EEG = iclabel(EEG);";
                    lines{end+1} = sprintf('icThr = %s; %% %s policy', thrStr, policy);
                    lines{end+1} = 'icLab = EEG.etc.ic_classification.ICLabel;';
                    lines{end+1} = 'probs = icLab.classifications;';
                    lines{end+1} = 'classes = icLab.classes;';
                    lines{end+1} = 'artCols = [];';
                    lines{end+1} = 'for j = 1:numel(classes)';
                    lines{end+1} = '    nm = lower(strtrim(char(classes{j})));';
                    lines{end+1} = "    if any(strcmp(nm, {'muscle','eye','heart','line noise','channel noise'}))";
                    lines{end+1} = '        artCols(end+1) = j; %#ok<AGROW>';
                    lines{end+1} = '    end';
                    lines{end+1} = 'end';
                    lines{end+1} = 'icIdx = [];';
                    lines{end+1} = 'for i = 1:size(probs, 1)';
                    lines{end+1} = '    if ~isempty(artCols) && max(probs(i, artCols)) >= icThr';
                    lines{end+1} = '        icIdx(end+1) = i; %#ok<AGROW>';
                    lines{end+1} = '    end';
                    lines{end+1} = 'end';
                    lines{end+1} = 'if ~isempty(icIdx)';
                    lines{end+1} = '    EEG = pop_subcomp(EEG, icIdx, 0);';
                    lines{end+1} = 'end';
                case 'epoch'
                    w=[contract.epoch.start contract.epoch.end];
                    if isfield(p,'window'), w=p.window; end
                    lines{end+1}='eventIdx=find(arrayfun(@(e) isequal(e.neuroqc_selected,1),EEG.event));';
                    lines{end+1}='assert(~isempty(eventIdx),''NeuroQC:NoFormalTrials'',''No selected events remain'');';
                    lines{end+1}=sprintf('EEG=pop_epoch(EEG,{},[%g %g],''eventindices'',eventIdx,''epochinfo'',''yes'');',w);
                case 'baseline'
                    % pop_rmbase expects milliseconds; contract/window are seconds.
                    if isfield(p, 'window') && numel(p.window) == 2
                        lines{end+1} = sprintf('EEG = pop_rmbase(EEG, [%.4g %.4g]);', ...
                            p.window(1) * 1000, p.window(2) * 1000);
                    elseif ~isempty(contract)
                        lines{end+1} = sprintf('EEG = pop_rmbase(EEG, [%.4g %.4g]);', ...
                            contract.baseline.start * 1000, contract.baseline.end * 1000);
                    end
                case 'artifact_reject'
                    assert(strcmp(p.method,'threshold'),'NeuroQC:Method','Only native EEGLAB amplitude threshold is supported here; run ERPLAB peak-to-peak manually');
                    lines{end+1}='assert(~isempty(EEG.epoch),''NeuroQC:EpochedRequired'',''Artifact rejection requires epochs'');';
                    lines{end+1}=sprintf('[EEG,rejectIdx]=pop_eegthresh(EEG,1,1:EEG.nbchan,-%g,%g,EEG.xmin,EEG.xmax,0,0);',p.thresholdUv,p.thresholdUv);
                    lines{end+1}='EEG.etc.neuroqc.rejectedEpochs=rejectIdx;';
                    lines{end+1}='if ~isempty(rejectIdx), EEG=pop_rejepoch(EEG,rejectIdx,0); end';
                otherwise
                    error('NeuroQC:UnsupportedStep','Unsupported step: %s',step.type);
            end
        end

        function value=positiveParameter(p,name,fallback)
            value=fallback;
            if isfield(p,name), value=p.(name); end
            assert(isnumeric(value) && isreal(value) && isscalar(value) && isfinite(value) && value>0, ...
                'NeuroQC:Parameters','%s must be a positive finite scalar; explicit invalid values are never replaced',name);
        end

        function channels=rejectionChannels(p,lo,gl)
            assert(isscalar(lo) && isscalar(gl) && all(isfinite([lo gl])) && lo>0 && gl>0,'NeuroQC:Parameters','Positive scalar rejection thresholds required');
            channels='1:EEG.nbchan';
            if isfield(p,'channels')
                assert(isnumeric(p.channels) && isvector(p.channels) && ~isempty(p.channels) && all(isfinite(p.channels)) && all(p.channels>=1 & p.channels==fix(p.channels)), 'NeuroQC:Parameters','Invalid rejection channel indices');
                channels=mat2str(p.channels(:)');
            end
        end

        function line=capturedCall(p,fn)
            assert(isfield(p,'com') && ~isempty(p.com),'NeuroQC:CapturedParametersRequired', ...
                'Capture complete %s parameters first; automated candidates cannot open dialogs',fn);
            line=strtrim(char(p.com));
            pattern=['^EEG\s*=\s*' fn '\s*\(\s*EEG\s*,[\s\S]+\)\s*;?$'];
            assert(~isempty(regexp(line,pattern,'once')),'NeuroQC:CapturedParametersRequired', ...
                'Expected a parameterized EEG = %s(EEG, ...) command',fn);
        end

        function s = epochTriggers(contract)
            s = '';
            if isempty(contract) || ~isprop(contract, 'conditions'), return; end
            parts = {};
            for i = 1:numel(contract.conditions)
                ev = contract.conditions(i).events;
                for j = 1:numel(ev)
                    parts{end+1} = ['''' char(string(ev{j})) '''']; %#ok<AGROW>
                end
            end
            s = strjoin(parts, ', ');
        end
    end
end
