function [psd, f] = psdMedian(EEG, chanIdx)
%psdMedian Median Welch PSD across selected channels
    X = double(EEG.data);
    if ndims(X) == 3, X = reshape(X, size(X,1), []); end
    if nargin < 2 || isempty(chanIdx)
        chanIdx = round(linspace(1, size(X,1), min(8, size(X,1))));
    end
    nfft = 2^nextpow2(min(4096, size(X,2)));
    fs = EEG.srate;
    f = (0:nfft/2) * fs / nfft;
    P = zeros(numel(chanIdx), numel(f));
    for k = 1:numel(chanIdx)
        p = pwelch(X(chanIdx(k),:), [], [], nfft, fs);
        P(k,:) = p(:)';
    end
    psd = median(P, 1);
end