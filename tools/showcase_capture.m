function cap = showcase_capture(outFile)
%SHOWCASE_CAPTURE Run the documented showcase search on synthetic data and
%   write the numbers the README and site quote (metrics_capture.json).
%   Synthetic data only (tests/nqc_synth.m, fixed seed); nothing is typed by hand.
%   Then: python3 tools/inject.py --root . --staging . --capture <outFile> --test-log <log>
here = fileparts(fileparts(mfilename('fullpath')));
addpath(here); addpath(fullfile(here, 'tests'));
if nargin < 1, outFile = fullfile(tempdir, 'metrics_capture.json'); end
[EEG, truth] = nqc_synth();
nqc_setBase(EEG);
c = neuroqc.eval.Contract('conditions', {'target', {'11'}; 'standard', {'31'}}, ...
    'epoch', [-0.2 1.0], 'baseline', [-0.2 0], 'components', {'P3', [0.30 0.50], truth.roi});
hp = {0.1, 0.5, 1, 2}; lp = {20, 30}; uv = {75, 100, 150};
p = neuroqc.plan.Plan();
p = p.add('highpass', 'cutoff', hp); p = p.add('lowpass', 'cutoff', lp);
p = p.add('epoch'); p = p.add('baseline');
p = p.add('reject_threshold', 'uv', uv);
r = neuroqc.NeuroQC.optimize(p, c);
T = r.ranking.table;
st = T.status;
dist = contains(T.reason, 'amplitude changed') | contains(T.reason, 'artifactual') | contains(T.reason, 'latency shifted');
b = r.ranking.byStratum;
cap = struct();
cap.dataset = sprintf('%d channels, %.0f s, %d target / %d standard trials', EEG.nbchan, EEG.pnts / EEG.srate, ...
    sum(strcmp({EEG.event.type}, '11')), sum(strcmp({EEG.event.type}, '31')));
cap.grid = sprintf('%d high-pass x %d low-pass x %d rejection thresholds', numel(hp), numel(lp), numel(uv));
cap.nPipelines = numel(r.leaves);
cap.nIllegal = sum([r.report.rejected.count]);
cap.nNodes = r.report.nNodes;
cap.nStepsUnshared = r.report.nStepsUnshared;
cap.signalCheck = r.signalCheck;
cap.nFeasible = sum(strcmp(st, 'feasible'));
cap.nRejected = sum(strcmp(st, 'rejected'));
cap.nRejectedDistortion = sum(strcmp(st, 'rejected') & dist);
cap.nFailed = sum(strcmp(st, 'failed'));
cap.bestId = b(1).best;
cap.recommendedId = b(1).recommended;
cap.nNotDistinguished = numel(b(1).set);
cap.recommendedLabel = r.labels{b(1).recommended};
cap.version = neuroqc.NeuroQC.version();
cap.capturedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
fid = fopen(outFile, 'w'); fprintf(fid, '%s\n', jsonencode(cap, 'PrettyPrint', true)); fclose(fid);
fprintf('showcase capture written: %s\n', outFile);
end

