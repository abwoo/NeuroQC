function ref = nqc_ref(N, names, units)
%NQC_REF Reference trial sets for statistics tests: N(c) trials per condition.
if nargin < 2, names = {'P3.mean'}; end
if nargin < 3, units = repmat({'uV'}, 1, numel(names)); end
ids = arrayfun(@(n) 1:n, N, 'UniformOutput', false);
ref = struct('ids', {ids}, 'n', N, 'names', {arrayfun(@(k) sprintf('c%d', k), 1:numel(N), 'UniformOutput', false)}, ...
    'objectives', {names}, 'units', {units});
end
