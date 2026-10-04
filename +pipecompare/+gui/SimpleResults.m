classdef SimpleResults < handle
    %SIMPLERESULTS Result window of the simple mode.
    %
    %   pipecompare.gui.SimpleResults(result)
    %
    %   First line: the recommended pipeline and why; below, a table of the
    %   recommendation (marked *) followed by the best of the others. Adopt stores the recommended (or the
    %   selected) candidate as a new EEGLAB dataset; Save script writes it
    %   as a runnable EEGLAB function; All results... opens the panel. With
    %   no feasible pipeline, the most common reason is said in one line.

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
                'ColumnWidth', {50, 70, 80, 80, 80, 'auto'});
            b = uigridlayout(g, [1 4]); b.Padding = [0 0 0 0]; b.ColumnWidth = {'1x', 120, 120, 140};
            uilabel(b, 'Text', 'Select a row to act on another candidate.', 'FontColor', [0.4 0.4 0.4]);
            uibutton(b, 'Text', 'Adopt', 'ButtonPushedFcn', @(~, ~) obj.adopt());
            uibutton(b, 'Text', 'Save script...', 'ButtonPushedFcn', @(~, ~) obj.saveScript());
            uibutton(b, 'Text', 'All results...', 'ButtonPushedFcn', @(~, ~) obj.allResults());
        end

        function t = headline(obj)
            R = obj.Result.ranking; T = R.table;
            nFeas = sum(strcmp(T.status, 'feasible'));
            if isempty(R.byStratum)
                common = pipecompare.eval.Rank.commonReasons(R, 1);
                t = sprintf('No pipeline meets the constraints (none relaxed). Most common reason: %s.', ...
                    pipecompare.utils.ternary(isempty(common), 'see All results', strjoin(common, '')));
            elseif numel(R.byStratum) > 1
                t = sprintf(['%d strata (different references) are not comparable, so there is one recommendation ', ...
                    'per reference: candidates %s. Choose the one that fits your analysis (All results...).'], ...
                    numel(R.byStratum), mat2str([R.byStratum.recommended]));
            else
                k = R.recommended; b = R.byStratum;
                t = sprintf(['Recommended: candidate %d, %s. Among the %d of %d pipelines that meet every ', ...
                    'constraint, it is the least aggressive (fewest trials lost, then least distortion) of the %d ', ...
                    'the data do not distinguish from the most precise one (candidate %d).'], k, ...
                    obj.Result.labels{k}, nFeas, height(T), numel(b.set), b.best);
            end
        end

        function [data, cols] = rows(obj)
            R = obj.Result.ranking; T = R.table;
            % the recommendation(s) first, then the best of the others
            rec = [R.byStratum.recommended];
            o = [rec(:); R.order(~ismember(R.order, rec))];
            o = o(1:min(max(5, numel(rec)), numel(o)));
            cols = {'id', 'status', 'objective', 'retention', 'amp. err.', 'pipeline'};
            data = cell(numel(o), numel(cols));
            for i = 1:numel(o)
                k = o(i); id = sprintf('%d', k);
                if any([R.byStratum.recommended] == k), id = [id '*']; end
                data(i, :) = {id, T.status{k}, pipecompare.gui.PanelText.num(T.objective(k), '%.4g'), ...
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
