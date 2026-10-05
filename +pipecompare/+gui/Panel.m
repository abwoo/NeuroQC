classdef Panel < handle
    %PANEL PipeCompare panel: live dataset + history, plan, contract, results.
    %
    %   pipecompare.gui.Panel()   (or EEGLAB > Tools > PipeCompare)
    %
    %   There is no load button: the panel follows the dataset that is
    %   current in EEGLAB and re-reads it (and its EEG.history) whenever it
    %   changes, including changes made through EEGLAB menus or the command
    %   line. Everything the panel does is also printed in the Command
    %   Window; results are assigned to the base variable pipecompare_result.

    properties
        Plan
        Result
        Fig
        Timer
        LastFingerprint = ''
        LastQuick = ''            % Session.quickPrint at the last refresh
        Ticks = 0                 % refresh-timer ticks since the last full check
        % widgets
        DatasetLabel; WarnArea; HistTable
        PlanTable; TypeDrop; OrderDrop; ConstraintLabel
        CondField; EpochField; BaseField; CompField; EventsLabel
        TrialRule = struct('mode', 'all')
        TrialRuleSource = ''      % the recording the trial rule was set on (recordingId)
        AutoFilled = struct('CondField', '', 'EpochField', '', 'BaseField', '')   % what the data filled in
        TrialLabel; SummaryLabel
        LimitFields = struct()
        ObjectiveField
        Options = struct('dataUnit', 'auto', 'checkpoint', '', ...
            'parallel', false)
        ResultTable; StatusLabel; DetailArea
    end

    methods
        function obj = Panel()
            obj.Plan = pipecompare.plan.Plan();
            obj.build();
            obj.refreshLive(true);
            obj.Timer = timer('ExecutionMode', 'fixedSpacing', 'Period', 1, 'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.refreshLive(false), 'Name', 'pipecompare_panel');
            start(obj.Timer);
            pipecompare.utils.log('Panel open. It follows the current EEGLAB dataset.');
        end

        function delete(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer), stop(obj.Timer); delete(obj.Timer); end
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        % ------------------------------------------------------------ layout
        function build(obj)
            obj.Fig = uifigure('Name', sprintf('PipeCompare %s', pipecompare.PipeCompare.version()), ...
                'Position', [60 60 1380 860], 'CloseRequestFcn', @(~, ~) obj.delete());
            g = uigridlayout(obj.Fig, [3 2]);
            g.RowHeight = {80, 300, '1x'}; g.ColumnWidth = {'1x', '1.25x'};   % contract and results get the remaining height
            % below the size every part needs, keep their sizes and scroll
            obj.Fig.AutoResizeChildren = 'off';   % the grid resizes itself; this lets SizeChangedFcn run
            obj.Fig.SizeChangedFcn = @(f, ~) fitLayout(g, f.Position);
            fitLayout(g, obj.Fig.Position);

            top = uigridlayout(g, [1 2]); top.Layout.Column = [1 2]; top.ColumnWidth = {'1x', '1x'}; top.Padding = [0 0 0 0];
            obj.DatasetLabel = uilabel(top, 'Text', 'No dataset', 'FontName', 'Courier', 'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.WarnArea = uitextarea(top, 'Editable', 'off', 'FontColor', [0.6 0.2 0], 'Value', {''});

            % history (left, rows 2-3)
            hp = uipanel(g, 'Title', 'EEG.history of the current dataset (live)'); hp.Layout.Row = 2; hp.Layout.Column = 1;
            hg = uigridlayout(hp, [1 1]);
            obj.HistTable = uitable(hg, 'ColumnName', {'line','kind','step','statement'}, ...
                'ColumnWidth', {40, 60, 95, 'auto'}, 'RowName', {}, ...
                'SelectionChangedFcn', @(t, ~) obj.showDetails('history', t));

            % plan (right, row 2)
            pp = uipanel(g, 'Title', 'Plan: steps after the current dataset (one value = fixed, several = searched)');
            pp.Layout.Row = 2; pp.Layout.Column = 2;
            pg = uigridlayout(pp, [5 1]); pg.RowHeight = {'1x', 28, 28, 28, 20};
            obj.PlanTable = uitable(pg, 'ColumnName', {'#','step','values (searched or fixed)','pin'}, ...
                'ColumnEditable', [false false false true], 'ColumnWidth', {30, 120, 'auto', 45}, 'RowName', {}, ...
                'CellEditCallback', @(~, e) obj.planEdited(e), 'SelectionChangedFcn', @(t, ~) obj.showDetails('plan', t));
            b1 = uigridlayout(pg, [1 8]); b1.Padding = [0 0 0 0];
            b1.ColumnWidth = {'1.3x', '0.6x', '1.7x', '0.9x', '0.6x', '0.7x', '0.7x', '0.9x'};
            obj.TypeDrop = uidropdown(b1, 'Items', setdiff(pipecompare.plan.Catalog.types(), {'native'}, 'stable'));
            uibutton(b1, 'Text', 'Add', 'ButtonPushedFcn', @(~, ~) obj.addStep());
            uibutton(b1, 'Text', 'Add EEGLAB menu step...', 'Tooltip', ...
                ['Any operation of EEGLAB''s menus (plugins included): its own dialog opens on the data as the plan ', ...
                 'has them at the end, and the command it returns becomes a step'], ...
                'ButtonPushedFcn', @(~, ~) obj.addEeglabStep());
            uibutton(b1, 'Text', 'Remove', 'ButtonPushedFcn', @(~, ~) obj.removeStep());
            uibutton(b1, 'Text', 'Up', 'ButtonPushedFcn', @(~, ~) obj.moveStep(-1));
            uibutton(b1, 'Text', 'Down', 'ButtonPushedFcn', @(~, ~) obj.moveStep(1));
            uilabel(b1, 'Text', 'Order:', 'HorizontalAlignment', 'right');
            obj.OrderDrop = uidropdown(b1, 'Items', {'fixed','search'}, 'ValueChangedFcn', @(s, ~) obj.setOrder(s.Value));
            b2 = uigridlayout(pg, [1 3]); b2.Padding = [0 0 0 0];
            uibutton(b2, 'Text', 'Configure in EEGLAB...', 'FontWeight', 'bold', 'Tooltip', ...
                ['Open the selected step''s EEGLAB dialog; its values are added to the step (a value that differs ', ...
                 'from those already there becomes a searched candidate)'], ...
                'ButtonPushedFcn', @(~, ~) obj.configureStep());
            uibutton(b2, 'Text', 'Edit values...', 'Tooltip', ...
                'Every parameter of the selected step: one value = fixed, several = searched; channels from EEGLAB''s channel list', ...
                'ButtonPushedFcn', @(~, ~) obj.valuesDialog());
            uibutton(b2, 'Text', 'Apply now in EEGLAB', 'Tooltip', ...
                'Run the selected step on the current dataset through the EEGLAB dialog (recorded in EEG.history); the plan then starts after it', ...
                'ButtonPushedFcn', @(~, ~) obj.applyNow());
            b3 = uigridlayout(pg, [1 3]); b3.Padding = [0 0 0 0];
            uibutton(b3, 'Text', 'Skipping allowed on/off', 'Tooltip', ...
                'Whether leaving the selected step out is one of the searched options', ...
                'ButtonPushedFcn', @(~, ~) obj.toggleSkip());
            uibutton(b3, 'Text', 'Must come before...', 'Tooltip', ...
                'With order = search: the selected step must run before the step you choose', ...
                'ButtonPushedFcn', @(~, ~) obj.mustBefore());
            uibutton(b3, 'Text', 'Clear order rules', 'ButtonPushedFcn', @(~, ~) obj.clearOrderRules());
            obj.ConstraintLabel = uilabel(pg, 'Text', 'Order rules: none', 'FontColor', [0.3 0.3 0.3]);

            % contract + run + results (right, row 3)
            rp = uipanel(g, 'Title', 'Analysis contract, constraints, search'); rp.Layout.Row = 3; rp.Layout.Column = 2;
            rg = uigridlayout(rp, [3 1]); rg.RowHeight = {196, 56, 64};
            % Each item: label | its text (the one source of the setting, also
            % editable by hand) | buttons that fill it from EEGLAB's dialogs.
            cg = uigridlayout(rg, [7 4]); cg.Padding = [0 0 0 0]; cg.RowSpacing = 3;
            cg.ColumnWidth = {80, '1x', 150, 95}; cg.RowHeight = repmat({24}, 1, 7);
            uilabel(cg, 'Text', 'Conditions');
            obj.CondField = uieditfield(cg, 'Placeholder', 'none yet - use Add from events... (format: name: code code; name2: code)');
            uibutton(cg, 'Text', 'Add from events...', 'Tooltip', ...
                'Name a condition and pick its event codes from the dataset''s own event list (EEGLAB selection window)', ...
                'ButtonPushedFcn', @(~, ~) obj.addCondition());
            uibutton(cg, 'Text', 'Clear', 'ButtonPushedFcn', @(~, ~) obj.setField(obj.CondField, ''));
            uilabel(cg, 'Text', 'Trials');
            obj.TrialLabel = uilabel(cg, 'Text', 'all trials', 'FontColor', [0.2 0.2 0.2]);
            uibutton(cg, 'Text', 'Choose trials...', 'Tooltip', ...
                'Which trials count: all, between start/end markers, time ranges, or an EEGLAB event selection (pop_selectevent)', ...
                'ButtonPushedFcn', @(~, ~) obj.chooseTrials());
            uibutton(cg, 'Text', 'All trials', 'ButtonPushedFcn', @(~, ~) obj.setTrialRule(struct('mode', 'all')));
            uilabel(cg, 'Text', 'Epoch (s)'); obj.EpochField = uieditfield(cg, 'Value', '', 'Placeholder', 'start end in s around the event - required (EEGLAB pop_epoch...)');
            uibutton(cg, 'Text', 'EEGLAB pop_epoch...', 'Tooltip', ...
                'Set the epoch in EEGLAB''s own epoching dialog (run on a copy); the window is filled in here', ...
                'ButtonPushedFcn', @(~, ~) obj.epochFromEEGLAB());
            uilabel(cg, 'Text', '');
            uilabel(cg, 'Text', 'Baseline (s)'); obj.BaseField = uieditfield(cg, 'Value', '', 'Placeholder', 'empty = pre-stimulus baseline [epoch start 0] s');
            uibutton(cg, 'Text', 'EEGLAB pop_rmbase...', 'Tooltip', ...
                'Set the baseline in EEGLAB''s own baseline dialog on epoched preview data (ms are converted to s)', ...
                'ButtonPushedFcn', @(~, ~) obj.baselineFromEEGLAB());
            uilabel(cg, 'Text', '');
            uilabel(cg, 'Text', 'Components');
            obj.CompField = uieditfield(cg, 'Placeholder', 'none yet - use Add component... (format: name: start end @ channels [# measure polarity])');
            uibutton(cg, 'Text', 'Add component...', 'Tooltip', ...
                'Name, window and measure, then the ROI from the dataset''s channels (EEGLAB channel selection)', ...
                'ButtonPushedFcn', @(~, ~) obj.addComponent());
            uibutton(cg, 'Text', 'Set ROI...', 'Tooltip', 'Replace the ROI of a component with channels chosen in EEGLAB''s channel selection', ...
                'ButtonPushedFcn', @(~, ~) obj.setRoi());
            obj.SummaryLabel = uilabel(cg, 'Text', '', 'FontColor', [0 0.3 0.1], 'WordWrap', 'on');
            obj.SummaryLabel.Layout.Column = [1 4]; obj.SummaryLabel.Layout.Row = 6;
            obj.EventsLabel = uilabel(cg, 'Text', 'Event types: -', 'FontColor', [0.3 0.3 0.3], 'WordWrap', 'on');
            obj.EventsLabel.Layout.Column = [1 2]; obj.EventsLabel.Layout.Row = 7;
            uibutton(cg, 'Text', 'View ERP (EEGLAB)...', 'Tooltip', ...
                'ERP and scalp maps of the conditions in EEGLAB (pop_timtopo on epoched preview data), to choose windows and ROIs', ...
                'ButtonPushedFcn', @(~, ~) obj.viewErp());
            uibutton(cg, 'Text', 'Chan. locations...', 'Tooltip', ...
                'Edit channel locations of the current dataset in EEGLAB (pop_chanedit); needed for interpolation and topographies', ...
                'ButtonPushedFcn', @(~, ~) obj.editChanlocs());
            lg = uigridlayout(rg, [2 10]); lg.Padding = [0 0 0 0]; lg.RowSpacing = 4;
            lg.ColumnWidth = {'fit', '1x', 'fit', '1x', 'fit', '1x', 'fit', '1x', 'fit', '1x'};
            d = pipecompare.eval.Rank.defaults();
            names = {'minTrials','minRetention','maxInterpolated','maxAmplitudeError','maxLatencyShiftMs', ...
                'maxArtifactPct','minWaveformCorr','minTopoCorr'};
            short = {'min trials','min retention','max interp','max amp err','max lat ms','max artifact','min wave r','min topo r'};
            for k = 1:numel(names)
                uilabel(lg, 'Text', short{k}, 'HorizontalAlignment', 'right');
                obj.LimitFields.(names{k}) = uieditfield(lg, 'numeric', 'Value', d.(names{k}));
            end
            uilabel(lg, 'Text', 'max pipelines', 'HorizontalAlignment', 'right');
            obj.LimitFields.maxLeaves = uieditfield(lg, 'numeric', 'Value', pipecompare.plan.Plan.MaxLeaves);
            ag = uigridlayout(rg, [2 6]); ag.Padding = [0 0 0 0]; ag.RowSpacing = 4;
            ag.ColumnWidth = {'fit', 170, 'fit', 'fit', 'fit', '1x'};
            uilabel(ag, 'Text', 'Objective', 'HorizontalAlignment', 'right');
            obj.ObjectiveField = uidropdown(ag, 'Items', {'composite'}, 'Value', 'composite', 'Tooltip', ...
                'composite = all measures together (same unit); or the one measure to optimize');
            uibutton(ag, 'Text', 'Preview count', 'ButtonPushedFcn', @(~, ~) obj.run(true));
            uibutton(ag, 'Text', 'Run search', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run(false));
            uibutton(ag, 'Text', 'Options...', 'Tooltip', 'Data unit, checkpoint folder, parallel', ...
                'ButtonPushedFcn', @(~, ~) obj.optionsDialog());
            obj.StatusLabel = uilabel(ag, 'Text', '', 'FontColor', [0 0 0.5], 'WordWrap', 'on');
            obj.StatusLabel.Layout.Row = [1 2]; obj.StatusLabel.Layout.Column = 6;
            uibutton(ag, 'Text', 'Resume...', 'Tooltip', 'Continue an interrupted search from its checkpoint folder', ...
                'ButtonPushedFcn', @(~, ~) obj.resume());
            uibutton(ag, 'Text', 'Inspect selected (EEGLAB)...', 'Tooltip', ...
                'Open the selected candidate (rebuilt, not adopted) or the source dataset in EEGLAB''s viewers', ...
                'ButtonPushedFcn', @(~, ~) obj.inspect());
            uibutton(ag, 'Text', 'Adopt selected', 'ButtonPushedFcn', @(~, ~) obj.adopt());
            uibutton(ag, 'Text', 'Print script', 'ButtonPushedFcn', @(~, ~) obj.printScript());
            resP = uipanel(g, 'Title', 'Results (select a row, then Inspect / Adopt / Print script)');
            resP.Layout.Row = 3; resP.Layout.Column = 1;
            rgl = uigridlayout(resP, [2 1]); rgl.RowHeight = {'1x', 96};
            obj.ResultTable = uitable(rgl, 'RowName', {}, 'ColumnName', ...
                {'id','status','objective','diff vs best','nd','min ret.','interp.','amp. err.','artifact','pipeline / reason'}, ...
                'ColumnWidth', {40, 70, 72, 128, 34, 66, 60, 74, 66, 'auto'}, ...
                'Tooltip', 'nd = not distinguished from the best by these data (not equivalence); * = recommended. Select a row for the full text below.', ...
                'SelectionChangedFcn', @(t, ~) obj.showDetails('result', t));
            obj.DetailArea = uitextarea(rgl, 'Editable', 'off', 'WordWrap', 'on', 'FontSize', 11, ...
                'Value', {'Select a row of the history, the plan or the results to see its full content here.'});
            % any change to what the search depends on makes shown results stale
            settings = [{obj.CondField, obj.EpochField, obj.CompField, obj.BaseField, obj.ObjectiveField}, ...
                struct2cell(obj.LimitFields)'];
            for k = 1:numel(settings)
                settings{k}.ValueChangedFcn = @(~, ~) obj.settingsChanged();
            end
        end

        % ------------------------------------------------------------- live
        function refreshLive(obj, force)
            if isempty(obj.Fig) || ~isvalid(obj.Fig), return; end
            % Two levels: every second only the quick signature (its cost does
            % not grow with events or history); the full fingerprint when it
            % changed, and otherwise every 5 s, so an edit that keeps every
            % count is still seen within 5 s.
            if ~force
                try, [~, q] = pipecompare.live.Session.peek(); catch, q = ''; end
                obj.Ticks = obj.Ticks + 1;
                if strcmp(q, obj.LastQuick) && obj.Ticks < 5, return; end
                obj.LastQuick = q;
            end
            obj.Ticks = 0;
            try
                [EEG, live] = pipecompare.live.Session.current();
            catch ME
                obj.DatasetLabel.Text = ME.message; return;
            end
            fp = live.fingerprint;
            if ~force && strcmp(fp, obj.LastFingerprint), return; end
            obj.LastFingerprint = fp;
            if isempty(EEG)
                obj.DatasetLabel.Text = 'No dataset loaded in EEGLAB.';
                obj.HistTable.Data = {}; obj.WarnArea.Value = {''};
                return;
            end
            s = pipecompare.live.DataState.fromEEG(EEG);
            if s.isEpoched, shape = sprintf('%d epochs [%g %g] s', s.trials, s.xmin, s.xmax);
            else, shape = sprintf('continuous %.1f s', s.pnts / s.srate); end
            stored = ''; if ~live.stored, stored = '  (base EEG not stored in ALLEEG)'; end
            if s.hasLocations, locs = 'channel locations: yes';
            elseif s.nLocated == 0, locs = 'channel locations: NONE (no interpolation, no ICLabel)';
            else, locs = sprintf('channel locations: %d of %d (none for %s)', s.nLocated, s.nbchan, strjoin(s.unlocated, ', ')); end
            obj.DatasetLabel.Text = sprintf(['Set %s: %s%s\n%d ch | %g Hz | %s | %d events\n', ...
                'Reference: %s | ICA: %s | %s\nFilters: %s'], mat2str(live.currentSet), s.setname, stored, ...
                s.nbchan, s.srate, shape, s.nEvents, s.reference, s.ica.summary, locs, pipecompare.gui.PanelText.orDash(s.filters.text));
            obj.autoFill(s);
            obj.checkTrialRule(EEG, s);
            if isempty(s.warnings), obj.WarnArea.Value = {'No inconsistencies between data and history.'};
            else, obj.WarnArea.Value = s.warnings(:); end
            h = s.history;
            obj.HistTable.Data = [num2cell([h.line]') {h.kind}' {h.step}' {h.statement}'];
            ev = arrayfun(@(k) sprintf('%s (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:numel(s.eventTypes), 'UniformOutput', false);
            if s.isEpoched
                obj.EpochField.Placeholder = sprintf('empty = the data''s epochs [%g %g] s', s.xmin, s.xmax);
            else
                obj.EpochField.Placeholder = 'start end in s around the event - required (EEGLAB pop_epoch...)';
            end
            obj.EventsLabel.Text = ['Event types: ' strjoin(ev, ', ')];
            obj.EventsLabel.Tooltip = obj.EventsLabel.Text;   % the full list, however long
            obj.updateSummary();
            if ~force, pipecompare.utils.log('Current EEGLAB dataset changed: %s (%d history entries).', s.setname, numel(h)); end
            if ~isempty(obj.Result) && ~strcmp(fp, obj.Result.rootFingerprint)
                obj.StatusLabel.Text = sprintf(['Shown results were computed on "%s", not on the current dataset; ', ...
                    'Adopt rebuilds from that starting copy. Run again for the current one.'], obj.Result.state.setname);
            end
        end

        function autoFill(obj, s)
            % What the dataset itself says, filled into fields that are
            % empty (or still hold an earlier automatic value): the epochs
            % of epoched data, the events they are time-locked to (one
            % condition per type, to rename or group), the baseline of the
            % last pop_rmbase. Never overwrites what the user typed.
            v = struct('CondField', '', 'EpochField', '', 'BaseField', '');
            if s.isEpoched
                v.EpochField = sprintf('%g %g', round(1000 * s.xmin) / 1000, round(1000 * s.xmax) / 1000);
                if ~isempty(s.lockingTypes)
                    v.CondField = pipecompare.gui.PanelText.conditionsText([s.lockingTypes(:) cellfun(@(t) {t}, s.lockingTypes(:), 'UniformOutput', false)]);
                end
            end
            if ~isempty(s.baselineMs), v.BaseField = sprintf('%g %g', s.baselineMs / 1000); end
            filled = {};
            for f = fieldnames(v)'
                fld = obj.(f{1}); cur = strtrim(fld.Value);
                if isempty(cur) || strcmp(cur, obj.AutoFilled.(f{1}))
                    if ~strcmp(cur, v.(f{1})), fld.Value = v.(f{1}); if ~isempty(v.(f{1})), filled{end+1} = f{1}; end, end %#ok<AGROW>
                    obj.AutoFilled.(f{1}) = v.(f{1});
                end
            end
            if ~isempty(filled)
                names = strrep(strrep(strrep(filled, 'CondField', 'conditions (time-locking events)'), 'EpochField', 'epoch'), 'BaseField', 'baseline');
                pipecompare.utils.log('From the dataset: %s filled in (edit them if needed).', strjoin(names, ', '));
                obj.invalidate('Settings changed'); obj.updateObjectives();
            end
        end

        % ------------------------------------------------------------- plan
        function showPlan(obj)
            S = obj.Plan.Slots;
            data = cell(numel(S), 4);
            ctxt = struct('epoch', obj.EpochField.Value, 'baseline', obj.BaseField.Value);
            for k = 1:numel(S)
                data{k, 1} = k; data{k, 2} = S(k).id;
                data{k, 3} = pipecompare.gui.PanelValues.settingsText(S(k), ctxt); data{k, 4} = S(k).pinned;
            end
            obj.PlanTable.Data = data;
            obj.OrderDrop.Value = obj.Plan.OrderMode;
            P = obj.Plan.Precedence;
            if isempty(P), t = 'Order rules: none';
            else, t = ['Order rules: ' strjoin(arrayfun(@(r) sprintf('%s before %s', P{r, 1}, P{r, 2}), 1:size(P, 1), 'UniformOutput', false), '; ')]; end
            if strcmp(obj.Plan.OrderMode, 'fixed') && ~isempty(P), t = [t '  (used when order = search)']; end
            obj.ConstraintLabel.Text = t;
        end

        function invalidate(obj, why)
            % Results belong to the plan, contract and limits they were
            % computed with; any change makes them stale.
            if isempty(obj.Result), return; end
            obj.Result = [];
            obj.ResultTable.Data = {};
            obj.StatusLabel.Text = sprintf('%s: previous results cleared - run the search again.', why);
            pipecompare.utils.log('%s: previous results cleared (pipecompare_result in the base workspace is the old run).', why);
        end

        function addStep(obj)
            obj.Plan = obj.Plan.add(obj.TypeDrop.Value);
            obj.invalidate('Plan changed');
            obj.showPlan();
            pipecompare.utils.log('Added %s: %s', obj.Plan.Slots(end).id, pipecompare.gui.PanelValues.settingsText(obj.Plan.Slots(end)));
        end

        function addEeglabStep(obj, label, com)
            % Any operation of EEGLAB's menus (plugins included) as a plan
            % step: its dialog opens on the data as the plan has them at
            % the end of the plan, and the command it returns is the step
            % (a single call's arguments can then be searched with Edit
            % values... or another Configure in EEGLAB...). A command
            % (com) given by a script skips the dialog.
            try
                if nargin < 3
                    items = pipecompare.run.Native.menuSteps();
                    assert(~isempty(items), 'PipeCompare:Native', 'EEGLAB''s main window (with its menus) is not open.');
                    if nargin < 2
                        [i, ok] = listdlg2('PromptString', 'EEGLAB operation to add as a plan step', ...
                            'ListString', {items.label}, 'SelectionMode', 'single');
                        if ~ok || isempty(i), return; end
                    else
                        i = find(strcmp({items.label}, label), 1);
                        assert(~isempty(i), 'PipeCompare:Native', 'EEGLAB has no menu item "%s".', label);
                    end
                    EEG = obj.previewAt(numel(obj.Plan.Slots) + 1);
                    com = pipecompare.run.Native.captureCall(EEG, items(i).call);
                    if isempty(com), return; end
                end
                st = pipecompare.run.Native.statements(com);
                e = pipecompare.live.History.classify(st{1});
                obj.Plan = obj.Plan.addNative(com, regexprep(e.fn, '^pop_', ''));
                obj.invalidate('Plan changed');
                obj.showPlan();
                pipecompare.utils.log('Added %s: %s', obj.Plan.Slots(end).id, pipecompare.gui.PanelValues.settingsText(obj.Plan.Slots(end)));
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function k = selected(obj)
            k = [];
            sel = obj.PlanTable.Selection;
            if ~isempty(sel), k = sel(1, 1); end
            if isempty(k), uialert(obj.Fig, 'Select a plan row first.', 'PipeCompare'); end
        end

        function removeStep(obj)
            k = obj.selected(); if isempty(k), return; end
            obj.Plan = obj.Plan.remove(obj.Plan.Slots(k).id); obj.invalidate('Plan changed'); obj.showPlan();
        end

        function moveStep(obj, d)
            k = obj.selected(); if isempty(k), return; end
            obj.Plan = obj.Plan.move(obj.Plan.Slots(k).id, d); obj.invalidate('Plan changed'); obj.showPlan();
        end

        function setOrder(obj, v)
            obj.Plan.OrderMode = v;
            obj.invalidate('Plan changed');
        end

        function planEdited(obj, e)
            % only the pin column is editable in the table
            k = e.Indices(1);
            if e.Indices(2) == 4
                obj.Plan.Slots(k).pinned = logical(e.NewData);
                obj.invalidate('Plan changed');
            end
            obj.showPlan();
        end

        function configureStep(obj, com, EEG, keepWhole)
            % The selected step's EEGLAB dialog. Its values join the step:
            % a value that differs from those already there becomes a
            % searched candidate. Settings the step cannot hold (e.g.
            % asymmetric limits) are never dropped silently: the whole
            % EEGLAB command is kept instead, if you choose so.
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            j = find(~cellfun(@(a) strcmp(a.type, 'none'), slot.alternatives), 1);
            alt = slot.alternatives{j};
            try
                if nargin < 2
                    type = obj.dialogType(slot);
                    [com, EEG] = obj.captureFor(type, k);   % on the data as the plan has them at this step
                    if isempty(com), return; end
                end
                if nargin < 3 || isempty(EEG), EEG = pipecompare.live.Session.current(); end
                alts = slot.alternatives;
                if any(strcmp(alt.type, pipecompare.plan.Catalog.types())) && ~strcmp(alt.type, 'native')
                    [vals, notes] = pipecompare.run.Native.catalogValues(alt.type, com, EEG);
                    if ~isempty(notes)
                        msg = sprintf('The dialog also set: %s.', strjoin(notes, '; '));
                        if nargin < 4
                            c = uiconfirm(obj.Fig, [msg ' Keep the whole EEGLAB command for this step, or only the values the step uses?'], ...
                                'PipeCompare', 'Options', {'Keep whole command', 'Only the step''s values', 'Cancel'}, 'DefaultOption', 1, 'CancelOption', 3);
                            if strcmp(c, 'Cancel'), return; end
                            keepWhole = strcmp(c, 'Keep whole command');
                        end
                        if keepWhole
                            alts{j} = stepAlt(com);
                            obj.Plan.Slots(k).alternatives = alts;
                            pipecompare.utils.log('%s: %s Kept the whole EEGLAB command.', slot.id, msg);
                            obj.invalidate('Plan changed'); obj.showPlan();
                            return;
                        end
                        pipecompare.utils.log('%s: %s Only the step''s values were used.', slot.id, msg);
                    end
                    alts{j} = pipecompare.gui.PanelValues.addValues(alt, vals);
                else
                    new = stepAlt(com);
                    if strcmp(alt.type, 'eeglab') && strcmp(new.type, 'eeglab')
                        [m, changed] = pipecompare.run.Native.mergeEeglab(alt, new);
                        if isequal({m.params.args.name}, {new.params.args.name}) && strcmp(m.params.fn, new.params.fn)
                            if isempty(changed), pipecompare.utils.log('%s: this configuration is already there.', slot.id); return; end
                            alts{j} = m;
                            pipecompare.utils.log('%s: searched argument(s) %s.', slot.id, strjoin(changed, ', '));
                        else
                            alts{end+1} = new;
                        end
                    elseif ~any(cellfun(@(a) isequal(a, new), alts))
                        alts{end+1} = new;           % another configuration of a workflow
                    else
                        pipecompare.utils.log('%s: this configuration is already there.', slot.id); return;
                    end
                end
                obj.Plan.Slots(k).alternatives = alts;
                pipecompare.utils.log('%s: %s', slot.id, pipecompare.gui.PanelValues.settingsText(obj.Plan.Slots(k)));
                obj.invalidate('Plan changed'); obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function setValues(obj, name, values)
            % Values of one parameter of the selected step (cell: one entry
            % per value; one entry = fixed, several = searched; {} = back to
            % the default).
            k = obj.selected(); if isempty(k), return; end
            alts = obj.Plan.Slots(k).alternatives;
            j = find(~cellfun(@(a) strcmp(a.type, 'none'), alts), 1);
            alts{j} = pipecompare.gui.PanelValues.setParam(alts{j}, name, values);
            obj.Plan.Slots(k).alternatives = alts;
            obj.invalidate('Plan changed'); obj.showPlan();
        end

        function valuesDialog(obj)
            % Every parameter of the selected step with its values; values
            % separated by " | "; channel lists picked in EEGLAB.
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            j = find(~cellfun(@(a) strcmp(a.type, 'none'), slot.alternatives), 1);
            alt = slot.alternatives{j};
            rows = pipecompare.gui.PanelValues.paramRows(alt);
            if isempty(rows)
                uialert(obj.Fig, sprintf('%s has no parameters of its own (settings come from the analysis contract or the workflow command).', slot.id), 'PipeCompare');
                return;
            end
            d = uifigure('Name', sprintf('%s: values', slot.id), 'Position', [200 200 680 380], 'WindowStyle', 'modal');
            gl = uigridlayout(d, [3 1]); gl.RowHeight = {40, '1x', 30};
            uilabel(gl, 'WordWrap', 'on', 'Text', ['One value = fixed; several values separated by " | " = searched. ', ...
                'Leave empty for the default. Channel lists: select the row and use Pick channels.']);
            T = uitable(gl, 'Data', [rows(:, 1) rows(:, 2) rows(:, 3)], 'ColumnName', {'parameter', 'values', 'default'}, ...
                'ColumnEditable', [false true false], 'ColumnWidth', {130, 'auto', 200}, 'RowName', {});
            bg = uigridlayout(gl, [1 4]); bg.Padding = [0 0 0 0]; bg.ColumnWidth = {130, '1x', 90, 90};
            uibutton(bg, 'Text', 'Pick channels...', 'ButtonPushedFcn', @(~, ~) pick());
            uilabel(bg, 'Text', '');
            uibutton(bg, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) delete(d));
            uibutton(bg, 'Text', 'OK', 'ButtonPushedFcn', @(~, ~) apply());
            function pick()
                sel = T.Selection; if isempty(sel), return; end
                L = obj.pickChannels(pipecompare.gui.PanelText.tokens(T.Data{sel(1, 1), 2}));
                if ~isempty(L), T.Data{sel(1, 1), 2} = strjoin(cellfun(@pipecompare.gui.PanelText.quoteItem, L, 'UniformOutput', false), ' '); end
            end
            function apply()
                try
                    a = alt;
                    for r = 1:size(rows, 1)
                        if strcmp(T.Data{r, 2}, rows{r, 2}), continue; end
                        a = pipecompare.gui.PanelValues.setParam(a, rows{r, 1}, pipecompare.gui.PanelValues.parseValues(T.Data{r, 2}, rows{r, 4}));
                    end
                    obj.Plan.Slots(k).alternatives{j} = a;
                    obj.invalidate('Plan changed'); obj.showPlan();
                    delete(d);
                catch ME
                    uialert(d, ME.message, 'PipeCompare');
                end
            end
        end

        function toggleSkip(obj)
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            has = any(cellfun(@(a) strcmp(a.type, 'none'), slot.alternatives));
            try
                obj.Plan = obj.Plan.setSkippable(slot.id, ~has);
                pipecompare.utils.log('%s: skipping %s.', slot.id, pipecompare.utils.ternary(~has, 'is now searched as an option', 'is no longer an option'));
                obj.invalidate('Plan changed'); obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function mustBefore(obj, other)
            k = obj.selected(); if isempty(k), return; end
            ids = {obj.Plan.Slots.id}; me = ids{k};
            if nargin < 2
                rest = ids(~strcmp(ids, me));
                if isempty(rest), return; end
                [j, ok] = listdlg('ListString', rest, 'SelectionMode', 'single', 'Name', sprintf('%s must come before', me));
                if ~ok, return; end
                other = rest{j};
            end
            obj.Plan = obj.Plan.before(me, other);
            if strcmp(obj.Plan.OrderMode, 'fixed')
                pipecompare.utils.log('Order rule %s before %s is used when Order = search.', me, other);
            end
            obj.invalidate('Plan changed'); obj.showPlan();
        end

        function clearOrderRules(obj)
            obj.Plan.Precedence = cell(0, 2);
            obj.invalidate('Plan changed'); obj.showPlan();
        end

        function type = dialogType(~, slot)
            % Which EEGLAB dialog(s) configure this slot.
            alts = slot.alternatives(~cellfun(@(a) strcmp(a.type, 'none'), slot.alternatives));
            assert(~isempty(alts), 'PipeCompare:Plan', 'The step has no configuration to edit.');
            type = alts{1}.type;
            if strcmp(type, 'eeglab')
                A = alts{1}.params.args;
                com = pipecompare.run.Native.eeglabCommand(alts{1}.params.fn, A, arrayfun(@(x) x.values{1}, A, 'UniformOutput', false));
                type = pipecompare.run.Native.typeOfCommand(com);
                if isempty(type), type = menuDialog(com); end
            elseif strcmp(type, 'native')
                type = pipecompare.run.Native.typeOfCommand(alts{1}.params.command);
                if isempty(type), type = menuDialog(alts{1}.params.command); end
            end
            if startsWith(type, 'call:'), return; end   % a step added from EEGLAB's menus
            ok = {'resample','highpass','lowpass','linenoise','filter','asr','badchannels','restore','reref','ica', ...
                'icremove','reject_threshold','reject_jointprob','reject_kurtosis'};
            assert(any(strcmp(type, ok)), 'PipeCompare:Native', ['%s has no EEGLAB dialog here (epoch and baseline come ', ...
                'from the analysis contract above; named channels from Edit values...).'], type);
        end

        function [com, EEG] = captureFor(obj, type, k)
            % The step's EEGLAB dialog, on the data as the plan has them when
            % step k runs (previewAt); epoch-level dialogs on epoched data.
            if nargin < 3, EEG = pipecompare.live.Session.current(); else, EEG = obj.previewAt(k); end
            switch type
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    if EEG.trials == 1, EEG = obj.previewEpoched(EEG); end
                    com = pipecompare.run.Native.captureWorkflow(type, EEG);
                case 'icremove'
                    assert(~isempty(EEG.icaweights), 'PipeCompare:Plan', ['There is no ICA decomposition at this step: ', ...
                        'add an ica step before it in the plan (or run ICA on the dataset).']);
                    com = pipecompare.run.Native.captureWorkflow(type, EEG);
                otherwise
                    if startsWith(type, 'call:')
                        com = pipecompare.run.Native.captureCall(EEG, type(6:end));   % the EEGLAB menu item's own call
                    else
                        com = pipecompare.run.Native.capture(type, EEG);
                    end
            end
        end

        function EEG = previewAt(obj, k)
            % A copy of the current dataset (continuous: its first 120 s) after
            % the plan's steps before step k, each with its first legal
            % configuration: what the dialog of step k would see.
            EEG = pipecompare.live.Session.current();
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset in EEGLAB.');
            if EEG.trials == 1 && EEG.pnts / EEG.srate > 120
                [~, EEG] = evalc('pop_select(EEG, ''time'', [0 120])');
            end
            if k <= 1, return; end
            c = obj.contract();
            [~, EEG] = evalc('pipecompare.run.Executor.prepareRoot(EEG, c, struct(''dataUnit'', ''uV''))');
            sub = obj.Plan; sub.Slots = sub.Slots(1:k-1); sub.OrderMode = 'fixed'; sub.Precedence = cell(0, 2);
            leaves = sub.enumerate(pipecompare.live.DataState.fromEEG(EEG), c, struct('maxLeaves', Inf));
            path = leaves(1).path;
            ctx = struct('contract', c, 'highpass', 0);
            for q = 1:numel(path)
                [~, EEG] = evalc('pipecompare.run.Steps.run(path{q}, EEG, ctx)');
            end
            if ~isempty(path)
                pipecompare.utils.log('Dialog on a preview copy%s after: %s', pipecompare.utils.ternary(EEG.trials == 1, ' (first 120 s)', ''), ...
                    strjoin(cellfun(@(i) i.label, path, 'UniformOutput', false), ' > '));
            end
        end

        function EEG = previewEpoched(obj, EEG)
            % The current dataset (or EEG), epoched on a copy with the
            % contract window when it is still continuous (epoch-level dialogs).
            if nargin < 2, EEG = pipecompare.live.Session.current(); end
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset in EEGLAB.');
            if EEG.trials > 1, return; end
            c = obj.contract();
            codes = c.allEvents();
            assert(~isempty(codes), 'PipeCompare:Contract', 'Define the conditions first (the preview is epoched on their events).');
            assert(numel(c.epoch) == 2, 'PipeCompare:Contract', 'Set the epoch first (EEGLAB pop_epoch...).');
            [~, EEG] = evalc('pop_epoch(EEG, codes, c.epoch, ''epochinfo'', ''yes'')');
            if ~isempty(c.baseline)
                [~, EEG] = evalc('pop_rmbase(EEG, 1000 * c.baseline, [])');
            end
            pipecompare.utils.log('Dialog on a preview copy epoched [%g %g] s on %s.', c.epoch, strjoin(codes, ', '));
        end

        function applyNow(obj)
            k = obj.selected(); if isempty(k), return; end
            alt = obj.Plan.Slots(k).alternatives{1};
            try
                before = pipecompare.live.Session.fingerprint(pipecompare.live.Session.current());
                if strcmp(alt.type, 'native')
                    pipecompare.run.Native.applyCommand(alt.params.command);   % the fixed command, no dialog
                elseif strcmp(alt.type, 'eeglab')
                    A = alt.params.args;
                    if numel(obj.Plan.Slots(k).alternatives) == 1 && all(cellfun(@numel, {A.values}) == 1)
                        pipecompare.run.Native.applyCommand(pipecompare.run.Native.eeglabCommand(alt.params.fn, A, ...
                            arrayfun(@(x) x.values{1}, A, 'UniformOutput', false)));
                    else   % several configurations: choose one in the dialog itself
                        pipecompare.run.Native.applyNow(obj.dialogType(obj.Plan.Slots(k)));
                    end
                else
                    pipecompare.run.Native.applyNow(alt.type);
                end
                obj.refreshLive(false);
                if strcmp(before, pipecompare.live.Session.fingerprint(pipecompare.live.Session.current()))
                    pipecompare.utils.log('Dialog cancelled or no change; the dataset is unchanged.');
                    return;
                end
                choice = uiconfirm(obj.Fig, 'Remove this step from the plan now that it is applied?', 'PipeCompare', ...
                    'Options', {'Remove from plan', 'Keep'});
                if strcmp(choice, 'Remove from plan'), obj.removeStep(); end
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        % -------------------------------------------------------------- run
        function c = contract(obj)
            [ep, bl] = obj.windows();
            c = pipecompare.eval.Contract('conditions', pipecompare.gui.PanelText.parseConditions(obj.CondField.Value), ...
                'components', pipecompare.gui.PanelText.parseComponents(obj.CompField.Value), 'epoch', ep, 'baseline', bl, 'trials', obj.TrialRule);
        end

        function [ep, bl] = windows(obj)
            % What the fields say; left empty: the epochs of an already
            % epoched dataset, and the pre-stimulus baseline [start 0].
            ep = str2num(obj.EpochField.Value); %#ok<ST2NM>
            bl = str2num(obj.BaseField.Value); %#ok<ST2NM>
            if isempty(ep)
                EEG = pipecompare.live.Session.current();
                if ~isempty(EEG) && EEG.trials > 1, ep = [EEG.xmin EEG.xmax]; end
            end
            if isempty(bl) && numel(ep) == 2 && ep(1) < 0, bl = [ep(1) 0]; end
        end

        % ------------------------------------- contract from EEGLAB dialogs
        function setField(obj, field, value)
            field.Value = value;
            obj.settingsChanged();
        end

        function settingsChanged(obj)
            obj.invalidate('Settings changed');
            obj.updateSummary();
            obj.updateObjectives();
        end

        function updateObjectives(obj)
            % objective choices from the components defined above
            try, names = obj.contract().objectiveNames(); catch, names = {}; end
            v = obj.ObjectiveField.Value;
            obj.ObjectiveField.Items = [{'composite'} names(:)'];
            if ~any(strcmp(v, obj.ObjectiveField.Items)), v = 'composite'; end
            obj.ObjectiveField.Value = v;
        end

        function optionsDialog(obj)
            o = obj.Options;
            d = uifigure('Name', 'PipeCompare search options', 'Position', [240 240 520 300], 'WindowStyle', 'modal');
            gl = uigridlayout(d, [4 3]); gl.ColumnWidth = {170, '1x', 110}; gl.RowHeight = repmat({26}, 1, 4);
            uilabel(gl, 'Text', 'Data unit of the dataset');
            du = uidropdown(gl, 'Items', {'auto', 'uV', 'V'}, 'Value', o.dataUnit, 'Tooltip', ...
                'auto: from the amplitude scale of the dataset; V: scaled to uV on PipeCompare''s copy (ICA weights too)');
            uilabel(gl, 'Text', '');
            uilabel(gl, 'Text', 'Checkpoint folder');
            ck = uilabel(gl, 'Text', pipecompare.gui.PanelText.orDash(o.checkpoint));
            uibutton(gl, 'Text', 'Choose...', 'ButtonPushedFcn', @(~, ~) pickDir());
            uilabel(gl, 'Text', 'Parallel (Parallel Computing Toolbox)');
            pa = uicheckbox(gl, 'Text', '', 'Value', o.parallel);
            uilabel(gl, 'Text', '');
            uilabel(gl, 'Text', '');
            uibutton(gl, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) delete(d));
            uibutton(gl, 'Text', 'OK', 'ButtonPushedFcn', @(~, ~) apply());
            function pickDir()
                p = uigetdir(pwd, 'Checkpoint folder (empty or of this same search)');
                if ischar(p), o.checkpoint = p; ck.Text = p; end
            end
            function apply()
                o.dataUnit = du.Value; o.parallel = pa.Value;
                obj.setOptions(o); delete(d);
            end
        end

        function setOptions(obj, o)
            obj.Options = o;
            pipecompare.utils.log('Search options: unit %s, checkpoint %s, parallel %d', o.dataUnit, pipecompare.gui.PanelText.orDash(o.checkpoint), o.parallel);
            obj.invalidate('Options changed');
        end

        function resume(obj, folder)
            if nargin < 2
                folder = uigetdir(pwd, 'Checkpoint folder of the interrupted search');
                if ~ischar(folder), return; end
            end
            try
                stop(obj.Timer); cleanup = onCleanup(@() restartTimer(obj.Timer)); %#ok<NASGU>
                obj.StatusLabel.Text = 'Resuming... progress in the Command Window'; drawnow;
                r = pipecompare.PipeCompare.resume(folder);
                obj.Result = r; assignin('base', 'pipecompare_result', r);
                obj.showResults();
                obj.StatusLabel.Text = 'Resumed search done. Result in variable pipecompare_result.';
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function editChanlocs(obj)
            try
                pipecompare.run.Native.applyNow('chanlocs');
                obj.refreshLive(false);
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function viewErp(obj)
            % EEGLAB's ERP + scalp map viewer on epoched preview data
            try
                EEG = obj.previewEpoched();
                EEG.setname = sprintf('%s (PipeCompare preview, all conditions)', EEG.setname);
                pop_timtopo(EEG);
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function inspect(obj, which, view)
            % A candidate (rebuilt from the stored start, not adopted) or the
            % source dataset in one of EEGLAB's own viewers.
            if nargin < 2
                k = obj.selectedResult(); if isempty(k), return; end
                srcs = {sprintf('Candidate %d: %s', k, obj.Result.labels{k}), 'Source dataset (start of the search)'};
                [w, ok] = listdlg('ListString', srcs, 'SelectionMode', 'single', 'Name', 'Inspect', 'ListSize', [420 60]);
                if ~ok, return; end
                which = k; if w == 2, which = 0; end
                views = {'Scroll data (eegplot)', 'ERP and scalp maps (pop_timtopo)', 'ERPs at all channels (pop_plottopo)', ...
                    'IC maps (pop_selectcomps)'};
                [view, ok] = listdlg('ListString', views, 'SelectionMode', 'single', 'Name', 'EEGLAB viewer', 'ListSize', [300 80]);
                if ~ok, return; end
            end
            r = obj.Result;
            try
                if which == 0
                    E = pipecompare.run.Executor.rootOf(r); E.setname = sprintf('%s (PipeCompare source, start of the search)', r.state.setname);
                else
                    [~, E] = evalc('pipecompare.run.Executor.replay(r, which)');
                    E.setname = sprintf('PipeCompare candidate %d (not adopted): %s', which, r.labels{which});
                end
                if E.trials == 1 && view > 1
                    codes = r.contract.allEvents();
                    [~, E] = evalc('pop_epoch(E, codes, r.contract.epoch)');
                end
                switch view
                    case 1, pop_eegplot(E, 1, 1, 0);
                    case 2, pop_timtopo(E);
                    case 3, pop_plottopo(E);
                    case 4
                        assert(~isempty(E.icaweights), 'PipeCompare:Inspect', 'This dataset has no ICA decomposition.');
                        pop_selectcomps(E, 1:min(35, size(E.icaweights, 1)));
                end
            catch ME
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function addCondition(obj, name, codes)
            % Name a condition and pick its codes from the current events
            % (EEGLAB's pop_chansel list, as in pop_epoch's event button).
            if nargin < 3
                EEG = pipecompare.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'PipeCompare'); return; end
                s = pipecompare.live.DataState.fromEEG(EEG);
                if isempty(s.eventTypes), uialert(obj.Fig, 'The dataset has no events.', 'PipeCompare'); return; end
                items = arrayfun(@(k) sprintf('%s  (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:numel(s.eventTypes), 'UniformOutput', false);
                idx = pop_chansel(items, 'withindex', 'off');
                if isempty(idx), return; end
                codes = s.eventTypes(idx);
                a = inputdlg(sprintf('Name of the condition with events %s:', strjoin(codes, ', ')), ...
                    'PipeCompare condition', 1, {sprintf('cond%d', size(pipecompare.gui.PanelText.parseConditions(obj.CondField.Value), 1) + 1)});
                if isempty(a) || isempty(strtrim(a{1})), return; end
                name = strtrim(a{1});
            end
            conds = pipecompare.gui.PanelText.parseConditions(obj.CondField.Value);
            assert(~any(strcmpi(conds(:, 1), name)), 'PipeCompare:Contract', 'A condition named %s exists already.', name);
            used = intersect(cellstr(codes), [conds{:, 2}]);
            if ~isempty(used)
                uialert(obj.Fig, sprintf('Event code(s) %s already belong to another condition.', strjoin(used, ', ')), 'PipeCompare');
                return;
            end
            conds(end+1, :) = {name, cellstr(codes)};
            obj.setField(obj.CondField, pipecompare.gui.PanelText.conditionsText(conds));
            pipecompare.utils.log('Condition %s = events %s', name, strjoin(cellstr(codes), ', '));
        end

        function epochFromEEGLAB(obj, com, choice)
            % EEGLAB's epoching dialog on a copy; its window is the epoch.
            % When its events differ from the conditions, or it sets options
            % the epoch step does not use, you decide in a dialog (choice:
            % 'replace' | 'keep' for scripts and tests).
            if nargin < 2
                EEG = pipecompare.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'PipeCompare'); return; end
                if EEG.trials > 1
                    uialert(obj.Fig, 'The dataset is already epoched; the epoch is fixed by the data.', 'PipeCompare'); return;
                end
                com = pipecompare.run.Native.captureCall(EEG, '[EEG, ~, LASTCOM] = pop_epoch(EEG);');
                if isempty(com), return; end
            end
            a = pipecompare.run.Native.argsOf(com, 'pop_epoch');
            assert(numel(a) >= 2 && isnumeric(a{2}) && numel(a{2}) == 2, 'PipeCompare:Native', 'No epoch limits in %s', com);
            types = a{1}; if ~iscell(types), types = {types}; end
            types = cellfun(@(x) strtrim(char(string(x))), types, 'UniformOutput', false);
            conds = pipecompare.gui.PanelText.parseConditions(obj.CondField.Value);
            extra = a(3:end);
            keys = extra(1:2:end); keys = keys(cellfun(@ischar, keys));
            ignored = setdiff(keys, {'epochinfo','newname'});
            differ = ~isempty(conds) && ~isempty(types) && ~isempty(setxor(types, [conds{:, 2}]));
            if differ || ~isempty(ignored)
                msg = {};
                if differ
                    msg{end+1} = sprintf(['The dialog epochs on %s; your conditions use %s. PipeCompare epochs on the ', ...
                        'condition events.'], strjoin(types, ', '), strjoin([conds{:, 2}], ', '));
                end
                if ~isempty(ignored)
                    msg{end+1} = sprintf('Option(s) %s of pop_epoch are not part of the epoch step and will not be used.', strjoin(ignored, ', '));
                end
                if nargin < 3
                    opts = {'Keep my conditions', 'Cancel'};
                    if differ, opts = [{'Use the dialog''s events as conditions'} opts]; end
                    c = uiconfirm(obj.Fig, strjoin(msg, ' '), 'PipeCompare: epoch', 'Options', opts, ...
                        'DefaultOption', 1, 'CancelOption', numel(opts));
                    if strcmp(c, 'Cancel'), return; end
                    choice = 'keep'; if startsWith(c, 'Use'), choice = 'replace'; end
                end
                if differ && strcmp(choice, 'replace'), conds = cell(0, 2); end
                pipecompare.utils.log('%s', strjoin(msg, ' '));
            end
            obj.EpochField.Value = num2str(a{2});
            if isempty(conds) && ~isempty(types)
                conds = [types(:) cellfun(@(t) {t}, types(:), 'UniformOutput', false)];
                obj.CondField.Value = pipecompare.gui.PanelText.conditionsText(conds);
                pipecompare.utils.log('Conditions set from the epoching events (one per code): %s', strjoin(types, ', '));
            end
            obj.settingsChanged();
            pipecompare.utils.log('Epoch from EEGLAB: [%s] s', obj.EpochField.Value);
        end

        function baselineFromEEGLAB(obj, com, choice)
            % EEGLAB's baseline dialog on epoched preview data (the dataset
            % itself, or a copy epoched with the planned window). A channel
            % subset is not silently widened: you confirm (choice 'all' |
            % 'cancel' for scripts and tests).
            if nargin < 2
                EEG = pipecompare.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'PipeCompare'); return; end
                if EEG.trials == 1
                    c = obj.contract();
                    codes = c.allEvents();
                    assert(~isempty(codes), 'PipeCompare:Contract', 'Define the conditions first (the preview is epoched on their events).');
                    assert(numel(c.epoch) == 2, 'PipeCompare:Contract', 'Set the epoch first (EEGLAB pop_epoch...).');
                    [~, EEG] = evalc('pop_epoch(EEG, codes, c.epoch, ''epochinfo'', ''yes'')');   % no baseline removed yet
                    pipecompare.utils.log('Baseline dialog on a preview copy epoched [%g %g] s on %s.', c.epoch, strjoin(codes, ', '));
                end
                com = pipecompare.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_rmbase(EEG);');
                if isempty(com), return; end
            else
                EEG = [];
            end
            a = pipecompare.run.Native.argsOf(com, 'pop_rmbase');
            ms = []; if ~isempty(a), ms = a{1}; end
            if isempty(ms) && numel(a) >= 2 && ~isempty(a{2}) && ~isempty(EEG)
                ms = EEG.times(a{2}([1 end]));                   % given as points
            end
            assert(numel(ms) == 2, 'PipeCompare:Native', 'No baseline range in %s', com);
            nAll = []; if ~isempty(EEG), nAll = EEG.nbchan; end
            if numel(a) >= 3 && ~isempty(a{3}) && ~(~isempty(nAll) && numel(a{3}) >= nAll)
                msg = sprintf(['The dialog removes the baseline on %d channel(s) only; PipeCompare removes it on all ', ...
                    'channels (the measure compares channels on the same footing).'], numel(a{3}));
                if nargin < 3
                    c = uiconfirm(obj.Fig, msg, 'PipeCompare: baseline', 'Options', {'Use the window for all channels', 'Cancel'}, ...
                        'DefaultOption', 1, 'CancelOption', 2);
                    choice = 'all'; if strcmp(c, 'Cancel'), choice = 'cancel'; end
                end
                if strcmp(choice, 'cancel'), return; end
                pipecompare.utils.log('%s', msg);
            end
            obj.BaseField.Value = num2str(ms / 1000);
            obj.settingsChanged();
            pipecompare.utils.log('Baseline from EEGLAB: [%g %g] ms -> [%s] s', ms, obj.BaseField.Value);
        end

        function addComponent(obj, name, win, roi, measure, polarity)
            if nargin < 2
                a = inputdlg({'Component name', 'Window start (s)', 'Window end (s)'}, 'PipeCompare component', 1, ...
                    {'', '', ''});
                if isempty(a), return; end
                name = strtrim(a{1}); win = [str2double(a{2}) str2double(a{3})];
                assert(~isempty(name) && all(isfinite(win)) && win(2) > win(1), 'PipeCompare:Contract', ...
                    'Give a name and a window with start < end (s).');
                ms = {'mean amplitude', 'peak amplitude (positive)', 'peak amplitude (negative)', ...
                    'peak latency (positive)', 'peak latency (negative)'};
                [k, ok] = listdlg('ListString', ms, 'SelectionMode', 'single', 'Name', 'Measure', 'ListSize', [260 110]);
                if ~ok, return; end
                measure = {'mean','peakAmplitude','peakAmplitude','peakLatency','peakLatency'}; measure = measure{k};
                polarity = {'positive','positive','negative','positive','negative'}; polarity = polarity{k};
                roi = obj.pickChannels();
                if isempty(roi), return; end
            end
            comps = pipecompare.gui.PanelText.parseComponents(obj.CompField.Value);
            comps(end+1, :) = {name, win, cellstr(roi), {measure, polarity}};
            obj.setField(obj.CompField, pipecompare.gui.PanelText.componentsText(comps));
        end

        function setRoi(obj, k, roi)
            comps = pipecompare.gui.PanelText.parseComponents(obj.CompField.Value);
            if isempty(comps), uialert(obj.Fig, 'Add a component first.', 'PipeCompare'); return; end
            if nargin < 2
                k = 1;
                if size(comps, 1) > 1
                    [k, ok] = listdlg('ListString', comps(:, 1), 'SelectionMode', 'single', 'Name', 'Component');
                    if ~ok, return; end
                end
                roi = obj.pickChannels(comps{k, 3});
                if isempty(roi), return; end
            end
            comps{k, 3} = cellstr(roi);
            obj.setField(obj.CompField, pipecompare.gui.PanelText.componentsText(comps));
        end

        function labels = pickChannels(obj, current)
            % EEGLAB's channel selection over the current dataset's channels.
            labels = {};
            EEG = pipecompare.live.Session.current();
            if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'PipeCompare'); return; end
            args = {'withindex', 'on'};
            if nargin > 1 && ~isempty(current)
                [~, sel] = ismember(lower(current), lower({EEG.chanlocs.labels}));
                args = [args {'select', sel(sel > 0)}];
            end
            [idx, ~, names] = pop_chansel({EEG.chanlocs.labels}, args{:});
            if ~isempty(idx), labels = {EEG.chanlocs(idx).labels}; elseif iscell(names), labels = names; end
            if ~isempty(labels), pipecompare.utils.log('ROI: %s (%d channels)', strjoin(labels, ' '), numel(labels)); end
        end

        function chooseTrials(obj)
            opts = {'All trials', 'Between a start and an end marker', 'Time ranges (EEGLAB pop_select)', ...
                'EEGLAB event selection (pop_selectevent)'};
            [k, ok] = listdlg('ListString', opts, 'SelectionMode', 'single', 'Name', 'Trials', 'ListSize', [300 90]);
            if ~ok, return; end
            EEG = pipecompare.live.Session.current();
            if isempty(EEG) && k > 1, uialert(obj.Fig, 'No dataset in EEGLAB.', 'PipeCompare'); return; end
            switch k
                case 1
                    obj.setTrialRule(struct('mode', 'all'));
                case 2
                    s = pipecompare.live.DataState.fromEEG(EEG);
                    a = pop_chansel(s.eventTypes, 'selectionmode', 'single', 'withindex', 'off');
                    if isempty(a), return; end
                    b = pop_chansel(s.eventTypes, 'selectionmode', 'single', 'withindex', 'off');
                    if isempty(b), return; end
                    obj.setTrialRule(struct('mode', 'marker_ranges', 'startCode', s.eventTypes{a}, 'endCode', s.eventTypes{b}));
                case 3
                    assert(EEG.trials == 1, 'PipeCompare:Contract', 'Time ranges apply to continuous data.');
                    com = pipecompare.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_select(EEG);');
                    if isempty(com), return; end
                    obj.trialRuleFromTimeSelection(com, (EEG.pnts - 1) / EEG.srate);
                case 4
                    if ~isfield(EEG, 'urevent') || isempty(EEG.urevent), [~, EEG] = evalc('eeg_checkset(EEG, ''makeur'')'); end
                    [com, sel] = pipecompare.run.Native.captureCall(EEG, '[EEG, ~, LASTCOM] = pop_selectevent(EEG);');
                    if isempty(com), return; end
                    obj.trialRuleFromSelection(sel, com);
            end
        end

        function trialRuleFromTimeSelection(obj, com, duration)
            % Time ranges kept ('time') or removed ('notime') in EEGLAB's
            % data selection dialog -> trials whose events fall inside.
            a = pipecompare.run.Native.argsOf(com, 'pop_select');
            k = find(cellfun(@(x) ischar(x) && any(strcmpi(x, {'time', 'notime', 'rmtime'})), a), 1);
            assert(~isempty(k) && numel(a) > k, 'PipeCompare:Contract', 'The selection keeps or removes no time range: %s', com);
            r = a{k + 1};
            if ~strcmpi(a{k}, 'time')   % removed ranges -> the complement is kept
                r = sortrows(r); edges = [0; reshape(r', [], 1); duration];
                r = reshape(edges, 2, [])'; r = r(r(:, 2) > r(:, 1), :);
            end
            obj.setTrialRule(struct('mode', 'time_ranges', 'ranges', r, 'source', com));
        end

        function trialRuleFromSelection(obj, sel, com)
            % The trials are the condition events that the EEGLAB event
            % selection kept (identified by urevent).
            c = obj.contract();
            codes = c.allEvents();
            assert(~isempty(codes), 'PipeCompare:Contract', 'Define the conditions first.');
            ty = arrayfun(@(e) strtrim(char(string(e.type))), sel.event, 'UniformOutput', false);
            keep = ismember(ty, codes) & arrayfun(@(e) isfield(e, 'urevent') && ~isempty(e.urevent), sel.event);
            ids = unique(arrayfun(@(e) double(e.urevent), sel.event(keep)));
            assert(~isempty(ids), 'PipeCompare:TrialRule', 'The event selection keeps no condition event.');
            obj.setTrialRule(struct('mode', 'urevents', 'ids', ids(:)', 'source', com));
        end

        function setTrialRule(obj, rule)
            c = pipecompare.eval.Contract('trials', rule); c.validateTrialRule();
            obj.TrialRule = rule;
            obj.TrialRuleSource = '';
            EEG = pipecompare.live.Session.current();
            if ~isempty(EEG), obj.TrialRuleSource = recordingId(EEG); end
            obj.TrialLabel.Text = pipecompare.gui.PanelText.trialText(rule);
            pipecompare.utils.log('Trial rule: %s', obj.TrialLabel.Text);
            obj.settingsChanged();
        end

        function checkTrialRule(obj, EEG, s)
            % A trial rule belongs to the recording it was set on. Event ids
            % (urevents) mean other trials in another recording, so that rule
            % is reset; marker rules need their markers; time ranges are
            % kept but shown as coming from the other recording.
            r = obj.TrialRule;
            if strcmp(r.mode, 'all') || isempty(obj.TrialRuleSource), return; end
            if strcmp(recordingId(EEG), obj.TrialRuleSource), return; end
            reset = '';
            switch r.mode
                case 'urevents'
                    reset = 'its event ids refer to the trials of the previous recording';
                case 'marker_ranges'
                    missing = setdiff({char(string(r.startCode)), char(string(r.endCode))}, s.eventTypes);
                    if ~isempty(missing), reset = sprintf('marker(s) %s are not in this recording', strjoin(missing, ', ')); end
            end
            if ~isempty(reset)
                msg = sprintf('Trial rule reset to all trials: %s.', reset);
                obj.TrialRule = struct('mode', 'all'); obj.TrialRuleSource = '';
                obj.TrialLabel.Text = 'all trials';
            else
                msg = sprintf('Trial rule kept from the previous recording (%s): check that it fits this one.', pipecompare.gui.PanelText.trialText(r));
                obj.TrialLabel.Text = [pipecompare.gui.PanelText.trialText(r) '  (set on another recording)'];
            end
            pipecompare.utils.log('%s', msg);
            obj.StatusLabel.Text = msg;
            obj.invalidate('Settings changed');
        end

        function updateSummary(obj)
            % Trials per condition in the current dataset, under the rule.
            if isempty(obj.SummaryLabel) || ~isvalid(obj.SummaryLabel), return; end
            try
                EEG = pipecompare.live.Session.current();
                c = obj.contract();
                if isempty(EEG) || isempty(c.conditions), obj.SummaryLabel.Text = ''; return; end
                [elig, E] = pipecompare.run.Executor.eligibleUrevents(EEG, c);
                parts = cell(1, numel(c.conditions));
                for k = 1:numel(c.conditions)
                    if E.trials == 1
                        ty = arrayfun(@(e) strtrim(char(string(e.type))), E.event, 'UniformOutput', false);
                        isC = ismember(ty, c.conditions(k).events);
                        n = sum(isC);
                        ne = n; if ~isempty(elig), ne = sum(ismember(arrayfun(@(e) double(e.urevent), E.event(isC)), elig)); end
                    else
                        if ~isempty(elig), E.etc.pipecompare.eligibleUrevents = elig; end
                        T = pipecompare.eval.Measure.trials(E, c);
                        n = NaN; ne = sum(T.cond == k);
                    end
                    if isempty(elig) || isnan(n), parts{k} = sprintf('%s %d', c.conditions(k).name, ne);
                    else, parts{k} = sprintf('%s %d of %d', c.conditions(k).name, ne, n); end
                end
                roi = ''; if ~isempty(c.components), roi = sprintf(' | ROI channels: %d', numel(c.allRoi())); end
                obj.SummaryLabel.Text = ['Trials: ' strjoin(parts, ', ') roi];
                obj.SummaryLabel.FontColor = [0 0.3 0.1];
            catch ME
                obj.SummaryLabel.Text = ME.message;
                obj.SummaryLabel.FontColor = [0.7 0.2 0];
            end
        end

        function run(obj, dry)
            try
                c = obj.contract();
                opts = struct('dryRun', dry);
                ob = strtrim(obj.ObjectiveField.Value);
                opts.objective = ob;
                for f = fieldnames(obj.LimitFields)'
                    opts.(f{1}) = obj.LimitFields.(f{1}).Value;
                end
                for f = fieldnames(obj.Options)'
                    if ~isempty(obj.Options.(f{1})) || islogical(obj.Options.(f{1})), opts.(f{1}) = obj.Options.(f{1}); end
                end
                if strcmp(opts.dataUnit, 'auto')
                    s = pipecompare.live.DataState.fromEEG(pipecompare.live.Session.current());
                    opts.dataUnit = s.unitGuess;
                    pipecompare.utils.log('Data unit: %s (judged from the amplitude scale; set it in Options... to override).', s.unitGuess);
                end
                obj.StatusLabel.Text = 'Running... progress in the Command Window'; drawnow;
                stop(obj.Timer);
                cleanup = onCleanup(@() restartTimer(obj.Timer));
                r = pipecompare.PipeCompare.optimize(obj.Plan, c, opts);
                if ~isvalid(obj) || ~isvalid(obj.Fig)      % the window was closed during the search
                    if ~dry, assignin('base', 'pipecompare_result', r); end
                    pipecompare.utils.log('Panel closed during the search; the result is in pipecompare_result.');
                    return;
                end
                if dry
                    obj.StatusLabel.Text = sprintf('%d pipelines, %d step runs (shared prefixes)', r.report.nLeaves, r.report.nNodes);
                    return;
                end
                obj.Result = r;
                assignin('base', 'pipecompare_result', r);
                obj.showResults();
                obj.StatusLabel.Text = 'Done. Result in variable pipecompare_result.';
                pipecompare.utils.log('Result stored in the base variable pipecompare_result.');
            catch ME
                pipecompare.utils.log('ERROR: %s', ME.message);
                if ~isvalid(obj) || ~isvalid(obj.Fig), return; end
                obj.StatusLabel.Text = 'Error (see dialog)';
                uialert(obj.Fig, ME.message, 'PipeCompare');
            end
        end

        function showResults(obj)
            r = obj.Result; T = r.ranking.table; data = {};
            recs = [r.ranking.byStratum.recommended];
            for k = r.ranking.order(:)'
                ci = ''; if isfinite(T.diffLo(k)), ci = sprintf('[%+.3f %+.3f]', T.diffLo(k), T.diffHi(k)); end
                id = sprintf('%d', k); if any(recs == k), id = [id '*']; end
                txt = r.labels{k}; if ~isempty(T.reason{k}), txt = [T.reason{k} ' | ' txt]; end
                if ismember('note', T.Properties.VariableNames) && ~isempty(T.note{k}), txt = ['(note, see below) ' txt]; end
                if ~isempty(T.stratum{k}), txt = ['[' T.stratum{k} '] ' txt]; end
                data(end+1, :) = {id, T.status{k}, pipecompare.gui.PanelText.num(T.objective(k), '%.4g'), ci, T.notDistinguished(k), ...
                    pipecompare.gui.PanelText.pctText(T.minRetention(k)), pipecompare.gui.PanelText.pctText(T.interpolated(k)), pipecompare.gui.PanelText.pctText(T.ampError(k)), pipecompare.gui.PanelText.pctText(T.artifactPct(k)), txt}; %#ok<AGROW>
            end
            obj.ResultTable.Data = data;
        end

        function showDetails(obj, kind, t)
            % The full content of the selected row, wrapped, whatever the
            % column widths.
            sel = t.Selection;
            if isempty(sel) || isempty(t.Data), return; end
            r = sel(1, 1);
            try
                switch kind
                    case 'history'
                        h = t.Data(r, :);
                        v = {sprintf('EEG.history line %d (%s, %s):', h{1}, h{2}, pipecompare.gui.PanelText.orDash(h{3})), h{4}};
                    case 'plan'
                        slot = obj.Plan.Slots(r);
                        v = {sprintf('Step %d: %s', r, slot.id), ...
                            ['Values: ' pipecompare.gui.PanelValues.settingsText(slot, struct('epoch', obj.EpochField.Value, 'baseline', obj.BaseField.Value))]};
                        for a = 1:numel(slot.alternatives)
                            alt = slot.alternatives{a};
                            if strcmp(alt.type, 'native'), v = [v {'EEGLAB command(s):'} pipecompare.run.Native.statements(alt.params.command)]; end %#ok<AGROW>
                        end
                    case 'result'
                        k = str2double(strrep(t.Data{r, 1}, '*', ''));
                        T = obj.Result.ranking.table;
                        v = {sprintf('Candidate %d (%s)%s', k, T.status{k}, pipecompare.utils.ternary(endsWith(t.Data{r, 1}, '*'), ', recommended', '')), ...
                            ['Pipeline: ' obj.Result.labels{k}]};
                        if ~isempty(T.reason{k}), v{end+1} = ['Reason: ' T.reason{k}]; end
                        if ismember('note', T.Properties.VariableNames) && ~isempty(T.note{k}), v{end+1} = ['Note: ' T.note{k}]; end
                        if ~isempty(T.stratum{k}), v{end+1} = ['Stratum (what is measured): ' T.stratum{k}]; end
                        v{end+1} = sprintf(['Objective (gain-corrected SME) %.4g; difference from the best [%.3g %.3g]; not distinguished %d; ', ...
                            'min retention %s; min trials %g; interpolated %s; amplitude error %s; latency shift %.3g ms; ', ...
                            'artifactual deflection %s; waveform r %.3f; topography r %.3f'], T.objective(k), T.diffLo(k), T.diffHi(k), ...
                            T.notDistinguished(k), pipecompare.gui.PanelText.pctText(T.minRetention(k)), T.minTrials(k), pipecompare.gui.PanelText.pctText(T.interpolated(k)), ...
                            pipecompare.gui.PanelText.pctText(T.ampError(k)), T.latencyShiftMs(k), pipecompare.gui.PanelText.pctText(T.artifactPct(k)), T.waveformCorr(k), T.topoCorr(k));
                        c = obj.Result.cands(k);
                        if ~isempty(c.unmatched), v{end+1} = ['Signal check not decision-matched for: ' strjoin(c.unmatched, ', ')]; end
                        v = [v {'EEGLAB commands:'} c.coms(:)'];
                end
                obj.DetailArea.Value = v(:);
            catch ME
                obj.DetailArea.Value = {ME.message};
            end
        end

        function k = selectedResult(obj)
            k = [];
            if isempty(obj.Result), uialert(obj.Fig, 'Run a search first.', 'PipeCompare'); return; end
            sel = obj.ResultTable.Selection;
            if isempty(sel)
                R = obj.Result.ranking;
                k = R.recommended;
                if isempty(k) && numel(R.byStratum) > 1
                    uialert(obj.Fig, sprintf(['The candidates fall into %d strata (different references): they measure ', ...
                        'different quantities and are not compared with each other, so there is no single ', ...
                        'recommendation. Each stratum''s recommendation is marked *; select the row you want, ', ...
                        'according to your analysis.'], numel(R.byStratum)), 'PipeCompare');
                elseif isempty(k)
                    uialert(obj.Fig, 'No candidate satisfies the constraints; the reasons are in the table.', 'PipeCompare');
                end
                return;
            end
            k = str2double(strrep(obj.ResultTable.Data{sel(1, 1), 1}, '*', ''));
        end

        function adopt(obj)
            k = obj.selectedResult(); if isempty(k), return; end
            stop(obj.Timer); cleanup = onCleanup(@() restartTimer(obj.Timer)); %#ok<NASGU>
            try
                pipecompare.PipeCompare.adopt(obj.Result, k);
            catch ME
                if ~any(strcmp(ME.identifier, {'PipeCompare:Adopt','PipeCompare:ReplayMismatch','PipeCompare:StaleState'}))
                    uialert(obj.Fig, ME.message, 'PipeCompare'); return;
                end
                choice = uiconfirm(obj.Fig, ME.message, 'PipeCompare: adopt anyway?', ...
                    'Options', {'Adopt anyway', 'Cancel'}, 'DefaultOption', 2, 'CancelOption', 2, 'Icon', 'warning');
                if strcmp(choice, 'Adopt anyway'), pipecompare.PipeCompare.adopt(obj.Result, k, true); end
            end
        end

        function printScript(obj)
            k = obj.selectedResult(); if isempty(k), return; end
            pipecompare.utils.log('EEGLAB commands of candidate %d:', k);
            pipecompare.PipeCompare.script(obj.Result, k);
        end
    end
end

function id = recordingId(EEG)
% Which recording the data come from, unchanged by filtering, epoching or
% rejection of the same recording: its file and its original event table.
f = '';
if isfield(EEG, 'filename') && ~isempty(EEG.filename), f = fullfile(char(EEG.filepath), char(EEG.filename)); end
ev = []; if isfield(EEG, 'urevent') && ~isempty(EEG.urevent), ev = EEG.urevent; elseif EEG.trials == 1, ev = EEG.event; end
lat = 0; n = numel(ev);
if n > 0 && isfield(ev, 'latency'), lat = sum(double([ev.latency]) .* (1:n)); end
id = sprintf('%s|%d|%.12g', f, n, lat);
end

function fitLayout(g, pos)
% Every part keeps the size it needs; below that the window scrolls.
if pos(4) < 840, g.RowHeight = {80, 300, 470}; else, g.RowHeight = {80, 300, '1x'}; end
if pos(3) < 1300, g.ColumnWidth = {560, 720}; else, g.ColumnWidth = {'1x', '1.25x'}; end
g.Scrollable = matlab.lang.OnOffSwitchState(pos(4) < 840 || pos(3) < 1300);
end

function type = menuDialog(command)
% 'call:<the call>' of the EEGLAB menu item whose function made the
% command (a step added from EEGLAB's menus), so its dialog can reopen.
st = pipecompare.run.Native.statements(command);
e = pipecompare.live.History.classify(st{1});
items = pipecompare.run.Native.menuSteps();
i = find(strcmp({items.fn}, e.fn), 1);
assert(~isempty(i), 'PipeCompare:Native', ['No EEGLAB menu item calls %s (is EEGLAB''s main window open?); ', ...
    'use Edit values... for this step.'], e.fn);
type = ['call:' items(i).call];
end

function alt = stepAlt(com)
% A captured dialog command as a plan alternative: a single EEGLAB call
% becomes parameterised (its arguments can be searched), a workflow stays
% a fixed native step.
alt = pipecompare.run.Native.eeglabAlt(com);
if isempty(alt), alt = pipecompare.plan.Plan.nativeAlt(com); end
end

function restartTimer(t)
% Resume the live refresh after a long action, unless the panel (and its
% timer) was closed meanwhile: closing the window during a search must
% not end in an error from the cleanup.
if ~isempty(t) && isvalid(t) && strcmp(t.Running, 'off'), start(t); end
end
