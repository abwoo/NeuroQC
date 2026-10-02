classdef RecipeInput
    % Input bookkeeping and explicit EEGLAB preparation only.
    methods (Static)
        function EEG=prepare(EEG,opts)
            assert(isfield(opts,'dataUnit'),'NeuroQC:DataUnitRequired','Declare V or uV');
            EEG=neuroqc.io.Units.convert(EEG,opts.dataUnit,'uV');
            % Stamp before any native event deletion/crop, even without a formal rule.
            for k=1:numel(EEG.event)
                if ~isfield(EEG.event,'neuroqc_source_id') || isempty(EEG.event(k).neuroqc_source_id)
                    EEG.event(k).neuroqc_source_id=k;
                end
            end
            % Fail-closed default: an explicit trialSelection without the
            % gate still applies; neither present means no formal rule.
            if ~isfield(opts,'trialSteps')
                opts.trialSteps=isfield(opts,'trialSelection');
            end
            if isfield(opts,'trialSelection') && opts.trialSteps
                [EEG,~]=neuroqc.contract.TrialSelector.apply(EEG,opts.trialSelection,cellstr(opts.codes));
            elseif opts.trialSteps
                error('NeuroQC:FormalRuleRequired','Explicit trialSelection required');
            end
            if isfield(opts,'stripRefSuffix') && opts.stripRefSuffix
                for k=1:EEG.nbchan
                    EEG.chanlocs(k).labels=regexprep(EEG.chanlocs(k).labels,'-Ref$','','ignorecase');
                end
            end
            if isfield(opts,'includeChannels') && ~isempty(opts.includeChannels)
                [found,idx]=ismember(upper(string(opts.includeChannels)),upper(string({EEG.chanlocs.labels})));
                assert(all(found),'NeuroQC:Channels','Requested channels missing');
                EEG=pop_select(EEG,'channel',idx);
            end
            if isfield(opts,'lookupFile') && ~isempty(opts.lookupFile)
                EEG=pop_chanedit(EEG,'lookup',opts.lookupFile);
            end
            if isfield(opts,'cropSeconds') && ~isempty(opts.cropSeconds)
                assert(isempty(EEG.epoch),'NeuroQC:Crop','Continuous data required for cropSeconds');
                ranges=opts.cropSeconds; if isvector(ranges), ranges=reshape(ranges,1,[]); end
                EEG=pop_select(EEG,'time',ranges);
            end
            if isfield(opts,'pendingBadChannels')
                idx=opts.pendingBadChannels;
                assert(all(idx>=1 & idx<=EEG.nbchan & idx==fix(idx)),'NeuroQC:Channels','Invalid pendingBadChannels');
                EEG.etc.neuroqc.badChannels=idx;
            end
            if isfield(opts,'originalChanlocs'), EEG.etc.neuroqc.originalChanlocs=opts.originalChanlocs; end
            EEG=eeg_checkset(EEG);
        end
    end
end
