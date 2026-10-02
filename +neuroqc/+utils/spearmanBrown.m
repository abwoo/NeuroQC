function sb = spearmanBrown(r)
%SPEARMAN-BROWN  Unified split-half prophecy formula (single source of truth).
%   sb = neuroqc.utils.spearmanBrown(r)  ->  2r/(1+r)
%
%   Semantics:
%   - non-finite r -> NaN (unknown; downstream reports Unknown / missing metric)
%   - r <= 0       -> 0   (negative split-half correlation is evidence of noise,
%                          not consistency; the formula diverges at r = -1, so
%                          the value is floored at 0 to stay finite for the
%                          HardConstraints required-metric gate)
%   - 0 < r <= 1   -> classic 2r/(1+r)
%
%   Used by ERPAnalyzer.splitHalf and CandidateSession.measure; both must
%   agree so the same threshold tables apply everywhere.
if ~isnumeric(r) || ~isscalar(r) || ~isfinite(r)
    sb = NaN;
    return;
end
if r <= 0
    sb = 0;
else
    sb = 2 * r / (1 + r);
end
end
