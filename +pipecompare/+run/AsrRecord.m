classdef AsrRecord
    %ASRRECORD The decisions ASR took on the real data, to apply them elsewhere.
    %
    %   rec = pipecompare.run.AsrRecord.record(EEG, cutoff)
    %   Y   = pipecompare.run.AsrRecord.apply(rec, X)
    %
    %   ASR (Kothe & Makeig; clean_rawdata's clean_asr / asr_process) cleans
    %   a recording window by window: at every update point it decides,
    %   from the covariance of the (look-ahead) data, which principal
    %   components exceed the calibrated threshold and builds a
    %   reconstruction matrix R; between update points it blends the
    %   previous and the new R with a raised cosine. Given the sequence of
    %   R, the operation is linear. record() recomputes that sequence for
    %   the call PipeCompare makes (pop_clean_rawdata with only the burst
    %   criterion, Euclidean distance, MaxMem from maxMemMB), using clean_rawdata's own
    %   calibration (clean_windows, asr_calibrate); apply() applies the same
    %   decisions to any data of the same size (e.g. the injected signal).
    %
    %   Written against clean_rawdata 2.11 (ASR core 0.13: asr_calibrate
    %   state fields M, T, A, B, iir, last_trivial; asr_process blocks,
    %   moving-average covariance and raised-cosine blending). After a
    %   clean_rawdata update, re-run test_engine/testAsrDecisionsAreReplayed-
    %   OnTheSignalCopy: it checks the replay against EEGLAB's output.
    %
    %   This is an independent implementation of the published algorithm,
    %   not a copy of asr_process. Its decisions are only used after
    %   pipecompare.run.Steps has checked that apply(rec, real data) equals
    %   EEGLAB's own output; otherwise ASR is re-run (and flagged).

    properties (Constant)
        MaxStoredMB = 300      % above this the decisions are not stored
    end

    methods (Static)
        function mb = maxMemMB(C, fs)
            % 'MaxMem' passed to pop_clean_rawdata: 64 MB, or more when ASR's
            % lookahead buffer (C*C*P*24 bytes) needs it. clean_rawdata
            % before 2.8 (EEGLAB 2022) stops with "Not enough memory"
            % instead of raising it (many channels or high sampling rates).
            P = round(max(0.5, 1.5 * C / fs) / 2 * fs);
            mb = max(64, ceil(2 * C * C * P * 24 / 2^20));
        end

        function rec = record(EEG, cutoff)
            % Same defaults as clean_asr when called by clean_artifacts.
            X0 = double(EEG.data);
            [C, n] = size(X0); fs = EEG.srate;
            windowlen = max(0.5, 1.5 * C / fs);
            stepsize = floor(fs * windowlen / 2);
            maxdims = round(C * 0.66);
            sig = EEG; sig.data = X0;
            [~, ref] = evalc('clean_windows(sig, 0.075, [-inf 5.5], 1)');
            if exist('hlp_diskcache', 'file')
                [~, state] = evalc('hlp_diskcache(''filterdesign'', @asr_calibrate, ref.data, ref.srate, cutoff)');
            else
                [~, state] = evalc('asr_calibrate(ref.data, ref.srate, cutoff, [], [], [], [], [], [], [], pipecompare.run.AsrRecord.maxMemMB(C, fs))');
            end
            pad = round(windowlen / 2 * fs);
            S = n + pad;
            P = round(windowlen / 2 * fs);
            N = round(max(windowlen, 1.5 * C / fs) * fs);
            sigData = padded(X0, pad);
            carry = repmat(2 * sigData(:, 1), 1, P) - sigData(:, 1 + mod(((P + 1):-1:2) - 1, S));
            D = [carry sigData]; D(~isfinite(D)) = 0;
            maxmem = pipecompare.run.AsrRecord.maxMemMB(C, fs);
            assert(maxmem * 1024 * 1024 - C * C * P * 8 * 3 >= 0, 'PipeCompare:Asr', 'ASR memory split not reproducible.');
            splits = ceil((C*C*S*8*8 + C*C*8*S/stepsize + C*S*8*2 + S*8*5) / (maxmem*1024*1024 - C*C*P*8*3));
            splits = min(splits, 10000);
            iir = state.iir; cov = []; lastR = []; lastTrivial = state.last_trivial;
            up = struct('n', {}, 'R', {}, 'trivial', {});
            stored = 0;
            for i = 1:splits
                range = 1 + floor((i - 1) * S / splits):min(S, floor(i * S / splits));
                if isempty(range), continue; end
                [Xf, iir] = filter(state.B, state.A, D(:, range + P), iir, 2);
                [Xcov, cov] = movingAverage(N, reshape(bsxfun(@times, reshape(Xf, 1, C, []), reshape(Xf, C, 1, [])), C * C, []), cov);
                updateAt = min(stepsize:stepsize:(size(Xcov, 2) + stepsize - 1), size(Xcov, 2));
                if isempty(lastR)
                    updateAt = [1 updateAt]; lastR = eye(C);
                end
                Xcov = reshape(Xcov(:, updateAt), C, C, []);
                for j = 1:numel(updateAt)
                    [V, Dg] = eig(Xcov(:, :, j));
                    [Dg, order] = sort(reshape(diag(Dg), 1, C)); V = V(:, order);
                    keep = Dg < sum((state.T * V) .^ 2) | (1:C) < (C - maxdims);
                    trivial = all(keep);
                    if ~trivial
                        R = real(state.M * pinv(bsxfun(@times, keep', V' * state.M)) * V');
                        stored = stored + C * C * 8;
                        assert(stored < pipecompare.run.AsrRecord.MaxStoredMB * 2^20, 'PipeCompare:AsrTooLarge', ...
                            'ASR changed too many windows to store its decisions.');
                    else
                        R = [];
                    end
                    up(end+1) = struct('n', range(updateAt(j)), 'R', R, 'trivial', trivial); %#ok<AGROW>
                    lastTrivial = trivial;
                end
            end
            rec = struct('C', C, 'n', n, 'pad', pad, 'P', P, 'S', S, 'updates', up, ...
                'initialTrivial', state.last_trivial, 'cutoff', cutoff);
        end

        function Y = apply(rec, X)
            % The recorded ASR decisions applied to data X (C x n).
            X = double(X);
            assert(isequal(size(X), [rec.C rec.n]), 'PipeCompare:Asr', 'Data size differs from the recorded ASR run.');
            sigData = padded(X, rec.pad);
            P = rec.P; S = rec.S;
            carry = repmat(2 * sigData(:, 1), 1, P) - sigData(:, 1 + mod(((P + 1):-1:2) - 1, S));
            D = [carry sigData]; D(~isfinite(D)) = 0;
            lastR = eye(rec.C); lastTrivial = rec.initialTrivial; lastN = 0;
            for j = 1:numel(rec.updates)
                u = rec.updates(j);
                R = u.R; if u.trivial, R = eye(rec.C); end
                if ~u.trivial || ~lastTrivial
                    sub = (lastN + 1):u.n;
                    blend = (1 - cos(pi * (1:numel(sub)) / numel(sub))) / 2;
                    D(:, sub) = bsxfun(@times, blend, R * D(:, sub)) + bsxfun(@times, 1 - blend, lastR * D(:, sub));
                end
                lastN = u.n; lastR = R; lastTrivial = u.trivial;
            end
            Y = D(:, 1:(end - P));
            Y(:, 1:P) = [];
        end
    end
end

function sig = padded(X, pad)
% the reflected extension clean_asr appends before processing
sig = [X bsxfun(@minus, 2 * X(:, end), X(:, (end - 1):-1:end - pad))];
end

function [Y, Zf] = movingAverage(N, X, Zi)
% running mean over N samples along dimension 2 with carried state
if isempty(Zi), Zi = zeros(size(X, 1), N); end
Yz = [Zi X]; M = size(Yz, 2);
I = [1:M-N; 1+N:M];
Sg = [-ones(1, M-N); ones(1, M-N)] / N;
Y = cumsum(bsxfun(@times, Yz(:, I(:)), Sg(:)'), 2);
Y = Y(:, 2:2:end);
Zf = [-(Y(:, end) * N - Yz(:, end-N+1)) Yz(:, end-N+2:end)];
end
