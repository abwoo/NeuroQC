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
%   'channels' 'custom' and 'band': electrode labels ('band': all EEG
%              channels when omitted)
%   'events'   ERP: the time-locking event types, one condition each
%   'pool'     ERP: true scores all the event types as one condition
%              (default false)
%   'left', 'right'  N2pc and LRP, scored contralateral minus ipsilateral
%              as in ERP CORE: the event types with the target on the left
%              / of left-hand responses, and of the right (instead of
%              'events'; one side may be left out)
%   'recipe'   'standard' (default) | 'filters': which steps are compared
%   'reference' 'asis' (default) | 'average': the average reference as a
%              fixed step of every pipeline, after the bad channels and
%              before ICA (channels typed as EOG, ECG, ... are left out of
%              the average)
%   'segment'  band power: segment length in s (default 2)
%   'show'     'on' (default) shows a progress window with a Stop button
%              (stopping keeps the pipelines already run) and opens the
%              results window; 'off' does neither
%
%   The Command Window shows a short summary; the full log (every EEGLAB
%   command of every pipeline) goes to pipecompare_last_run.log in
%   tempdir. The dataset is not modified (EEG is returned unchanged); the
%   result is also stored in the base variable pipecompare_result. com is the command
%   that repeats this comparison (EEGLAB puts it in ALLCOM). The panel
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
        'channels', {{}}, 'recipe', 'standard', 'reference', 'asis', 'segment', 2, 'show', 'on');
    for k = 1:2:numel(varargin)
        f = lower(char(varargin{k}));
        assert(isfield(opts, f), 'PipeCompare:Simple', ['Unknown option %s (measure, events, left, right, pool, window, ', ...
            'band, channels, recipe, reference, segment, show).'], f);
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
assert(~(state.isEpoched && pipecompare.simple.Presets.isBand(opts.measure)), 'PipeCompare:Simple', ['Band power is ', ...
    'compared on continuous recordings (e.g. resting state); this dataset is already cut into epochs. Choose an ERP ', ...
    'measure, or use the continuous data.']);
events = opts.events;
if pipecompare.simple.Presets.isLateral(opts.measure), events = struct('left', {opts.left}, 'right', {opts.right}); end
c = pipecompare.simple.Presets.contract(EEG, opts.measure, events, opts.segment, opts.pool, ...
    struct('window', opts.window, 'band', opts.band, 'channels', {cellstr(opts.channels)}));
[plan, notes] = pipecompare.simple.Presets.recipe(opts.recipe, state, c, opts.reference, ...
    pipecompare.simple.Presets.nonEegChannels(EEG));
for k = 1:numel(notes), pipecompare.utils.log('Recipe %s: %s.', opts.recipe, notes{k}); end
nTotal = numel(plan.enumerate(state, c, struct('maxLeaves', Inf)));
assert(nTotal > 1, 'PipeCompare:Simple', 'On these data the recipe ''%s'' gives %d pipeline, so there is nothing to compare%s.', ...
    opts.recipe, nTotal, pipecompare.utils.ternary(isempty(notes), '', [': ' strjoin(notes, '; ')]));
% the unit judged from the amplitude scale, as in the panel: rejection
% thresholds in uV would remove nothing from data stored in V
runOpts = struct('dataUnit', state.unitGuess);
if strcmp(state.unitGuess, 'V'), pipecompare.utils.log('The data are in volts (judged from the amplitude scale); they are compared in uV.'); end
fig = gobjects(0); dlg = []; nDone = 0; t1 = []; stopping = false;
if ~strcmp(opts.show, 'off')
    first = 'the first one runs every step from the start';
    if any(strcmp({plan.Slots.id}, 'ica')), first = 'ICA is fitted first (once; the slow part)'; end
    fig = uifigure('Name', 'PipeCompare', 'Position', [300 300 460 150]);
    dlg = uiprogressdlg(fig, 'Title', 'Comparing pipelines', 'Cancelable', 'on', 'CancelText', 'Stop', ...
        'Message', sprintf('Running %d pipelines; %s.', nTotal, first));
    runOpts.progress = @progress;
end
closeFig = onCleanup(@() delete(fig(isvalid(fig)))); %#ok<NASGU>   % also on an error
% the full log goes to a file; the Command Window gets the summary
t0 = tic; err = []; searchFcn = @runSearch;   % (evalc here may only assign existing variables)
logText = evalc('[result, err] = searchFcn(plan, c, runOpts);');
delete(fig(isvalid(fig)));
logFile = fullfile(tempdir, 'pipecompare_last_run.log');
fid = fopen(logFile, 'w');
if fid > 0, fprintf(fid, '%s', logText); fclose(fid); end
if ~isempty(err)
    % the log says how far the search got; it would be lost with the error
    if fid > 0, pipecompare.utils.log('The comparison stopped with an error; full log: %s', logFile); end
    rethrow(err);
end
T = result.ranking.table;
pipecompare.utils.log('%d pipelines compared on %s in %s; %d passed the checks%s.', height(T), state.setname, ...
    timeText(toc(t0)), sum(strcmp(T.status, 'feasible')), pipecompare.utils.ternary(isempty(result.ranking.recommended), ...
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
if fid > 0, pipecompare.utils.log('Full log (every EEGLAB command): %s', logFile); end
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
args = [args {'recipe', opts.recipe}];
if strcmp(opts.reference, 'average'), args = [args {'reference', 'average'}]; end
com = sprintf('EEG = pop_pipecompare(EEG, %s);', vararg2str(args));
if ~strcmp(opts.show, 'off'), pipecompare.gui.SimpleResults(result); end

    function stop = progress(n)
        % the Executor's progress callback: n more pipelines are finished
        if ~isvalid(dlg), stop = true; return; end   % the window was closed: stop as well
        nDone = nDone + n;
        if n > 0 && ~stopping
            % the time after the first pipeline: it alone runs the shared
            % steps (ICA included), so it would inflate the estimate
            if isempty(t1), t1 = tic; end
            dlg.Value = min(1, nDone / nTotal);
            if nDone >= nTotal
                dlg.Message = 'All pipelines done; ranking them...';
            elseif nDone < 3
                dlg.Message = sprintf('%d of %d pipelines done; estimating the time left...', nDone, nTotal);
            else
                dlg.Message = sprintf('%d of %d pipelines done, about %s left. Stop keeps the finished ones.', ...
                    nDone, nTotal, timeText(toc(t1) / (nDone - 1) * (nTotal - nDone)));
            end
        end
        drawnow;
        stop = dlg.CancelRequested;
        if stop && ~stopping, stopping = true; dlg.Message = 'Stopping after the current step...'; drawnow; end
    end
end

function [result, err] = runSearch(plan, c, runOpts)
% The search, with its error returned rather than thrown, so that the log
% captured around it is written either way.
result = []; err = [];
try
    result = pipecompare.PipeCompare.optimize(plan, c, runOpts);
catch err
end
end

function t = timeText(sec)
% 'about 40 s', '12 min', '2 h 10 min'
if sec < 90, t = sprintf('%.0f s', sec);
elseif sec < 3600, t = sprintf('%.0f min', sec / 60);
else, t = sprintf('%d h %d min', floor(sec / 3600), round(mod(sec, 3600) / 60)); end
end
