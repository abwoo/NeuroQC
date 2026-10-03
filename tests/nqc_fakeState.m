function st = nqc_fakeState(epoched, srate)
%NQC_FAKESTATE Minimal data state for plan enumeration tests.
st = struct('isEpoched', epoched, 'srate', srate, 'ica', struct('present', false), ...
    'process', struct('step', {}), 'filters', struct('highpass', []), 'lineFreq', 50);
end
