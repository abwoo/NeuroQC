function types = erpERPAnalyzer_types(EEG)
% Resolve the time-locking event, never the first incidental epoch event.
% Fail closed: an epoch without exactly one time-locking event is ambiguous
% or corrupt, and silently returning '' would drop the trial from every
% condition without telling anyone (same policy as EpochIdentity.table).
    types = repmat({''},1,EEG.trials);
    if isfield(EEG,'epoch') && ~isempty(EEG.epoch) && isfield(EEG.epoch,'eventtype')
        for t=1:min(EEG.trials,numel(EEG.epoch))
            et=EEG.epoch(t).eventtype;
            if ~iscell(et), et={et}; end
            pick=[];
            if isfield(EEG.epoch,'eventlatency') && ~isempty(EEG.epoch(t).eventlatency)
                lat=EEG.epoch(t).eventlatency;
                if iscell(lat), lat=cellfun(@double,lat); end
                % EEGLAB epoch latencies are milliseconds; allow half a sample.
                zero=find(abs(lat)<=500/EEG.srate+eps);
                assert(numel(zero)==1,'NeuroQC:EpochTimeLock', ...
                    'Trial %d: expected exactly one time-locking event at latency 0, found %d',t,numel(zero));
                pick=zero;
                assert(pick<=numel(et),'NeuroQC:EpochTimeLock', ...
                    'Trial %d: epoch latency/type arrays are inconsistent',t);
            elseif numel(et)==1
                pick=1;
            else
                assert(false,'NeuroQC:EpochTimeLock', ...
                    'Trial %d: ambiguous epoch with %d events and no latency field',t,numel(et));
            end
            types{t}=char(string(et{pick}));
        end
    elseif isfield(EEG,'event') && numel(EEG.event)==EEG.trials
        for t=1:EEG.trials, types{t}=char(string(EEG.event(t).type)); end
    end
end
