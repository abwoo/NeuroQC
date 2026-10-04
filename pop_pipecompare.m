function [EEG, com, result] = pop_pipecompare(EEG, varargin)
%POP_PIPECOMPARE Compare preprocessing pipelines on the current dataset
%   (simple mode of PipeCompare).
%
%   [EEG, com] = pop_pipecompare(EEG);          % dialog
%   [EEG, com, result] = pop_pipecompare(EEG, 'measure', 'P3', ...
%       'events', {'11'}, 'recipe', 'standard');
%
%   'measure'  an ERP component with ERP CORE parameters (N170, MMN, N2pc,
%              N400, P3, LRP, ERN) or a frequency band of continuous data
%              (delta, theta, alpha, beta); see pipecompare.simple.Presets
%   'events'   ERP: the time-locking event types, one condition each
%   'recipe'   'filters' | 'standard': which steps are compared
%   'segment'  band power: segment length in s (default 2)
%   'show'     'on' (default) shows a progress window with a Stop button
%              (stopping keeps the pipelines already run) and opens the
%              results window; 'off' does neither
%
%   The dataset is not modified (EEG is returned unchanged); the result is
%   also stored in the base variable pipecompare_result. com is the command
%   that repeats this comparison (EEGLAB puts it in ALLCOM). The panel
%   (EEGLAB > Tools > PipeCompare > Advanced panel) offers every option.
com = ''; result = [];
assert(nargin >= 1 && ~isempty(EEG) && isfield(EEG, 'data') && ~isempty(EEG.data), 'PipeCompare:NoDataset', ...
    'pop_pipecompare needs a dataset (load one in EEGLAB first).');
if nargin < 2
    opts = pipecompare.gui.SimpleDialog.ask(EEG);
    if isempty(opts), return; end                       % cancelled, or continued in the panel
else
    opts = struct('measure', '', 'events', {{}}, 'recipe', '', 'segment', 2, 'show', 'on');
    for k = 1:2:numel(varargin)
        f = lower(char(varargin{k}));
        assert(isfield(opts, f), 'PipeCompare:Simple', 'Unknown option %s (measure, events, recipe, segment, show).', f);
        opts.(f) = varargin{k+1};
    end
    opts.events = cellstr(opts.events);
end
% the search reads the dataset that is current in EEGLAB: it must be this one
cur = pipecompare.live.Session.current();
assert(~isempty(cur) && strcmp(pipecompare.live.Session.fingerprint(cur), pipecompare.live.Session.fingerprint(EEG)), ...
    'PipeCompare:Simple', 'pop_pipecompare works on the current EEGLAB dataset; make this dataset current first.');
state = pipecompare.live.DataState.fromEEG(EEG);
c = pipecompare.simple.Presets.contract(EEG, opts.measure, opts.events, opts.segment);
[plan, notes] = pipecompare.simple.Presets.recipe(opts.recipe, state, c);
for k = 1:numel(notes), pipecompare.utils.log('Recipe %s: %s.', opts.recipe, notes{k}); end
runOpts = struct(); fig = gobjects(0); dlg = []; nDone = 0; nTotal = 0; t0 = tic;
if ~strcmp(opts.show, 'off')
    nTotal = numel(plan.enumerate(state, c, struct('maxLeaves', Inf)));
    fig = uifigure('Name', 'PipeCompare', 'Position', [300 300 460 150]);
    dlg = uiprogressdlg(fig, 'Title', 'Comparing pipelines', 'Cancelable', 'on', 'CancelText', 'Stop', ...
        'Message', sprintf('Running %d pipelines. The first one takes longest (it includes ICA when compared).', nTotal));
    runOpts.progress = @progress;
end
closeFig = onCleanup(@() delete(fig(isvalid(fig)))); %#ok<NASGU>   % also on an error
result = pipecompare.PipeCompare.optimize(plan, c, runOpts);
delete(fig(isvalid(fig)));
assignin('base', 'pipecompare_result', result);
args = {'measure', opts.measure};
if ~any(strcmpi(opts.measure, pipecompare.simple.Presets.bandNames())), args = [args {'events', opts.events}];
elseif opts.segment ~= 2, args = [args {'segment', opts.segment}]; end
args = [args {'recipe', opts.recipe}];
com = sprintf('EEG = pop_pipecompare(EEG, %s);', vararg2str(args));
if ~strcmp(opts.show, 'off'), pipecompare.gui.SimpleResults(result); end

    function stop = progress(n)
        % the Executor's progress callback: n more pipelines are finished
        if ~isvalid(dlg), stop = true; return; end   % the window was closed: stop as well
        nDone = nDone + n;
        if n > 0
            left = toc(t0) / nDone * (nTotal - nDone);
            if left < 90, when = sprintf('%.0f s', left); else, when = sprintf('%.0f min', left / 60); end
            dlg.Value = min(1, nDone / nTotal);
            dlg.Message = sprintf('%d of %d pipelines done, about %s left. Stop keeps the finished ones.', ...
                nDone, nTotal, when);
        end
        drawnow;
        stop = dlg.CancelRequested;
    end
end
