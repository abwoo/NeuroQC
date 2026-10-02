function sd = baselineSD(EEG, contract)
%baselineSD Prestimulus baseline SD (scalar, robust median across channels)
    if EEG.trials <= 1
        sd = median(std(double(EEG.data), 0, 2));
        return;
    end
    if nargin >= 2 && ~isempty(contract) && isprop(contract, 'baseline')
        t0 = contract.baseline.start;
        t1 = contract.baseline.end;
    else
        t0 = EEG.xmin;
        t1 = min(0, EEG.xmax);
    end
    times = (0:EEG.pnts-1) / EEG.srate + EEG.xmin;
    sel = times >= t0 & times <= t1;
    if ~any(sel), sel = true(1, EEG.pnts); end
    data = double(EEG.data(:, sel, :));
    sd = std(data, 0, 'all');
end