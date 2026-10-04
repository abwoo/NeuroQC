classdef SimpleResults < handle
    %SIMPLERESULTS Result window of the simple mode.
    %
    %   pipecompare.gui.SimpleResults(result)
    %
    %   First line, in plain words: the recommended pipeline and why; below,
    %   a table of the recommendation (marked *) followed by the best of the
    %   others. "Use this pipeline" stores the recommended (or the selected)
    %   candidate as a new EEGLAB dataset; Save script writes it as a
    %   runnable EEGLAB function; Details... opens the panel. With no
    %   feasible pipeline, the most common reason is said in one line; after
    %   a stop, how many pipelines were run.

    properties
        Result
        Fig; Headline; Table
    end

    methods
        function obj = SimpleResults(result)
            obj.Result = result;
            obj.Fig = uifigure('Name', 'Pipeline comparison', 'Position', [220 220 900 380]);
            g = uigridlayout(obj.Fig, [3 1]); g.RowHeight = {66, '1x', 30};
            obj.Headline = uilabel(g, 'Text', obj.headline(), 'WordWrap', 'on', 'FontWeight', 'bold', ...
                'VerticalAlignment', 'top');
            [data, cols] = obj.rows();
            obj.Table = uitable(g, 'Data', data, 'ColumnName', cols, 'RowName', {}, ...
                'ColumnWidth', {60, 70, 85, 80, 90, 'auto'});
            b = uigridlayout(g, [1 4]); b.Padding = [0 0 0 0]; b.ColumnWidth = {'1x', 140, 120, 120};
            uilabel(b, 'Text', 'Select a row to use another pipeline.', 'FontColor', [0.4 0.4 0.4]);
            uibutton(b, 'Text', 'Use this pipeline', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.adopt());
            uibutton(b, 'Text', 'Save script...', 'ButtonPushedFcn', @(~, ~) obj.saveScript());
            uibutton(b, 'Text', 'Details...', 'ButtonPushedFcn', @(~, ~) obj.allResults());
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
                    pipecompare.utils.ternary(isempty(common), 'see Details', strjoin(common, '')));
            elseif numel(R.byStratum) > 1
                t = sprintf(['%sThese pipelines use different references, which measure different things, so there is ', ...
                    'one recommendation per reference: pipelines %s. Use the one that matches your analysis.'], ...
                    t, strjoin(arrayfun(@num2str, [R.byStratum.recommended], 'UniformOutput', false), ', '));
            else
                k = R.recommended; b = R.byStratum;
                kept = pipecompare.gui.PanelText.pctText(T.minRetention(k));
                if k == b.best
                    t = sprintf('%sUse pipeline %d: %s. It has the least noise and keeps at least %s of the trials.', ...
                        t, k, obj.Result.labels{k}, kept);
                else
                    t = sprintf(['%sUse pipeline %d: %s. Its noise is as low as that of the best one (pipeline %d; ', ...
                        'the difference is within chance), and it removes less: it keeps at least %s of the trials.'], ...
                        t, k, obj.Result.labels{k}, b.best, kept);
                end
                t = sprintf('%s %d of %d pipelines passed the checks.', t, nFeas, height(T));
            end
        end

        function [data, cols] = rows(obj)
            R = obj.Result.ranking; T = R.table;
            % the recommendation(s) first, then the best of the others
            rec = [R.byStratum.recommended];
            o = [rec(:); R.order(~ismember(R.order, rec))];
            o = o(1:min(max(5, numel(rec)), numel(o)));
            cols = {'pipeline', 'checks', 'noise (SME)', 'trials kept', 'signal change', 'steps'};
            data = cell(numel(o), numel(cols));
            for i = 1:numel(o)
                k = o(i); id = sprintf('%d', k);
                if any([R.byStratum.recommended] == k), id = [id '*']; end
                st = statusText(T.status{k});
                if startsWith(obj.Result.cands(k).message, 'not run'), st = 'not run'; end   % after a stop
                data(i, :) = {id, st, pipecompare.gui.PanelText.num(T.objective(k), '%.4g'), ...
                    pipecompare.gui.PanelText.pctText(T.minRetention(k)), pipecompare.gui.PanelText.pctText(T.ampError(k)), ...
                    obj.Result.labels{k}};
            end
        end

        function k = chosen(obj)
            % the selected row's candidate, else the recommendation
            k = obj.Result.ranking.recommended;
            sel = obj.Table.Selection;
            if ~isempty(sel), k = str2double(strrep(obj.Table.Data{sel(1, 1), 1}, '*', '')); end
        end

        function adopt(obj)
            try
                pipecompare.PipeCompare.adopt(obj.Result, obj.chosen());
                uialert(obj.Fig, 'Stored as a new EEGLAB dataset; its EEG.history reproduces it.', 'Adopted', 'Icon', 'success');
            catch ME
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

        function app = allResults(obj)
            app = pipecompare.gui.Panel();
            app.Plan = obj.Result.plan; app.showPlan();
            app.Result = obj.Result; app.showResults();
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
