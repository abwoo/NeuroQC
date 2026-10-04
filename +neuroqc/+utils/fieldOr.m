function v = fieldOr(s, f, d)
%FIELDOR s.(f), or d (default []) when s has no field f or it is empty.
if nargin < 3, d = []; end
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
