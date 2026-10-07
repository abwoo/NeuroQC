function [EEG, com, result] = pop_pipecompare(EEG, varargin)
%POP_PIPECOMPARE Compare preprocessing pipelines on the current dataset
%   (simple mode of PipeCompare).
%
%   [EEG, com] = pop_pipecompare(EEG);          % dialog
%   [EEG, com, result] = pop_pipecompare(EEG, 'measure', 'P3', ...
%       'events', {'target'}, 'recipe', 'standard');
%
%   'measure'  an ERP component with ERP CORE parameters (N170, MMN, N2pc,
%              N400, P3, LRP, ERN), a frequency band of continuous data
%              (delta, theta, alpha, beta), 'custom' (your own ERP window
%              and electrodes) or 'band' (your own band and electrodes);
%              see pipecompare.simple.Presets
%   'window'   'custom': [start end] in s after the event, e.g. [0.3 0.6]
%   'band'     'band': [low high] in Hz, e.g. [8 12]
%   'channels' electrode labels, averaged: required for 'custom'; for
%              'band' and the preset bands all EEG channels when omitted;
%              for an ERP component, instead of its ERP CORE site(s) (not
%              N2pc and LRP)
%   'events'   ERP: the time-locking event types, one condition each
%   'pool'     ERP: true scores all the event types as one condition
%              (default false)
%   'left', 'right'  N2pc and LRP, scored contralateral minus ipsilateral
%              as in ERP CORE: the event types with the target on the left
%              / of left-hand responses, and of the right (instead of
%              'events'; one side may be left out)
%   'recipe'   'standard' (default) | 'filters': which steps are compared
%              (standard: all the steps below; filters: the two filters)
%   'steps'    instead of 'recipe', any of 'badchannels', 'ica',
%              'highpass', 'lowpass', 'reject' (epoch rejection),
%              'epochinterp' (with 'reject': an epoch with at most 3
%              channels over the limit keeps them, interpolated within the
%              epoch, instead of being rejected), e.g.
%              {'highpass', 'lowpass', 'reject'}; they always run in that
%              order, with epoching and baseline in every pipeline
%   'reference' 'asis' (default) | 'average': the average reference as a
%              fixed step of every pipeline, after the bad channels and
%              before ICA (channels typed as EOG, ECG, ... and ear or
%              mastoid channels such as A1, A2, M1, M2 are left out of
%              the average)
%   'segment'  band power: segment length in s (default 2)
%   'show'     'on' (default) shows a progress window with a Stop button
%              (stopping keeps the pipelines already run) and opens the
%              results window; 'off' does neither
%
%   Before the run, the montage check (pipecompare.live.Montage) names
%   channels that do not resemble their neighbours (labels that may not
%   match the positions); after it, a note when ICA did nothing useful or
%   had too little data (Presets.icaText), and when one channel caused
%   most rejected epochs (Presets.rejectText). The Command Window shows each step and pipeline as
%   it runs, then a summary; the same log (every EEGLAB command of every pipeline) is kept
%   in pipecompare_last_run.log in tempdir. The dataset is not modified
%   (EEG is returned unchanged); the result is also stored in the base
%   variable pipecompare_result. com is the command that repeats this
%   comparison (EEGLAB puts it in ALLCOM). The panel
%   (EEGLAB > Tools > PipeCompare > Advanced panel) offers every option.
com = ''; result = [];
assert(nargin >= 1 && ~isempty(EEG) && isfield(EEG, 'data'), 'PipeCompare:NoDataset', ...
    'pop_pipecompare needs a dataset (load one in EEGLAB first).');
assert(isscalar(EEG), 'PipeCompare:NoDataset', 'Several datasets are selected in EEGLAB; select one.');
assert(~isempty(EEG.data), 'PipeCompare:NoDataset', 'pop_pipecompare needs a dataset (load one in EEGLAB first).');
if nargin < 2
    opts = pipecompare.gui.SimpleDialog.ask(EEG);
    if isempty(opts), return; end                       % cancelled, or continued in the panel
