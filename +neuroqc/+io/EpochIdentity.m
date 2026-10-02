classdef EpochIdentity
    methods (Static)
        function T=table(EEG)
            epoch=(1:EEG.trials)'; sourceEventId=nan(EEG.trials,1); eventCode=cell(EEG.trials,1);
            for k=1:EEG.trials
                ep=EEG.epoch(k); lat=ep.eventlatency;
                if iscell(lat), lat=cellfun(@double,lat); end
                ix=find(abs(lat)<=500/EEG.srate+eps);
                indices=ep.event;
                if iscell(indices), indices=cellfun(@double,indices); end
                candidates=indices(ix);
                selected=[];
                for j=candidates(:)'
                    e=EEG.event(j);
                    if isfield(e,'neuroqc_selected') && isequal(e.neuroqc_selected,1), selected(end+1)=j; end
                end
                assert(numel(selected)==1,'NeuroQC:EpochIdentity','Ambiguous or unselected time-locking event');
                e=EEG.event(selected); sourceEventId(k)=e.neuroqc_source_id;
                eventCode{k}=char(string(e.type));
            end
            T=table(epoch,sourceEventId,eventCode);
        end
    end
end
