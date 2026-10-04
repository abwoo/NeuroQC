function o = withDefaults(o, d)
%WITHDEFAULTS Fields of d that o does not set, added to o.
for f = fieldnames(d)'
    if ~isfield(o, f{1}), o.(f{1}) = d.(f{1}); end
end
end
