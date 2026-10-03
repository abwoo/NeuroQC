function nqc_setBase(EEG)
%NQC_SETBASE Make EEG the current EEGLAB dataset (ALLEEG/EEG/CURRENTSET).
assignin('base', 'NQC_TMP', EEG);
evalin('base', ['global ALLCOM; ALLEEG = []; [ALLEEG, EEG, CURRENTSET] = eeg_store([], NQC_TMP, 0); ' ...
    'clear NQC_TMP;']);
end
