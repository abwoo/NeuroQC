function E = nqc_epoched(EEG)
%NQC_EPOCHED Epoch and baseline-correct a synthetic dataset with EEGLAB, recording history.
[E, ~, com] = pop_epoch(EEG, {'11', '31'}, [-0.2 1], 'epochinfo', 'yes'); E = eeg_hist(E, com);
[E, com] = pop_rmbase(E, [-200 0]); E = eeg_hist(E, com);
end