else
    opts = struct('measure', '', 'events', {{}}, 'left', {{}}, 'right', {{}}, 'pool', false, 'window', [], 'band', [], ...
        'channels', {{}}, 'recipe', 'standard', 'steps', {{}}, 'reference', 'asis', 'segment', 2, 'show', 'on');
    for k = 1:2:numel(varargin)
        f = lower(char(varargin{k}));
        assert(isfield(opts, f), 'PipeCompare:Simple', ['Unknown option %s (measure, events, left, right, pool, window, ', ...
            'band, channels, recipe, steps, reference, segment, show).'], f);
        opts.(f) = varargin{k+1};
    end
    for f = {'events', 'left', 'right'}
        v = opts.(f{1});
        if isnumeric(v), v = arrayfun(@(x) sprintf('%g', x), v, 'UniformOutput', false); end
        opts.(f{1}) = cellstr(v);
    end
    assert(~pipecompare.simple.Presets.isLateral(opts.measure) || isempty(opts.events), 'PipeCompare:Simple', ['%s is contralateral minus ipsilateral: give ', ...
        'the event types of each side with ''left'' and ''right'' instead of ''events''.'], opts.measure);
end
% the search reads the dataset that is current in EEGLAB: it must be this one
cur = pipecompare.live.Session.current();
assert(~isempty(cur) && strcmp(pipecompare.live.Session.fingerprint(cur), pipecompare.live.Session.fingerprint(EEG)), ...
    'PipeCompare:Simple', 'pop_pipecompare works on the current EEGLAB dataset; make this dataset current first.');
