function c = nqc_cand(X, varargin)
%NQC_CAND Synthetic candidate record for Rank tests.
%   X: cell (objectives) of cell (conditions) of score vectors (NaN = trial
%   not retained); or a single vector (one objective, one condition).
%   Options: 'kind' (cell of kinds), 'times', 'stratum', 'signal'.
if ~iscell(X), X = {{X}}; elseif ~iscell(X{1}), X = {X}; end
o = struct('kind', {repmat({'scalar'}, 1, numel(X))}, 'times', [], 'stratum', '', 'signal', [], 'key', '', ...
    'polarity', 'positive', 'units', {repmat({'uV'}, 1, numel(X))});
for k = 1:2:numel(varargin), o.(varargin{k}) = varargin{k+1}; end
opts = neuroqc.eval.Measure.defaults();
objs = struct('name', {}, 'unit', {}, 'kind', {}, 'polarity', {}, 'times', {}, 'X', {}, 'estimate', {}, 'sme', {}, 'agg', {});
for k = 1:numel(X)
    ob = struct('name', sprintf('obj%d', k), 'unit', o.units{k}, 'kind', o.kind{k}, 'polarity', o.polarity, ...
        'times', o.times, 'X', {X{k}}, 'estimate', [], 'sme', [], 'agg', NaN);
    for cc = 1:numel(X{k})
        [ob.estimate(cc), ob.sme(cc)] = neuroqc.eval.Measure.estimate(ob, X{k}{cc}, opts, k * 1000 + cc);
    end
    ob.agg = sqrt(mean(ob.sme .^ 2));
    objs(k) = ob;
end
first = X{1};
kept = cellfun(@(x) sum(~isnan(x(:, 1))), first); n = cellfun(@(x) size(x, 1), first);
m = struct('kept', kept, 'retention', kept ./ n, 'extraTrials', 0, 'objectives', objs, ...
    'composite', sqrt(mean([objs.sme] .^ 2)), 'baselineSd', NaN, 'artifactPct', 0);
sig = o.signal;
if isempty(sig)
    sig = struct('source', 'test', 'amplitudeError', 0, 'latencyShiftMs', 0, 'artifactPct', 0, ...
        'waveformCorr', 1, 'topoCorr', NaN, 'chain', '');
end
c = struct('id', 0, 'key', o.key, 'stratum', o.stratum, 'status', 'ok', 'message', '', 'm', m, 'signal', sig, ...
    'interpolatedFraction', 0, 'icsRemoved', 0, 'rejectedEpochs', 0, 'coms', {{}}, 'seconds', 0, 'unmatched', {{}});
end
