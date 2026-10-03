function v = nqc_pct(x, p)
%NQC_PCT Percentile without the Statistics Toolbox.
x = sort(x(:)); v = x(max(1, round(numel(x) * p / 100)));
end