state = pipecompare.live.DataState.fromEEG(EEG);
% what was done to the data before (the hint for raw data is the dialog's)
advice = pipecompare.simple.Presets.dataAdvice(state);
advice = advice(~startsWith(advice, 'Start from the raw'));
for k = 1:numel(advice), pipecompare.utils.log('%s', advice{k}); end
mon = pipecompare.live.Montage.check(EEG);
if ~isempty(mon.text), pipecompare.utils.log('%s', mon.text); end
assert(~(state.isEpoched && pipecompare.simple.Presets.isBand(opts.measure)), 'PipeCompare:Simple', ['Band power is ', ...
    'compared on continuous recordings (e.g. resting state); this dataset is already cut into epochs. Choose an ERP ', ...
    'measure, or use the continuous data.']);
events = opts.events;
if pipecompare.simple.Presets.isLateral(opts.measure), events = struct('left', {opts.left}, 'right', {opts.right}); end
c = pipecompare.simple.Presets.contract(EEG, opts.measure, events, opts.segment, opts.pool, ...
    struct('window', opts.window, 'band', opts.band, 'channels', {cellstr(opts.channels)}));
% the steps compared: those given, else the recipe's (in the order they run)
if ~isempty(opts.steps) || isempty(opts.recipe)
    steps = pipecompare.simple.Presets.recipeSteps(cellstr(opts.steps));
else
    steps = pipecompare.simple.Presets.recipeSteps(opts.recipe);
end
recipe = pipecompare.simple.Presets.recipeOf(steps);
[plan, notes] = pipecompare.simple.Presets.recipe(steps, state, c, opts.reference, ...
    pipecompare.simple.Presets.nonEegChannels(EEG));
for k = 1:numel(notes), pipecompare.utils.log('Left out: %s.', notes{k}); end
nTotal = numel(plan.enumerate(state, c, struct('maxLeaves', Inf)));
assert(nTotal > 1, 'PipeCompare:Simple', 'On these data the steps chosen (%s) give %d pipeline, so there is nothing to compare%s.', ...
    strjoin(steps, ', '), nTotal, pipecompare.utils.ternary(isempty(notes), '', [': ' strjoin(notes, '; ')]));
% the unit judged from the amplitude scale, as in the panel: rejection
% thresholds in uV would remove nothing from data stored in V
runOpts = struct('dataUnit', state.unitGuess);
if strcmp(state.unitGuess, 'V'), pipecompare.utils.log('The data are in volts (judged from the amplitude scale); they are compared in uV.'); end
prog = pipecompare.gui.Progress.empty;
if ~strcmp(opts.show, 'off')
    prog = pipecompare.gui.Progress(nTotal, any(strcmp({plan.Slots.id}, 'ica')));
    runOpts.progress = @(n, varargin) prog.step(n, varargin{:});
end
closeProg = onCleanup(@() delete(prog)); %#ok<NASGU>   % also on an error
% the search prints as it goes, and the same text is kept in a log file
t0 = tic;
logFile = fullfile(tempdir, 'pipecompare_last_run.log');
if isfile(logFile), delete(logFile); end   % (the diary appends)
logging = keepDiary(logFile);
[result, err] = runSearch(plan, c, runOpts);
clear logging   % the diary stops here
delete(prog);
hasLog = isfile(logFile);
if ~isempty(err)
    % the log says how far the search got
    if hasLog, pipecompare.utils.log('The comparison stopped with an error; full log: %s', logFile); end
    rethrow(err);
end
T = result.ranking.table;
pipecompare.utils.log('%d pipelines compared on %s in %s; %d passed the checks%s.', height(T), state.setname, ...
    pipecompare.gui.Progress.timeText(toc(t0)), sum(strcmp(T.status, 'feasible')), pipecompare.utils.ternary(isempty(result.ranking.recommended), ...
    '', sprintf('; recommended: pipeline %d', result.ranking.recommended)));
if pipecompare.eval.Rank.sameScores(result.ranking)
    pipecompare.utils.log('All pipelines that passed have the same noise: the settings compared make no difference on these data.');
end
n = result.ref.n; d = pipecompare.eval.Rank.defaults();
if isempty(result.ranking.recommended) && ~opts.pool && ~pipecompare.simple.Presets.isLateral(opts.measure) && ...
        numel(n) > 1 && any(n < d.minTrials) && sum(n) >= d.minTrials
    pipecompare.utils.log(['Each condition needs at least %d trials (here %s). If these event types are one condition ', ...
        '(e.g. one code per block), add ''pool'', true.'], d.minTrials, strjoin(arrayfun(@(k) sprintf('%s: %d', ...
        result.ref.names{k}, n(k)), 1:numel(n), 'UniformOutput', false), ', '));
end
hint = pipecompare.simple.Presets.nextStep(result);
if ~isempty(hint), pipecompare.utils.log('%s', hint); end
detect = pipecompare.simple.Presets.detectableText(result);
if ~isempty(detect), pipecompare.utils.log('%s', detect); end
ica = pipecompare.simple.Presets.icaText(result);
if ~isempty(ica), pipecompare.utils.log('%s', ica); end
rej = pipecompare.simple.Presets.rejectText(result);
if ~isempty(rej), pipecompare.utils.log('%s', rej); end
did = pipecompare.simple.Presets.stepsText(result, result.ranking.recommended);
if ~isempty(did), pipecompare.utils.log('Pipeline %d, step by step:%s', result.ranking.recommended, sprintf('\n  %s', did{:})); end
% filters applied before PipeCompare are outside the pipelines' signal check
try
    result.priorFilters = pipecompare.eval.Injection.priorFilters(result.root, c, state, result.options);
catch ME
    result.priorFilters = [];
    pipecompare.utils.log('The filters applied before PipeCompare were not checked (%s).', ME.message);
end
prior = pipecompare.simple.Presets.priorFilterText(result);
if ~isempty(prior), pipecompare.utils.log('%s', prior); end
if hasLog, pipecompare.utils.log('Full log (every EEGLAB command): %s', logFile); end
assignin('base', 'pipecompare_result', result);
args = {'measure', opts.measure};
if strcmpi(opts.measure, 'custom'), args = [args {'window', opts.window}]; end
if strcmpi(opts.measure, 'band'), args = [args {'band', opts.band}]; end
if ~isempty(opts.channels), args = [args {'channels', cellstr(opts.channels)}]; end
if pipecompare.simple.Presets.isLateral(opts.measure)
    if ~isempty(opts.left), args = [args {'left', opts.left}]; end
    if ~isempty(opts.right), args = [args {'right', opts.right}]; end
elseif ~pipecompare.simple.Presets.isBand(opts.measure)
    args = [args {'events', opts.events}];
    if opts.pool, args = [args {'pool', true}]; end
elseif opts.segment ~= 2, args = [args {'segment', opts.segment}]; end
if isempty(recipe), args = [args {'steps', steps}]; else, args = [args {'recipe', recipe}]; end
if strcmp(opts.reference, 'average'), args = [args {'reference', 'average'}]; end
if strcmp(opts.show, 'off'), args = [args {'show', 'off'}]; end
com = sprintf('EEG = pop_pipecompare(EEG, %s);', vararg2str(args));
if ~strcmp(opts.show, 'off'), pipecompare.gui.SimpleResults(result); end
end

function restore = keepDiary(logFile)
% The Command Window's text also goes to logFile until restore is cleared;
% a diary the user had on goes on afterwards.
was = get(0, 'Diary'); file = get(0, 'DiaryFile');
diary(logFile);
restore = onCleanup(@() restoreDiary(was, file));
end

function restoreDiary(was, file)
diary off;
set(0, 'DiaryFile', file);
if strcmp(char(was), 'on'), diary on; end
end

function [result, err] = runSearch(plan, c, runOpts)
% The search, with its error returned rather than thrown, so that the
% log's location can be printed before the error.
result = []; err = [];
try
    result = pipecompare.PipeCompare.optimize(plan, c, runOpts);
catch err
end
end
