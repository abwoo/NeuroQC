classdef CandidateSession
    % Explicit scoped trials. Every signal operation delegates to EEGLAB.
    methods (Static)
        function out=compare(out,source,contract,opts,indices)
            assert(nargin==5 && ~isempty(indices),'NeuroQC:CandidatesRequired','Explicitly choose candidate indices');
            assert(all(indices>=1 & indices<=numel(out.pipelines) & indices==fix(indices)) && numel(unique(indices))==numel(indices),'NeuroQC:CandidatesRequired','Invalid or duplicate candidate indices');
            retry=nargin>=4 && isstruct(opts) && isfield(opts,'retryFailed') && opts.retryFailed;
            out=neuroqc.advice.CandidateSession.recover(out);
            out=neuroqc.advice.RecommendPath.bindEvaluationContract(out,contract);
            opts=out.recipeOptions; % Bind evaluation to the exported recipe configuration.
            EEG=neuroqc.advice.RecommendPath.loadSource(source);
            assert(strcmp(neuroqc.utils.hashEEG(EEG),out.inputHash),'NeuroQC:SourceMismatch','The handoff EEG has changed');
            stepTypes = {};
            for i = 1:numel(out.pipelines)
                stepTypes = [stepTypes {out.pipelines(i).steps.type}]; %#ok<AGROW>
            end
            stepTypes = unique(stepTypes);
            needsTrialRule = isfield(opts,'trialSelection') || any(ismember(stepTypes,{'epoch','baseline','artifact_reject','auto_reject','reject_jointprob','reject_kurtosis'}));
            if needsTrialRule && ~isfield(opts,'trialSelection')
                error('NeuroQC:FormalRuleRequired', ...
                    ['Comparison needs trialSelection for its ERP evaluation view. ', ...
                     'Supply existing / explicit indices, or mode=all only if already formally screened.']);
            end
            prep=opts;
            prep.trialSteps=isfield(opts,'trialSelection');
            prep.codes={};
            for k=1:numel(contract.conditions), prep.codes=[prep.codes contract.conditions(k).events]; end
            ref=neuroqc.advice.RecipeInput.prepare(EEG,prep);
            ref=neuroqc.advice.CandidateSession.view(ref,contract);
            if ~prep.trialSteps
                fprintf(['NOTE: continuous-only candidates without trialSelection; ', ...
                    'ERP evaluation view epochs contract events only (candidates unchanged).\n']);
            end
            originalPath=path; cleanup=onCleanup(@() path(originalPath)); %#ok<NASGU>
            addpath(out.recipesDir,'-begin');
            folder=fullfile(out.outputDir,'candidate_trials'); if ~isfolder(folder), mkdir(folder); end
            
            % Load previously tested candidates
            prevRows = struct('id',{},'quality',{}); prevFailures = struct('id',{},'message',{});
            if isfield(out,'candidateTrials') && isfile(fullfile(folder,'comparison_session.mat'))
                previous=load(fullfile(folder,'comparison_session.mat'),'rows','failures');
                prevRows = previous.rows; prevFailures = previous.failures;
            end
            
            if retry
                assert(all(ismember({out.pipelines(indices).id},{prevFailures.id})),'NeuroQC:Retry','Only execution failures can be retried');
                archive=fullfile(folder,['retry_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);mkdir(archive);
                for i=indices
                    id=out.pipelines(i).id;
                    for suffix={'.mat','.result.mat'}
                        file=fullfile(folder,[id suffix{1}]);if isfile(file),movefile(file,archive);end
                    end
                end
                prevRows=prevRows(~ismember({prevRows.id},{out.pipelines(indices).id}));
                prevFailures=prevFailures(~ismember({prevFailures.id},{out.pipelines(indices).id}));
            end
            assert(isempty(intersect({prevRows.id},{out.pipelines(indices).id})),'NeuroQC:OutputExists','These candidates were already tried; choose untested candidates');
            % Bind the evaluation contract BEFORE starting expensive computation.
            rows=prevRows;failures=prevFailures;out.candidateTrials=folder;
            neuroqc.advice.CandidateSession.checkpoint(folder,out,rows,failures);

            % Parallel or serial evaluation of NEW candidates only
            nIdx = numel(indices);
            newRowIds = cell(1, nIdx);
            newRowQualities = cell(1, nIdx);
            newFailIds = cell(1, nIdx);
            newFailMessages = cell(1, nIdx);
            
            usePar = isfield(opts,'useParallel') && opts.useParallel && license('test','Distrib_Computing_Toolbox');
            if usePar
                try
                    gcp;  % ensure pool exists
                catch
                    try
                        parpool('local');  % auto-size
                    catch
                        usePar = false;  % fallback
                    end
                end
            end
            
            out.executionMode='serial';
            if usePar, out.executionMode='parallel'; end
            out.parallelRequested=isfield(opts,'useParallel') && logical(opts.useParallel);
            if usePar
                parfor j = 1:nIdx
                    [newRowIds{j}, newRowQualities{j}, newFailIds{j}, newFailMessages{j}] = ...
                        neuroqc.advice.CandidateSession.evalCandidate( ...
                        out, EEG, ref, contract, folder, needsTrialRule, indices(j));
                end
            else
                for j = 1:nIdx
                    [newRowIds{j}, newRowQualities{j}, newFailIds{j}, newFailMessages{j}] = ...
                        neuroqc.advice.CandidateSession.evalCandidate( ...
                        out, EEG, ref, contract, folder, needsTrialRule, indices(j));
                end
            end
            
            % Combine previous + new results (preserve previous order, append new)
            rows = prevRows;
            failures = prevFailures;
            for j = 1:nIdx
                rows(end+1) = struct('id', newRowIds{j}, 'quality', newRowQualities{j}); %#ok<AGROW>
                if ~isempty(newFailIds{j})
                    failures(end+1) = struct('id', newFailIds{j}, 'message', newFailMessages{j}); %#ok<AGROW>
                end
            end
            
            out=neuroqc.advice.RecommendPath.applyExternalQC(out,rows,contract,out.goalProfile);
            out.metricScope='paired_ERP_QC_relative_to_handoff_not_physiological_truth';
            out.candidateTrials=folder; out.trialFailures=failures;
            out.testedIndices=find(ismember({out.pipelines.id},{rows.id}));
            out.searchCoverage=numel(out.testedIndices)/numel(out.pipelines);
            neuroqc.advice.CandidateSession.checkpoint(folder,out,rows,failures);
            neuroqc.advice.RecommendPath.writeSummary(out,out.outputDir,contract,[],opts);
        end
        
        function [candId, candQuality, failId, failMsg] = evalCandidate(out, EEG, ref, contract, folder, needsTrialRule, idx)
            % Single candidate evaluation (parfor-compatible).
            i = idx; id = out.pipelines(i).id; name = ['recipe_' id];
            q = neuroqc.advice.ExternalQC.defaultQuality(); q.status = 'FAIL';
            failId = ''; failMsg = '';
            try
                % Workers may start without client recipe paths. Resolve only
                % after installing the intended session path, inside failure capture.
                previousPath=path; pathGuard=onCleanup(@() path(previousPath)); %#ok<NASGU>
                addpath(out.recipesDir, '-begin');
                clear(name);
                assert(strcmp(which(name), fullfile(out.recipesDir, [name '.m'])), ...
                    'NeuroQC:RecipePath', 'Another recipe shadows this session');
                file = fullfile(folder, [id '.mat']);
                % A candidate without a receipt is an interrupted attempt, not a completed comparison.
                if isfile(file)
                    archive=fullfile(folder,['interrupted_' id '_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);mkdir(archive);movefile(file,archive);
                end
                candidate = feval(name, EEG);
                sourceHash = out.inputHash; recipeFingerprint = out.pipelines(i).fingerprint(); %#ok<NASGU>
                save(file, 'candidate', 'q', 'sourceHash', 'recipeFingerprint', '-v7.3');
                hasMarkers = isfield(candidate,'event') && ~isempty(candidate.event) && ...
                    isfield(candidate.event,'neuroqc_selected');
                if needsTrialRule
                    assert(hasMarkers && any(arrayfun(@(x) isequal(x.neuroqc_selected,1),candidate.event)), ...
                        'NeuroQC:TrialRule', 'Regenerate recipes with trialSelection before comparison');
                end
                view = neuroqc.advice.CandidateSession.view(candidate, contract);
                q = neuroqc.advice.CandidateSession.measure(ref, view, contract);
                save(file, 'q', '-append');
            catch ME
                q.status = 'FAIL'; failId = id; failMsg = ME.message;
                % Persist failures as well, so interrupted runs can resume.

            end
            candId = id; candQuality = q;
            receipt=struct('id',id,'quality',q,'failId',failId,'failMsg',failMsg, ...
                'inputHash',out.inputHash,'fingerprint',out.pipelines(i).fingerprint(), ...
                'evaluationContract',neuroqc.advice.RecommendPath.contractSnapshot(contract));
            pending=fullfile(folder,[id '.result.partial.mat']);save(pending,'receipt','-v7.3');
            movefile(pending,fullfile(folder,[id '.result.mat']),'f');
        end
        function EEG=view(EEG,c)
            if isempty(EEG.epoch)
                codes={};
                for k=1:numel(c.conditions), codes=[codes c.conditions(k).events]; end %#ok<AGROW>
                hasMarkers=isfield(EEG,'event') && ~isempty(EEG.event) && ...
                    isfield(EEG.event,'neuroqc_selected');
                if hasMarkers
                    idx=find(arrayfun(@(e) isequal(e.neuroqc_selected,1),EEG.event));
                else
                    idx=[];
                end
                if hasMarkers
                    assert(~isempty(idx),'NeuroQC:NoFormalTrials','All explicitly selected events were lost; do not fall back to practice/all events');
                    EEG=pop_epoch(EEG,{},[c.epoch.start c.epoch.end],'eventindices',idx,'epochinfo','yes');
                else
                    % Evaluation-only: stamp stable source ids, then epoch contract events.
                    nE=numel(EEG.event);
                    for j=1:nE
                        if ~isfield(EEG.event,'neuroqc_source_id') || isempty(EEG.event(j).neuroqc_source_id)
                            EEG.event(j).neuroqc_source_id=j;
                        end
                        EEG.event(j).neuroqc_selected=0;
                    end
                    EEG=pop_epoch(EEG,codes,[c.epoch.start c.epoch.end],'epochinfo','yes');
                    for j=1:numel(EEG.event)
                        if ~isfield(EEG.event,'neuroqc_source_id') || isempty(EEG.event(j).neuroqc_source_id)
                            EEG.event(j).neuroqc_source_id=j;
                        end
                        EEG.event(j).neuroqc_selected=0;
                    end
                    for k=1:EEG.trials
                        ep=EEG.epoch(k); lat=ep.eventlatency; idx=ep.event;
                        if iscell(lat), lat=cellfun(@double,lat); end
                        if iscell(idx), idx=cellfun(@double,idx); end
                        z=idx(abs(lat)<=500/EEG.srate+eps);
                        types=arrayfun(@(j) strtrim(char(string(EEG.event(j).type))),z,'UniformOutput',false);
                        z=z(ismember(types,codes));
                        assert(~isempty(z),'NeuroQC:EpochIdentity','No time-locking contract event');
                        EEG.event(z).neuroqc_selected=1;
                    end
                end
            end
            % QC view only. Candidate itself retains exactly the selected steps.
            % Do not re-baseline: that would erase differences between baseline candidates.
            neuroqc.io.EpochIdentity.table(EEG);
        end
        function q=measure(ref,e,c)
            R=neuroqc.io.EpochIdentity.table(ref); T=neuroqc.io.EpochIdentity.table(e);
            assert(numel(unique(T.sourceEventId))==height(T),'NeuroQC:EpochIdentity','Duplicate trial IDs');
            assert(all(ismember(T.sourceEventId,R.sourceEventId)),'NeuroQC:EpochIdentity','Unexpected trial identities');
            [~,ia,ib]=intersect(R.sourceEventId,T.sourceEventId,'stable');
            labels=lower(string({e.chanlocs.labels})); refLabels=lower(string({ref.chanlocs.labels}));
            [shared,rc,ec]=intersect(refLabels,labels,'stable'); %#ok<ASGLU>
            assert(numel(rc)>=4,'NeuroQC:QC','At least four common channels required');
            tr=ref.xmin+(0:ref.pnts-1)/ref.srate; te=e.xmin+(0:e.pnts-1)/e.srate;
            window=te>=max(tr(1),te(1)) & te<=min(tr(end),te(end));
            a=double(ref.data(rc,:,ia)); b=double(e.data(ec,window,ib));
            % Interpolation only aligns the QC comparison grid, never candidate EEG.
            aa=zeros(size(b));
            for k=1:numel(ia), aa(:,:,k)=interp1(tr,a(:,:,k)',te(window),'linear')'; end
            roi=false(numel(shared),1); targetTime=false(1,sum(window));
            for j=1:numel(c.components)
                roi=roi | ismember(shared,lower(string(c.components(j).roi)))';
                targetTime=targetTime | (te(window)>=c.components(j).window(1) & te(window)<=c.components(j).window(2));
            end
            assert(any(roi) && any(targetTime),'NeuroQC:QC','No usable target ROI/window');
            retention=[]; reliability=[]; topo=[]; distortion=[];
            saved=rng; guard=onCleanup(@() rng(saved)); rng(42,'twister'); %#ok<NASGU>
            for k=1:numel(c.conditions)
                codes=c.conditions(k).events;
                n0=sum(ismember(R.eventCode,codes)); sel=find(ismember(T.eventCode(ib),codes));
                assert(n0>0 && numel(sel)>=4,'NeuroQC:QC','Each condition needs at least four retained trials for split-half QC');
                retention(end+1)=numel(sel)/n0; %#ok<AGROW>
                av=mean(aa(:,:,sel),3); bv=mean(b(:,:,sel),3);
                distortion(end+1)=norm(bv(:)-av(:))/max(norm(av(:)),eps); %#ok<AGROW>
                cc=zeros(1,30); tt=cc;
                for rep=1:30
                    % Stable IDs ensure deterministic splitting, independent of input epoch order.
                    [~,order]=sort(T.sourceEventId(ib(sel))); ss=sel(order); ss=ss(randperm(numel(ss))); h=floor(numel(ss)/2);
                    x=mean(b(:,:,ss(1:h)),3); y=mean(b(:,:,ss(h+1:2*h)),3);
                    rx=x(roi,targetTime); ry=y(roi,targetTime);
                    rr=neuroqc.advice.CandidateSession.correlation(rx(:),ry(:)); cc(rep)=neuroqc.utils.spearmanBrown(rr);
                    tt(rep)=neuroqc.advice.CandidateSession.correlation(mean(x(:,targetTime),2),mean(y(:,targetTime),2));
                end
                % Degenerate splits yield NaN (undefined correlation); ignore
                % them unless every split is NaN, which stays NaN -> missing.
                reliability(end+1)=median(cc,'omitnan'); topo(end+1)=median(tt,'omitnan'); %#ok<AGROW>
            end
            q=neuroqc.advice.ExternalQC.defaultQuality(); q.status='REVIEW';
            q.retention=height(T)/height(R); q.reliability=median(reliability); q.topoStability=median(topo);
            q.waveformDistortion=max(distortion); q.minConditionRetention=min(retention); q.conditionRetentionSpread=max(retention)-min(retention);
            q.rank=rank(reshape(double(e.data),e.nbchan,[]));
            q.badRatio=0; q.interpRatio=0;
            if isfield(e,'etc') && isfield(e.etc,'neuroqc') && isfield(e.etc.neuroqc,'badChannels')
                q.badRatio=numel(e.etc.neuroqc.badChannels)/ref.nbchan;
            end
            if isfield(e,'etc') && isfield(e.etc,'neuroqc') && isfield(e.etc.neuroqc,'interpolatedLabels')
                q.interpRatio=numel(e.etc.neuroqc.interpolatedLabels)/ref.nbchan;
            end
            q.eventLoss=false;
            % Baseline noise + SNR, same definition as ERPAnalyzer:
            %   baselineSd = SD of samples inside the contract baseline
            %   snr        = |mean amplitude in the component windows| / baselineSd
            % Undefined (degenerate baseline, or a window outside the data)
            % stays NaN rather than a fabricated huge number.
            q.baselineSd = NaN;
            q.snr = NaN;
            bl = te(window) >= c.baseline.start & te(window) <= c.baseline.end;
            if c.baseline.start < c.baseline.end && any(bl)
                q.baselineSd = std(b(:, bl, :), 0, 'all');
                if isfinite(q.baselineSd) && q.baselineSd > 0
                    snrByCond = nan(1, numel(c.conditions));
                    for k = 1:numel(c.conditions)
                        codes = c.conditions(k).events;
                        sel = find(ismember(T.eventCode(ib), codes));
                        if isempty(sel), continue; end
                        bv = mean(b(:, :, sel), 3);
                        snrByCond(k) = abs(mean(bv(roi, targetTime), 'all')) / q.baselineSd;
                    end
                    if any(isfinite(snrByCond))
                        q.snr = median(snrByCond, 'omitnan');
                    end
                end
            end
        end
        function r=correlation(a,b)
            a=a-mean(a); b=b-mean(b); den=norm(a)*norm(b);
            if den<=eps, r=NaN; else, r=max(-1,min(1,(a'*b)/den)); end
        end
        function checkpoint(folder,out,rows,failures)
            pending=fullfile(folder,'comparison_session.partial.mat');
            save(pending,'out','rows','failures','-v7.3');movefile(pending,fullfile(folder,'comparison_session.mat'),'f');
        end

        function ix=tested(out)
            ix=[];if isempty(out),return;end
            out=neuroqc.advice.CandidateSession.recover(out);
            if isfield(out,'testedIndices'),ix=out.testedIndices;end
        end

        function [out,rows,failures]=recover(out)
            rows=struct('id',{},'quality',{});
            failures=struct('id',{},'message',{});
            if isempty(out) || ~isfield(out,'outputDir'),return;end
            folder=fullfile(out.outputDir,'candidate_trials');file=fullfile(folder,'comparison_session.mat');
            if ~isfile(file) && ~isfolder(folder),return;end
            if isfile(file)
                saved=load(file,'out','rows','failures');
                assert(strcmp(saved.out.inputHash,out.inputHash) && isequal({saved.out.pipelines.id},{out.pipelines.id}), ...
                    'NeuroQC:SessionMismatch','Comparison checkpoint belongs to another session');
                out=saved.out;rows=saved.rows;failures=saved.failures;
            else
                % Session metadata lost: per-candidate receipts are the source
                % of truth for what was already evaluated.
                rows=struct('id',{},'quality',{});failures=struct('id',{},'message',{});
            end
            receipts=dir(fullfile(folder,'*.result.mat'));
            if ~isfile(file) && isempty(receipts),return;end
            for k=1:numel(receipts)
                d=load(fullfile(folder,receipts(k).name),'receipt');r=d.receipt;
                i=find(strcmp({out.pipelines.id},r.id),1);
                if ~isfield(out,'evaluationContract') && isfield(r,'evaluationContract')
                    % A fresh session adopts the contract stamped by its receipts,
                    % so interrupted comparisons resume without a saved session.
                    out.evaluationContract=r.evaluationContract;
                end
                assert(~isempty(i) && strcmp(r.inputHash,out.inputHash) && strcmp(r.fingerprint,out.pipelines(i).fingerprint()) ...
                    && isequaln(r.evaluationContract,out.evaluationContract),'NeuroQC:SessionMismatch','Candidate receipt provenance mismatch');
                if any(strcmp({rows.id},r.id)),continue;end
                rows(end+1)=struct('id',r.id,'quality',r.quality);
                if ~isempty(r.failId),failures(end+1)=struct('id',r.failId,'message',r.failMsg);end
            end
            out.candidateTrials=folder;out.trialFailures=failures;
            out.testedIndices=find(ismember({out.pipelines.id},{rows.id}));out.searchCoverage=numel(out.testedIndices)/numel(out.pipelines);
            if ~isempty(rows)
                c=neuroqc.contract.AnalysisContract(out.evaluationContract);
                out=neuroqc.advice.RecommendPath.applyExternalQC(out,rows,c,out.goalProfile);
                out.metricScope='paired_ERP_QC_relative_to_handoff_not_physiological_truth';
            end
            neuroqc.advice.CandidateSession.checkpoint(folder,out,rows,failures);
        end

        function out=rerank(out,contract)
            % Re-apply the current constraint limits and ranking to already
            % evaluated candidates. No recipe is re-executed, so editing
            % Constraints never invalidates receipts or generated recipes.
            [out,rows,failures]=neuroqc.advice.CandidateSession.recover(out);
            assert(~isempty(rows),'NeuroQC:CandidatesRequired', ...
                'No evaluated candidate to re-rank; compare at least one first');
            out=neuroqc.advice.RecommendPath.bindEvaluationContract(out,contract);
            gp=[];
            if isfield(out,'goalProfile'),gp=out.goalProfile;end
            out=neuroqc.advice.RecommendPath.applyExternalQC(out,rows,contract,gp);
            out.metricScope='paired_ERP_QC_relative_to_handoff_not_physiological_truth';
            neuroqc.advice.CandidateSession.checkpoint(out.candidateTrials,out,rows,failures);
            opts=struct();
            if isfield(out,'recipeOptions'),opts=out.recipeOptions;end
            neuroqc.advice.RecommendPath.writeSummary(out,out.outputDir,contract,[],opts);
        end

        function EEG=loadCandidate(out,index)
            assert(isfield(out,'candidateTrials'),'NeuroQC:Candidate','No trial outputs');
            d=load(fullfile(out.candidateTrials,[out.pipelines(index).id '.mat']));
            assert(strcmp(d.sourceHash,out.inputHash) && strcmp(d.recipeFingerprint,out.pipelines(index).fingerprint()),'NeuroQC:SourceMismatch','Candidate provenance mismatch');
            EEG=d.candidate;
        end
    end
end
