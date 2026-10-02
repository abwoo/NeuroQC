function hp = extractHP(p)
%extractHP High-pass value from a pipeline (for sensitivity analysis)
    hp = NaN;
    for i = 1:numel(p.steps)
        if strcmp(p.steps(i).type, 'filter') && isfield(p.steps(i).parameters, 'highpass')
            hp = p.steps(i).parameters.highpass;
            return;
        end
    end
end