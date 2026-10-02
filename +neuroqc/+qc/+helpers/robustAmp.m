function a = robustAmp(data)
%robustAmp Robust amplitude estimate (median of per-channel 95th pct |x|)
    X = double(data);
    if ndims(X) == 3, X = reshape(X, size(X,1), []); end
    a = median(prctile(abs(X), 95, 2));
end