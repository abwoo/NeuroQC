function d = durationSec(EEG)
%durationSec Total duration in seconds
    if EEG.trials > 1
        d = EEG.pnts * EEG.trials / EEG.srate;
    else
        d = EEG.pnts / EEG.srate;
    end
end