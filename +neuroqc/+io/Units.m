classdef Units
    methods (Static)
        function EEG = convert(EEG, from, to)
            assert(any(strcmp(from,{'V','uV'})) && any(strcmp(to,{'V','uV'})), ...
                'NeuroQC:DataUnitRequired','Units must be explicitly V or uV');
            if isfield(EEG,'etc') && isfield(EEG.etc,'neuroqc') && isfield(EEG.etc.neuroqc,'dataUnit')
                assert(strcmp(EEG.etc.neuroqc.dataUnit,from),'NeuroQC:UnitMismatch','Declared unit conflicts with recorded data unit');
            end
            factor=1;
            if strcmp(from,'uV') && strcmp(to,'V'), factor=1e-6; end
            if strcmp(from,'V') && strcmp(to,'uV'), factor=1e6; end
            EEG.data=double(EEG.data)*factor;
            if isfield(EEG,'icaweights') && ~isempty(EEG.icaweights)
                EEG.icaweights=EEG.icaweights/factor;
            end
            if isfield(EEG,'icawinv') && ~isempty(EEG.icawinv), EEG.icawinv=EEG.icawinv*factor; end
            EEG.etc.neuroqc.dataUnit=to;
        end
    end
end
