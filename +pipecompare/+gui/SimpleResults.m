classdef SimpleResults < handle
    %SIMPLERESULTS Result window of the simple mode.
    %
    %   pipecompare.gui.SimpleResults(result)
    %
    %   First line, in plain words: the recommended pipeline and why; below,
    %   a table of the recommendation (marked *) followed by the best of the
    %   others. "Use this pipeline" stores the recommended (or the selected)
    %   candidate as a new EEGLAB dataset; Save script writes it as a
    %   function for any recording; "Show all pipelines" lists every
    %   pipeline with the reason it was excluded. With no
    %   feasible pipeline, the most common reason is said in one line; after
    %   a stop, how many pipelines were run.

    properties
        Result
        Fig; Headline; Table; AllBox
    end

    methods
        function obj = SimpleResults(result)
            obj.Result = result;
            obj.Fig = uifigure('Name', 'Pipeline comparison', 'Position', [220 220 900 380]);
            g = uigridlayout(obj.Fig, [4 1]); g.RowHeight = {66, '1x', 22, 30};
            obj.Headline = uilabel(g, 'Text', obj.headline(), 'WordWrap', 'on', 'FontWeight', 'bold', ...
                'VerticalAlignment', 'top');
            obj.Table = uitable(g, 'RowName', {});
            obj.showRows();
            uilabel(g, 'Text', obj.shared(), 'FontColor', [0.3 0.3 0.3]);
            b = uigridlayout(g, [1 4]); b.Padding = [0 0 0 0]; b.ColumnWidth = {'1x', 150, 140, 120};
            uilabel(b, 'Text', 'Select a row to use another pipeline.', 'FontColor', [0.4 0.4 0.4]);
            obj.AllBox = uicheckbox(b, 'Text', 'Show all pipelines', 'ValueChangedFcn', @(~, ~) obj.showRows());
            uibutton(b, 'Text', 'Use this pipeline', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.adopt());
            uibutton(b, 'Text', 'Save script...', 'ButtonPushedFcn', @(~, ~) obj.saveScript());
        end

        function t = headline(obj)
            R = obj.Result.ranking; T = R.table;
            nFeas = sum(strcmp(T.status, 'feasible'));
            t = '';
            if isfield(obj.Result, 'notRun') && obj.Result.notRun > 0
                t = sprintf('Stopped after %d of %d pipelines; this covers those. ', height(T) - obj.Result.notRun, height(T));
            end
            if isempty(R.byStratum)
                common = pipecompare.eval.Rank.commonReasons(R, 1);
                t = sprintf('%sNo pipeline passed the checks. Most common reason: %s.', t, ...
                    pipecompare.utils.ternary(isempty(common), 'see Show all pipelines', strjoin(common, '')));
                % the reason with its numbers, from one pipeline
                k = find(~strcmp(T.status, 'feasible') & ~cellfun(@isempty, R.whyList(:)), 1);
                if ~isempty(k), t = sprintf('%s For example, pipeline %d: %s.', t, k, strjoin(R.whyList{k}, '; ')); end
                hint = pipecompare.simple.Presets.nextStep(obj.Result);
                if ~isempty(hint), t = sprintf('%s %s', t, hint); end
            elseif numel(R.byStratum) > 1
                t = sprintf(['%sThese pipelines use different references, which measure different things, so there is ', ...
                    'one recommendation per reference: pipelines %s. Use the one that matches your analysis.'], ...
                    t, strjoin(arrayfun(@num2str, [R.byStratum.recommended], 'UniformOutput', false), ', '));
            else
                k = R.recommended; b = R.byStratum;
                kept = pipecompare.gui.PanelText.pctText(T.minRetention(k));
                if pipecompare.eval.Rank.sameScores(R)
                    t = sprintf(['%sUse pipeline %d: %s. All pipelines that passed the checks have exactly the same ', ...
                        'noise: on these data the settings compared make no difference.'], t, k, obj.name(k));
                elseif k == b.best
                    t = sprintf('%sUse pipeline %d: %s. It has the least noise and keeps at least %s of the trials.', ...
                        t, k, obj.name(k), kept);
                else
                    t = sprintf(['%sUse pipeline %d: %s. Its noise is as low as that of the best one (pipeline %d; ', ...
                        'the difference is within chance), and it removes less: it keeps at least %s of the trials.'], ...
                        t, k, obj.name(k), b.best, kept);
                end
                t = sprintf('%s %d of %d pipelines passed the checks.', t, nFeas, height(T));
            end
        end

        function showRows(obj)
            showAll = ~isempty(obj.AllBox) && obj.AllBox.Value;
            [data, cols] = obj.rows(showAll);
            w = {60, 70, 85, 80, 90, 'auto'};
            if showAll, w = [w {'auto'}]; end
            obj.Table.Data = data; obj.Table.ColumnName = cols; obj.Table.ColumnWidth = w;
        end

        function [data, cols] = rows(obj, showAll)
            % the recommendation(s) first, then the best of the others (showAll:
            % every pipeline, with the reason it was excluded)
            if nargin < 2, showAll = false; end
            R = obj.Result.ranking; T = R.table;
            rec = [R.byStratum.recommended];
            o = [rec(:); R.order(~ismember(R.order, rec))];
            if ~showAll, o = o(1:min(max(5, numel(rec)), numel(o))); end
            cols = {'pipeline', 'checks', 'noise (SME)', 'trials kept', 'signal change', 'settings'};
            if showAll, cols{end+1} = 'why excluded'; end
            data = cell(numel(o), numel(cols));
            for i = 1:numel(o)
                k = o(i); id = sprintf('%d', k);
                if any([R.byStratum.recommended] == k), id = [id '*']; end
                st = statusText(T.status{k});
                if startsWith(obj.Result.cands(k).message, 'not run'), st = 'not run'; end   % after a stop
                data(i, 1:6) = {id, st, pipecompare.gui.PanelText.num(T.objective(k), '%.4g'), ...
                    pipecompare.gui.PanelText.pctText(T.minRetention(k)), pipecompare.gui.PanelText.pctText(T.ampError(k)), ...
                    obj.name(k)};
                if showAll, data{i, 7} = char(T.reason{k}); end
            end
        end

        function t = name(obj, k)
            % Pipeline k by the settings that differ between pipelines, in
            % words (the full key is in the Command Window and the script).
            parts = {};
            for e = obj.Result.leaves(k).path
                i = e{1};
                if strcmp(i.type, 'none'), parts{end+1} = noneText(i.slot, obj.Result.state); continue; end %#ok<AGROW>
                for f = i.searched, parts{end+1} = settingText(i.type, f{1}, i.params.(f{1})); end %#ok<AGROW>
            end
            if isempty(parts), t = obj.Result.labels{k}; else, t = strjoin(parts, ', '); end
        end

        function t = shared(obj)
            % The steps every pipeline has, with no setting compared.
            names = {};
            for e = obj.Result.leaves(1).path
                i = e{1};
                if strcmp(i.type, 'none') || ~isempty(i.searched), continue; end
                names{end+1} = stepText(i.type); %#ok<AGROW>
            end
            t = '';
            if ~isempty(names), t = ['In every pipeline: ' strjoin(names, ', ') '.']; end
        end

        function k = chosen(obj)
            % the selected row's candidate, else the recommendation
            k = obj.Result.ranking.recommended;
            sel = obj.Table.Selection;
            if ~isempty(sel), k = str2double(strrep(obj.Table.Data{sel(1, 1), 1}, '*', '')); end
        end

        function adopt(obj, answer)
            % Rebuild the pipeline (its steps run again; the ICA decomposition
            % comes from the comparison) and store it in EEGLAB; it is in
            % memory only until saved. A pipeline that did not pass the
            % checks is used only after a confirmation that says why it did
            % not pass (answer: the button to press instead, for scripts).
            dlg = [];
            try
                k = pipecompare.run.Executor.pickCandidate(obj.Result, obj.chosen());
                T = obj.Result.ranking.table;
                force = ~strcmp(T.status{k}, 'feasible');
                if force
                    q = sprintf('Pipeline %d did not pass the checks: %s. Use it anyway?', k, char(T.reason{k}));
                    if nargin < 2
                        answer = uiconfirm(obj.Fig, q, 'PipeCompare', 'Options', {'Use anyway', 'Cancel'}, ...
                            'DefaultOption', 2, 'CancelOption', 2, 'Icon', 'warning');
                    end
                    if ~strcmp(answer, 'Use anyway'), return; end
                end
                msg = sprintf('Building pipeline %d from the start (every step runs again)...', k);
                if any(cellfun(@(e) strcmp(e.type, 'ica'), obj.Result.leaves(k).path))
                    msg = sprintf(['Building pipeline %d from the start; every step runs again except ICA, ', ...
                        'whose decomposition comes from the comparison...'], k);
                end
                dlg = uiprogressdlg(obj.Fig, 'Title', 'Use this pipeline', 'Message', msg, 'Indeterminate', 'on');
                pipecompare.PipeCompare.adopt(obj.Result, k, force);
                close(dlg);
                uialert(obj.Fig, sprintf(['Pipeline %d is now the current EEGLAB dataset. It is not saved yet: ', ...
                    'use File > Save current dataset as.'], k), 'Done', 'Icon', 'success');
            catch ME
                if ~isempty(dlg) && isvalid(dlg), close(dlg); end
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function saveScript(obj, file)
            try
                k = pipecompare.run.Executor.pickCandidate(obj.Result, obj.chosen());
                if nargin < 2
                    [f, p] = uiputfile('*.m', 'Save the pipeline as an EEGLAB function', sprintf('pipeline%d.m', k));
                    if isequal(f, 0), return; end
                    file = fullfile(p, f);
                end
                pipecompare.PipeCompare.writeScript(obj.Result, k, file);
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end
    end
