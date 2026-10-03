function r = estimateRank(data)
%estimateRank Numerical rank of data matrix (channels x samples)
%   Used to constrain ICA dimensionality after average reference /
%   interpolation / projection.
%   Definition: rank of data after removing near-zero singular values.
%   Threshold: s(i) > s(1) * max(size(data)) * eps(class(data)) is too
%   strict for noisy EEG; we use a relative tolerance of 1e-6 * s(1).

    if isempty(data)
        r = 0;
        return;
    end
    
    X = double(data);
    if ndims(X) == 3
        X = reshape(X, size(X,1), []);
    end
    
    % Use economy SVD on covariance for speed when many samples
    [nch, nsamp] = size(X);
    if nsamp > nch
        C = X * X';
        s = svd(C);
        s = sqrt(max(s, 0));
    else
        s = svd(X, 0);
    end
    
    if isempty(s) || s(1) == 0
        r = 0;
        return;
    end
    
    tol = max(nch, nsamp) * eps(max(s));
    relTol = 1e-6 * s(1);
    thr = max(tol, relTol);
    r = sum(s > thr);
    r = min(r, nch);
end