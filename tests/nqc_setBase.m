function nqc_setBase(EEG)
%NQC_SETBASE Make EEG the current EEGLAB dataset (ALLEEG/EEG/CURRENTSET).
%   EEGLAB before 2023.0 adds "EEG = eeg_checkset( EEG );" to the history
%   of a dataset it stores; the stored dataset keeps the caller's history,
%   so that it is the dataset the test holds.
assignin('base', 'NQC_TMP', EEG);
evalin('base', ['global ALLCOM; ALLEEG = []; [ALLEEG, EEG, CURRENTSET] = eeg_store([], NQC_TMP, 0); ' ...
    'EEG.history = NQC_TMP.history; ALLEEG(CURRENTSET).history = NQC_TMP.history; clear NQC_TMP;']);
end