end

function t = statusText(s)
% Rank's status in the words of the simple mode.
switch s
    case 'feasible', t = 'passed';
    case 'rejected', t = 'excluded';
    case 'failed', t = 'error';
    otherwise, t = s;
end
end

function t = settingText(type, param, v)
% One compared setting in words.
if isnumeric(v) && isscalar(v), x = sprintf('%g', v);
elseif ischar(v), x = v;
elseif isnumeric(v), x = mat2str(v);
else, x = '(set)'; end
switch [type '.' param]
    case 'highpass.cutoff', t = sprintf('high-pass %s Hz', x);
    case 'lowpass.cutoff', t = sprintf('low-pass %s Hz', x);
    case 'icremove.threshold', t = sprintf('ICLabel %s', x);
    case 'reject_threshold.uv', t = sprintf('reject above %s uV', x);
    case 'asr.cutoff', t = sprintf('ASR %s SD', x);
    otherwise, t = sprintf('%s %s %s', type, param, x);
end
end

function t = noneText(slot, state)
% A skipped step in words; a filter the data already had is kept.
t = sprintf('no %s', slot);
if ~any(strcmp(slot, {'highpass', 'lowpass'})) || ~isfield(state, 'filters') || isempty(state.filters.(slot)), return; end
edge = pipecompare.utils.ternary(strcmp(slot, 'highpass'), max(state.filters.(slot)), min(state.filters.(slot)));
t = sprintf('%s as in the data (%g Hz)', strrep(slot, 'pass', '-pass'), edge);
end

function t = stepText(type)
% A step that is the same in every pipeline, in words.
switch type
    case 'badchannels', t = 'bad channels interpolated';
    case 'ica', t = 'one ICA';
    case 'icremove', t = 'ICLabel component removal';
    case 'epoch', t = 'epochs';
    case 'baseline', t = 'baseline removal';
    otherwise
        d = pipecompare.plan.Catalog.get(type); t = lower(d.label);
end
end
