function results = run_all(names)
%RUN_ALL Run the NeuroQC 0.7 test suite and print a summary.
%   results = run_all()              all suites
%   results = run_all({'test_plan'}) selected suites
%   Needs EEGLAB on the path. Set NEUROQC_REAL_SET to a real .set file
%   (never committed) to include the real-data test.
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here, '..'));
if nargin < 1
    names = {'test_history', 'test_plan', 'test_statistics', 'test_signal', 'test_engine', 'test_eeglab', 'test_legacy_invariants'};
end
results = [];
for k = 1:numel(names)
    results = [results, runtests(fullfile(here, [names{k} '.m']))]; %#ok<AGROW>
end
disp(table(results));
fprintf('\n%d passed, %d failed, %d incomplete (skipped) of %d\n', sum([results.Passed]), ...
    sum([results.Failed]), sum([results.Incomplete]), numel(results));
% machine-readable line for tools/inject.py (skipped tests count as not passed)
fprintf('TOTAL=%d PASSED=%d FAILED=%d\n', numel(results), sum([results.Passed]), ...
    numel(results) - sum([results.Passed]));
end
