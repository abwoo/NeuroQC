classdef TrialSelector
    % Select events by explicit acquisition-stage evidence, never by event code alone.
    methods (Static)
        function [EEG, audit] = apply(EEG, rule, codes)
            assert(isstruct(rule) && isfield(rule,'mode'),'NeuroQC:TrialRule','trialSelection must be a struct with mode');
            if isfield(EEG,'epoch') && ~isempty(EEG.epoch)
                [EEG,audit]=neuroqc.contract.TrialSelector.epoched(EEG,rule,codes); return;
            end
            n=numel(EEG.event); eligible=false(1,n);
            types=arrayfun(@(e) strtrim(char(string(e.type))),EEG.event,'UniformOutput',false);
            lat=[EEG.event.latency]; seconds=(lat-1)/EEG.srate;
            switch rule.mode
                case 'existing'
                    assert(isfield(EEG.event,'neuroqc_selected'),'NeuroQC:TrialRule','No saved trial selection');
                    eligible=arrayfun(@(e) isequal(e.neuroqc_selected,1),EEG.event);
                case 'all'
                    eligible(:)=true;
                case 'event_indices'
                    ids=rule.indices;
                    assert(isnumeric(ids) && all(isfinite(ids)) && all(ids==fix(ids)) && all(ids>=1 & ids<=n), ...
                        'NeuroQC:TrialRule','Invalid source event indices');
                    eligible(ids)=true;
                case 'time_ranges'
                    ranges=rule.ranges;
                    assert(isnumeric(ranges) && size(ranges,2)==2 && all(isfinite(ranges),'all') && all(ranges(:,2)>ranges(:,1)), ...
                        'NeuroQC:TrialRule','Provide [start end] ranges in seconds from recording start');
                    for k=1:size(ranges,1)
                        eligible=eligible | (seconds>=ranges(k,1) & seconds<ranges(k,2));
                    end
                case 'marker_ranges'
                    active=false;
                    for k=1:n
                        if strcmp(types{k},char(string(rule.startCode)))
                            assert(~active,'NeuroQC:TrialRule','Nested formal-start marker'); active=true;
                        elseif strcmp(types{k},char(string(rule.endCode)))
                            assert(active,'NeuroQC:TrialRule','Formal-end marker without start'); active=false;
                        else
                            eligible(k)=active;
                        end
                    end
                    assert(~active,'NeuroQC:TrialRule','Unclosed formal interval');
                otherwise
                    error('NeuroQC:FormalRuleRequired','Specify formal trial indices, time ranges, or start/end markers');
            end
            selected=eligible & ismember(types,codes);
            assert(any(selected),'NeuroQC:NoFormalTrials','No selected target events');
            ids=1:n;
            if isfield(EEG.event,'neuroqc_source_id')
                for k=1:n
                    if ~isempty(EEG.event(k).neuroqc_source_id), ids(k)=EEG.event(k).neuroqc_source_id; end
                end
            end
            for k=1:n
                EEG.event(k).type=types{k};
                EEG.event(k).neuroqc_source_id=ids(k);
                EEG.event(k).neuroqc_selected=double(selected(k));
            end
            audit=struct('rule',rule,'codes',{codes},'selectedSourceIds',ids(selected), ...
                'excludedTargetIds',ids(~selected & ismember(types,codes)),'counts',struct());
            for k=1:numel(codes)
                audit.counts.(matlab.lang.makeValidName(['event_' codes{k}]))=sum(selected & strcmp(types,codes{k}));
            end
            EEG.etc.neuroqc.selection=audit;
        end
        function [EEG,audit]=epoched(EEG,rule,codes)
            assert(any(strcmp(rule.mode,{'all','existing','epoch_indices'})), ...
                'NeuroQC:TrialRule','Epoched input requires explicit epoch_indices, existing, or all; original time ranges are unavailable');
            keep=false(1,EEG.trials); anchors=zeros(1,EEG.trials); types=cell(1,EEG.trials);
            if strcmp(rule.mode,'epoch_indices')
                ix=rule.indices;
                assert(isnumeric(ix) && all(isfinite(ix)) && all(ix==fix(ix)) && all(ix>=1 & ix<=EEG.trials),'NeuroQC:TrialRule','Invalid epoch indices');
                keep(ix)=true;
            else
                keep(:)=true;
            end
            for k=1:EEG.trials
                ep=EEG.epoch(k); lat=ep.eventlatency; idx=ep.event;
                if iscell(lat), lat=cellfun(@double,lat); end
                if iscell(idx), idx=cellfun(@double,idx); end
                z=idx(abs(lat)<=500/EEG.srate+eps);
                target=arrayfun(@(j) ismember(strtrim(char(string(EEG.event(j).type))),codes),z);
                z=z(target);
                if isempty(z), keep(k)=false; continue; end
                assert(numel(z)==1,'NeuroQC:EpochIdentity','Multiple target anchors at time zero');
                anchors(k)=z; types{k}=strtrim(char(string(EEG.event(z).type)));
                if strcmp(rule.mode,'existing')
                    assert(isfield(EEG.event,'neuroqc_selected'),'NeuroQC:TrialRule','No saved trial selection');
                    keep(k)=keep(k) && isequal(EEG.event(z).neuroqc_selected,1);
                end
            end
            assert(any(keep),'NeuroQC:NoFormalTrials','No selected target epochs');
            for j=1:numel(EEG.event)
                if ~isfield(EEG.event,'neuroqc_source_id') || isempty(EEG.event(j).neuroqc_source_id)
                    EEG.event(j).neuroqc_source_id=j;
                end
                EEG.event(j).neuroqc_selected=double(any(anchors(keep)==j));
            end
            ids=arrayfun(@(j) EEG.event(j).neuroqc_source_id,anchors(keep));
            assert(numel(unique(ids))==numel(ids),'NeuroQC:EpochIdentity','Duplicate selected source identities');
            audit=struct('rule',rule,'codes',{codes},'selectedSourceIds',ids,'excludedTargetIds',[],'counts',struct(),'scope','handoff_epochs');
            for j=1:numel(codes)
                audit.counts.(matlab.lang.makeValidName(['event_' codes{j}]))=sum(strcmp(types(keep),codes{j}));
            end
            if any(~keep), EEG=pop_select(EEG,'trial',find(keep)); end
            EEG.etc.neuroqc.selection=audit;
            EEG=eeg_checkset(EEG,'eventconsistency');
        end
    end
end
