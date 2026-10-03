classdef Panel < handle
    %PANEL NeuroQC panel: live dataset + history, plan, contract, results.
    %
    %   neuroqc.gui.Panel()   (or EEGLAB > Tools > NeuroQC)
    %
    %   There is no load button: the panel follows the dataset that is
    %   current in EEGLAB and re-reads it (and its EEG.history) whenever it
    %   changes, including changes made through EEGLAB menus or the command
    %   line. Everything the panel does is also printed in the Command
    %   Window; results are assigned to the base variable neuroqc_result.

    properties
        Plan
        Result
        Fig
        Timer
        LastFingerprint = ''
        % widgets
        DatasetLabel; WarnArea; HistTable
        PlanTable; TypeDrop; OrderDrop; ConstraintLabel
        CondField; EpochField; BaseField; CompField; EventsLabel
        TrialRule = struct('mode', 'all')
        TrialLabel; SummaryLabel
        LimitFields = struct()
        ObjectiveField
        Options = struct('dataUnit', 'uV', 'checkpoint', '', 'searchMode', 'exhaustive', 'sampleSize', 100, ...
            'parallel', false, 'externalQC', [])
        ResultTable; StatusLabel
    end

    methods
        function obj = Panel()
            obj.Plan = neuroqc.plan.Plan();
            obj.build();
            obj.refreshLive(true);
            obj.Timer = timer('ExecutionMode', 'fixedSpacing', 'Period', 1, 'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.refreshLive(false), 'Name', 'neuroqc_panel');
            start(obj.Timer);
            neuroqc.utils.log('Panel open. It follows the current EEGLAB dataset.');
        end

        function delete(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer), stop(obj.Timer); delete(obj.Timer); end
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        % ------------------------------------------------------------ layout
        function build(obj)
            obj.Fig = uifigure('Name', sprintf('NeuroQC %s', neuroqc.NeuroQC.version()), ...
                'Position', [60 60 1380 860], 'CloseRequestFcn', @(~, ~) obj.delete());
            g = uigridlayout(obj.Fig, [3 2]);
            g.RowHeight = {80, 300, '1x'}; g.ColumnWidth = {'1x', '1.25x'};   % contract and results get the remaining height

            top = uigridlayout(g, [1 2]); top.Layout.Column = [1 2]; top.ColumnWidth = {'1x', '1x'}; top.Padding = [0 0 0 0];
            obj.DatasetLabel = uilabel(top, 'Text', 'No dataset', 'FontName', 'Courier', 'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.WarnArea = uitextarea(top, 'Editable', 'off', 'FontColor', [0.6 0.2 0], 'Value', {''});

            % history (left, rows 2-3)
            hp = uipanel(g, 'Title', 'EEG.history of the current dataset (live)'); hp.Layout.Row = 2; hp.Layout.Column = 1;
            hg = uigridlayout(hp, [1 1]);
            obj.HistTable = uitable(hg, 'ColumnName', {'line','kind','step','statement'}, ...
                'ColumnWidth', {40, 60, 95, 'auto'}, 'RowName', {});

            % plan (right, row 2)
            pp = uipanel(g, 'Title', 'Plan: steps after the current dataset (fixed = one value, search = {list})');
            pp.Layout.Row = 2; pp.Layout.Column = 2;
            pg = uigridlayout(pp, [5 1]); pg.RowHeight = {'1x', 28, 28, 28, 20};
            obj.PlanTable = uitable(pg, 'ColumnName', {'#','step','settings (editable)','pinned'}, ...
                'ColumnEditable', [false false true true], 'ColumnWidth', {30, 110, 'auto', 55}, 'RowName', {}, ...
                'CellEditCallback', @(~, e) obj.planEdited(e));
            b1 = uigridlayout(pg, [1 7]); b1.Padding = [0 0 0 0];
            obj.TypeDrop = uidropdown(b1, 'Items', neuroqc.plan.Catalog.types());
            uibutton(b1, 'Text', 'Add', 'ButtonPushedFcn', @(~, ~) obj.addStep());
            uibutton(b1, 'Text', 'Remove', 'ButtonPushedFcn', @(~, ~) obj.removeStep());
            uibutton(b1, 'Text', 'Up', 'ButtonPushedFcn', @(~, ~) obj.moveStep(-1));
            uibutton(b1, 'Text', 'Down', 'ButtonPushedFcn', @(~, ~) obj.moveStep(1));
            uilabel(b1, 'Text', 'Order:', 'HorizontalAlignment', 'right');
            obj.OrderDrop = uidropdown(b1, 'Items', {'fixed','search'}, 'ValueChangedFcn', @(s, ~) obj.setOrder(s.Value));
            b2 = uigridlayout(pg, [1 4]); b2.Padding = [0 0 0 0];
            uibutton(b2, 'Text', 'Values from EEGLAB dialog...', 'Tooltip', ...
                ['Set the selected step''s values in its EEGLAB dialog; each time adds the values to the step''s ', ...
                 'search (the step keeps NeuroQC''s decision-matched signal check)'], ...
                'ButtonPushedFcn', @(~, ~) obj.valuesFromDialog());
            uibutton(b2, 'Text', 'Fix via EEGLAB dialog', 'Tooltip', ...
                'Open the native EEGLAB dialog for the selected step; its command replaces the step as a fixed native step', ...
                'ButtonPushedFcn', @(~, ~) obj.captureStep());
            uibutton(b2, 'Text', 'Apply now in EEGLAB', 'Tooltip', ...
                'Run the selected step on the current dataset through the EEGLAB dialog (recorded in EEG.history); the plan then starts after it', ...
                'ButtonPushedFcn', @(~, ~) obj.applyNow());
            uibutton(b2, 'Text', 'Catalog help', 'ButtonPushedFcn', @(~, ~) obj.catalogHelp());
            b3 = uigridlayout(pg, [1 5]); b3.Padding = [0 0 0 0];
            uibutton(b3, 'Text', 'Add config (EEGLAB)...', 'Tooltip', ...
                'Configure the selected step once more in its EEGLAB dialog; the search tries every configuration of the step', ...
                'ButtonPushedFcn', @(~, ~) obj.addCandidateConfig());
            uibutton(b3, 'Text', 'Skipping allowed on/off', 'Tooltip', ...
                'Whether leaving the selected step out is one of the searched options', ...
                'ButtonPushedFcn', @(~, ~) obj.toggleSkip());
            uibutton(b3, 'Text', 'Must come before...', 'Tooltip', ...
                'With order = search: the selected step must run before the step you choose', ...
                'ButtonPushedFcn', @(~, ~) obj.mustBefore());
            uibutton(b3, 'Text', 'Clear order rules', 'ButtonPushedFcn', @(~, ~) obj.clearOrderRules());
            uibutton(b3, 'Text', 'Parameters...', 'Tooltip', ...
                'Arguments of an EEGLAB-configured step and the values searched for each', ...
                'ButtonPushedFcn', @(~, ~) obj.paramsDialog());
            obj.ConstraintLabel = uilabel(pg, 'Text', 'Order rules: none', 'FontColor', [0.3 0.3 0.3]);

            % contract + run + results (right, row 3)
            rp = uipanel(g, 'Title', 'Analysis contract, constraints, search'); rp.Layout.Row = 3; rp.Layout.Column = 2;
            rg = uigridlayout(rp, [3 1]); rg.RowHeight = {196, 56, 64};
            % Each item: label | its text (the one source of the setting, also
            % editable by hand) | buttons that fill it from EEGLAB's dialogs.
            cg = uigridlayout(rg, [7 4]); cg.Padding = [0 0 0 0]; cg.RowSpacing = 3;
            cg.ColumnWidth = {80, '1x', 150, 95}; cg.RowHeight = repmat({24}, 1, 7);
            uilabel(cg, 'Text', 'Conditions');
            obj.CondField = uieditfield(cg, 'Placeholder', 'target: 11 21; standard: 31  (codes with spaces in "quotes")');
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
            uilabel(cg, 'Text', 'Epoch (s)'); obj.EpochField = uieditfield(cg, 'Value', '-0.2 1');
            uibutton(cg, 'Text', 'EEGLAB pop_epoch...', 'Tooltip', ...
                'Set the epoch in EEGLAB''s own epoching dialog (run on a copy); the window is filled in here', ...
                'ButtonPushedFcn', @(~, ~) obj.epochFromEEGLAB());
            uilabel(cg, 'Text', '');
            uilabel(cg, 'Text', 'Baseline (s)'); obj.BaseField = uieditfield(cg, 'Value', '-0.2 0');
            uibutton(cg, 'Text', 'EEGLAB pop_rmbase...', 'Tooltip', ...
                'Set the baseline in EEGLAB''s own baseline dialog on epoched preview data (ms are converted to s)', ...
                'ButtonPushedFcn', @(~, ~) obj.baselineFromEEGLAB());
            uilabel(cg, 'Text', '');
            uilabel(cg, 'Text', 'Components');
            obj.CompField = uieditfield(cg, 'Placeholder', 'P3: 0.3 0.6 @ Pz CPz POz; N2: 0.2 0.3 @ Fz FCz # peakLatency negative');
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
            d = neuroqc.eval.Rank.defaults();
            names = {'minTrials','minRetention','maxInterpolated','maxAmplitudeError','maxLatencyShiftMs', ...
                'maxArtifactPct','minWaveformCorr','minTopoCorr'};
            short = {'min trials','min retention','max interp','max amp err','max lat ms','max artifact','min wave r','min topo r'};
            for k = 1:numel(names)
                uilabel(lg, 'Text', short{k}, 'HorizontalAlignment', 'right');
                obj.LimitFields.(names{k}) = uieditfield(lg, 'numeric', 'Value', d.(names{k}));
            end
            uilabel(lg, 'Text', 'max pipelines', 'HorizontalAlignment', 'right');
            obj.LimitFields.maxLeaves = uieditfield(lg, 'numeric', 'Value', 500);
            ag = uigridlayout(rg, [2 6]); ag.Padding = [0 0 0 0]; ag.RowSpacing = 4;
            ag.ColumnWidth = {'fit', 170, 'fit', 'fit', 'fit', '1x'};
            uilabel(ag, 'Text', 'Objective', 'HorizontalAlignment', 'right');
            obj.ObjectiveField = uidropdown(ag, 'Items', {'composite', 'pareto'}, 'Value', 'composite', 'Editable', 'on', 'Tooltip', ...
                'composite | pareto | one objective; a priority list can be typed: P3.mean, N2.peakLatency');
            uibutton(ag, 'Text', 'Preview count', 'ButtonPushedFcn', @(~, ~) obj.run(true));
            uibutton(ag, 'Text', 'Run search', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run(false));
            uibutton(ag, 'Text', 'Options...', 'Tooltip', 'Data unit, checkpoint folder, sampled search, parallel, external QC table', ...
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
            obj.ResultTable = uitable(uigridlayout(resP, [1 1]), 'RowName', {}, 'ColumnName', ...
                {'id','status','objective','diff CI','not distinguished','P(best)','min ret','interp','amp err','art','pipeline / reason'}, ...
                'ColumnWidth', {35, 70, 65, 120, 45, 50, 55, 50, 55, 45, 'auto'});
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
            try
                [EEG, live] = neuroqc.live.Session.current();
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
            s = neuroqc.live.DataState.fromEEG(EEG);
            if s.isEpoched, shape = sprintf('%d epochs [%g %g] s', s.trials, s.xmin, s.xmax);
            else, shape = sprintf('continuous %.1f s', s.pnts / s.srate); end
            stored = ''; if ~live.stored, stored = '  (base EEG not stored in ALLEEG)'; end
            obj.DatasetLabel.Text = sprintf(['Set %s: %s%s\n%d ch | %g Hz | %s | %d events\n', ...
                'Reference: %s | ICA: %s\nFilters: %s'], mat2str(live.currentSet), s.setname, stored, ...
                s.nbchan, s.srate, shape, s.nEvents, s.reference, s.ica.summary, orDash(s.filters.text));
            if isempty(s.warnings), obj.WarnArea.Value = {'No inconsistencies between data and history.'};
            else, obj.WarnArea.Value = s.warnings(:); end
            h = s.history;
            obj.HistTable.Data = [num2cell([h.line]') {h.kind}' {h.step}' {h.statement}'];
            ev = arrayfun(@(k) sprintf('%s (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:numel(s.eventTypes), 'UniformOutput', false);
            obj.EventsLabel.Text = ['Event types: ' strjoin(ev, ', ')];
            obj.updateSummary();
            if ~force, neuroqc.utils.log('Current EEGLAB dataset changed: %s (%d history entries).', s.setname, numel(h)); end
            if ~isempty(obj.Result) && ~strcmp(fp, obj.Result.rootFingerprint)
                obj.StatusLabel.Text = sprintf(['Shown results were computed on "%s", not on the current dataset; ', ...
                    'Adopt rebuilds from that starting copy. Run again for the current one.'], obj.Result.state.setname);
            end
        end

        % ------------------------------------------------------------- plan
        function showPlan(obj)
            S = obj.Plan.Slots;
            data = cell(numel(S), 4);
            for k = 1:numel(S)
                data{k, 1} = k; data{k, 2} = S(k).id;
                data{k, 3} = settingsText(S(k)); data{k, 4} = S(k).pinned;
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
            neuroqc.utils.log('%s: previous results cleared (neuroqc_result in the base workspace is the old run).', why);
        end

        function addStep(obj)
            obj.Plan = obj.Plan.add(obj.TypeDrop.Value);
            obj.invalidate('Plan changed');
            obj.showPlan();
            d = neuroqc.plan.Catalog.get(obj.TypeDrop.Value);
            neuroqc.utils.log('Added %s. Unmentioned parameters are searched over their suggestions: %s', ...
                d.type, suggestText(d));
        end

        function k = selected(obj)
            k = [];
            sel = obj.PlanTable.Selection;
            if ~isempty(sel), k = sel(1, 1); end
            if isempty(k), uialert(obj.Fig, 'Select a plan row first.', 'NeuroQC'); end
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
            k = e.Indices(1);
            try
                if e.Indices(2) == 4
                    obj.Plan.Slots(k).pinned = logical(e.NewData);
                else
                    slot = obj.Plan.Slots(k);
                    assert(numel(slot.alternatives) == 1, 'NeuroQC:Plan', ['A step with several candidate configurations ', ...
                        'is edited through its EEGLAB dialog (Add EEGLAB config as candidate) or from the command line.']);
                    assert(~any(strcmp(slot.alternatives{1}.type, {'native','eeglab'})), 'NeuroQC:Plan', ...
                        ['An EEGLAB-configured step is edited in its dialog (Fix via EEGLAB dialog / Add EEGLAB config ', ...
                         'as candidate) or with Parameters...']);
                    p = parseSettings(e.NewData);
                    obj.Plan.Slots(k).alternatives{1}.params = p;
                end
                obj.invalidate('Plan changed');
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC'); obj.showPlan();
            end
        end

        function captureStep(obj, com)
            % Replace the selected step by its configuration in EEGLAB's
            % own dialog(s) (a fixed native step; re-editable).
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            id = slot.id; if ~endsWith(id, '_native'), id = [id '_native']; end
            try
                if nargin < 2
                    com = obj.captureFor(obj.dialogType(slot));
                    if isempty(com), return; end
                end
                obj.Plan.Slots(k).alternatives = {stepAlt(com)};
                obj.Plan.Slots(k).id = id;
                obj.invalidate('Plan changed');
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function addCandidateConfig(obj, com)
            % One more configuration of the selected step, from its EEGLAB
            % dialog; the search tries each configuration of the slot.
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            try
                if nargin < 2
                    com = obj.captureFor(obj.dialogType(slot));
                    if isempty(com), return; end
                end
                alt = stepAlt(com);
                alts = slot.alternatives;
                % the same EEGLAB call with other values: the arguments that
                % differ are searched one by one (combined with each other)
                j = find(cellfun(@(a) strcmp(a.type, 'eeglab'), alts) & strcmp(alt.type, 'eeglab'), 1);
                if isempty(j)
                    j = find(cellfun(@(a) strcmp(a.type, 'native') && ~isempty(neuroqc.run.Native.eeglabAlt(a.params.command)), alts), 1);
                    if ~isempty(j) && strcmp(alt.type, 'eeglab'), alts{j} = neuroqc.run.Native.eeglabAlt(alts{j}.params.command); end
                end
                merged = false;
                if ~isempty(j) && strcmp(alt.type, 'eeglab') && strcmp(alts{j}.type, 'eeglab')
                    [m, changed] = neuroqc.run.Native.mergeEeglab(alts{j}, alt);
                    if isequal({m.params.args.name}, {alt.params.args.name}) && strcmp(m.params.fn, alt.params.fn)
                        merged = true;
                        if isempty(changed), neuroqc.utils.log('This configuration is already a candidate of %s.', slot.id); return; end
                        alts{j} = m;
                        neuroqc.utils.log('%s: searched argument(s) %s now take %s.', slot.id, strjoin(changed, ', '), ...
                            strjoin(arrayfun(@(x) sprintf('%s %s', x.name, valuesText(x.values)), ...
                            m.params.args(ismember({m.params.args.name}, changed)), 'UniformOutput', false), '; '));
                    end
                end
                if ~merged
                    same = cellfun(@(a) isequal(a, alt), alts);
                    if any(same), neuroqc.utils.log('This configuration is already a candidate of %s.', slot.id); return; end
                    alts{end+1} = alt;
                    neuroqc.utils.log('%s now has %d candidate configuration(s).', slot.id, numel(alts));
                end
                obj.Plan.Slots(k).alternatives = alts;
                obj.invalidate('Plan changed');
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function editParams(obj, name, values)
            % Set the searched values of one argument of the selected
            % EEGLAB-configured step (values: cell, one entry per value).
            k = obj.selected(); if isempty(k), return; end
            alts = obj.Plan.Slots(k).alternatives;
            j = find(cellfun(@(a) strcmp(a.type, 'eeglab'), alts), 1);
            assert(~isempty(j), 'NeuroQC:Plan', 'The selected step is not configured in an EEGLAB dialog.');
            i = find(strcmp({alts{j}.params.args.name}, name), 1);
            assert(~isempty(i), 'NeuroQC:Plan', '%s has no argument %s.', alts{j}.params.fn, name);
            assert(iscell(values) && ~isempty(values), 'NeuroQC:Plan', 'Give at least one value.');
            alts{j}.params.args(i).values = values(:)';
            obj.Plan.Slots(k).alternatives = alts;
            obj.invalidate('Plan changed'); obj.showPlan();
        end

        function paramsDialog(obj)
            % Table of the step's arguments: values separated by " | ".
            k = obj.selected(); if isempty(k), return; end
            alts = obj.Plan.Slots(k).alternatives;
            j = find(cellfun(@(a) strcmp(a.type, 'eeglab'), alts), 1);
            if isempty(j)
                uialert(obj.Fig, ['Configure the step in its EEGLAB dialog first (Fix via EEGLAB dialog). Each ', ...
                    'further configuration (Add EEGLAB config as candidate) adds the values that differ.'], 'NeuroQC');
                return;
            end
            A = alts{j}.params.args;
            d = uifigure('Name', sprintf('%s: searched values', alts{j}.params.fn), 'Position', [200 200 620 360], ...
                'WindowStyle', 'modal');
            gl = uigridlayout(d, [3 1]); gl.RowHeight = {36, '1x', 30};
            uilabel(gl, 'WordWrap', 'on', 'Text', ['Each row is an argument of the EEGLAB command. One value = fixed; ', ...
                'several values separated by " | " = searched (combined with the other searched arguments).']);
            T = uitable(gl, 'Data', [{A.name}' arrayfun(@(x) strjoin(cellfun(@codeOf, x.values, 'UniformOutput', false), ' | '), A, ...
                'UniformOutput', false)'], 'ColumnName', {'argument', 'values'}, 'ColumnEditable', [false true], ...
                'ColumnWidth', {140, 'auto'}, 'RowName', {});
            bg = uigridlayout(gl, [1 3]); bg.Padding = [0 0 0 0]; bg.ColumnWidth = {'1x', 90, 90};
            uilabel(bg, 'Text', '');
            uibutton(bg, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) delete(d));
            uibutton(bg, 'Text', 'OK', 'ButtonPushedFcn', @(~, ~) apply());
            function apply()
                try
                    for r = 1:numel(A)
                        parts = strtrim(regexp(T.Data{r, 2}, '\s\|\s', 'split'));
                        parts = parts(~cellfun(@isempty, parts));
                        vals = cellfun(@(c) eval(c), parts, 'UniformOutput', false);
                        if ~isequal(vals, A(r).values), obj.editParams(A(r).name, vals); end
                    end
                    delete(d);
                catch ME
                    uialert(d, ME.message, 'NeuroQC');
                end
            end
        end

        function valuesFromDialog(obj, com, EEG)
            % Values of a catalog step from its EEGLAB dialog; a value that
            % differs from those already set is added to the step's search.
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            j = find(cellfun(@(a) ~any(strcmp(a.type, {'none','native','eeglab'})), slot.alternatives), 1);
            if isempty(j)
                uialert(obj.Fig, 'The selected step is already configured in EEGLAB; use Add EEGLAB config as candidate.', 'NeuroQC');
                return;
            end
            alt = slot.alternatives{j};
            try
                if nargin < 2
                    if any(strcmp(alt.type, {'reject_threshold','reject_jointprob','reject_kurtosis'}))
                        EEG = obj.previewEpoched();
                        com = neuroqc.run.Native.captureCall(EEG, neuroqc.run.Native.menuCall(alt.type));
                    elseif strcmp(alt.type, 'icremove')
                        EEG = neuroqc.live.Session.current();
                        com = neuroqc.run.Native.captureWorkflow('icremove', EEG);
                    else
                        assert(~any(strcmp(alt.type, {'epoch','baseline','restore'})), 'NeuroQC:Native', ...
                            '%s takes its settings from the analysis contract / the starting montage.', alt.type);
                        EEG = neuroqc.live.Session.current();
                        com = neuroqc.run.Native.capture(alt.type, EEG);
                    end
                    if isempty(com), return; end
                end
                [vals, notes] = neuroqc.run.Native.catalogValues(alt.type, com, EEG);
                d = neuroqc.plan.Catalog.get(alt.type);
                added = {};
                for f = fieldnames(vals)'
                    name = f{1}; v = vals.(name);
                    listValued = iscell(d.params(strcmp({d.params.name}, name)).default);
                    if ~isfield(alt.params, name), alt.params.(name) = v; added{end+1} = name; continue; end %#ok<AGROW>
                    cur = alt.params.(name);
                    if listValued
                        if iscell(cur) && ~isempty(cur) && all(cellfun(@iscell, cur)), L = cur; else, L = {cur}; end
                    else
                        if iscell(cur), L = cur; else, L = {cur}; end
                    end
                    if any(cellfun(@(x) isequal(x, v), L)), continue; end
                    L{end+1} = v; alt.params.(name) = L; added{end+1} = name; %#ok<AGROW>
                end
                obj.Plan.Slots(k).alternatives{j} = alt;
                msg = sprintf('%s from the EEGLAB dialog: %s', slot.id, strjoin(arrayfun(@(f) sprintf('%s = %s', f{1}, ...
                    valText(alt.params.(f{1}))), fieldnames(vals)', 'UniformOutput', false), '; '));
                neuroqc.utils.log('%s', msg);
                if ~isempty(notes)
                    neuroqc.utils.log('Not used by the %s step: %s.', alt.type, strjoin(notes, '; '));
                    if nargin < 2
                        uialert(obj.Fig, sprintf(['%s\n\nNot used by the %s step: %s.\n\nTo keep every setting of ', ...
                            'the dialog, use Fix via EEGLAB dialog instead.'], msg, alt.type, strjoin(notes, '; ')), 'NeuroQC', 'Icon', 'warning');
                    end
                end
                if ~isempty(added), obj.invalidate('Plan changed'); end
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function toggleSkip(obj)
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            has = any(cellfun(@(a) strcmp(a.type, 'none'), slot.alternatives));
            try
                obj.Plan = obj.Plan.setSkippable(slot.id, ~has);
                neuroqc.utils.log('%s: skipping %s.', slot.id, ternary(~has, 'is now searched as an option', 'is no longer an option'));
                obj.invalidate('Plan changed'); obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
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
                neuroqc.utils.log('Order rule %s before %s is used when Order = search.', me, other);
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
            assert(~isempty(alts), 'NeuroQC:Plan', 'The step has no configuration to edit.');
            type = alts{1}.type;
            if strcmp(type, 'eeglab')
                A = alts{1}.params.args;
                type = neuroqc.run.Native.typeOfCommand(neuroqc.run.Native.eeglabCommand(alts{1}.params.fn, A, ...
                    arrayfun(@(x) x.values{1}, A, 'UniformOutput', false)));
                assert(~isempty(type), 'NeuroQC:Native', 'No EEGLAB dialog is known for %s.', alts{1}.params.fn);
            elseif strcmp(type, 'native')
                type = neuroqc.run.Native.typeOfCommand(alts{1}.params.command);
                assert(~isempty(type), 'NeuroQC:Native', 'No EEGLAB dialog is known for this command; remove the step and add it again.');
            end
            ok = {'resample','highpass','lowpass','linenoise','filter','asr','badchannels','restore','reref','ica', ...
                'icremove','reject_threshold','reject_jointprob','reject_kurtosis'};
            assert(any(strcmp(type, ok)), 'NeuroQC:Native', ['%s has no EEGLAB dialog here (epoch and baseline come ', ...
                'from the analysis contract above; named channels from the settings column).'], type);
        end

        function com = captureFor(obj, type)
            switch type
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    com = neuroqc.run.Native.captureWorkflow(type, obj.previewEpoched());
                case 'icremove'
                    com = neuroqc.run.Native.captureWorkflow(type);
                otherwise
                    com = neuroqc.run.Native.capture(type);
            end
        end

        function EEG = previewEpoched(obj)
            % The current dataset, epoched on a copy with the contract
            % window when it is still continuous (for epoch-level dialogs).
            EEG = neuroqc.live.Session.current();
            assert(~isempty(EEG), 'NeuroQC:NoDataset', 'No dataset in EEGLAB.');
            if EEG.trials > 1, return; end
            c = obj.contract();
            codes = c.allEvents();
            assert(~isempty(codes), 'NeuroQC:Contract', 'Define the conditions first (the preview is epoched on their events).');
            [~, EEG] = evalc('pop_epoch(EEG, codes, c.effectiveEpoch(), ''epochinfo'', ''yes'')');
            if ~isempty(c.effectiveBaseline())
                [~, EEG] = evalc('pop_rmbase(EEG, 1000 * c.effectiveBaseline(), [])');
            end
            neuroqc.utils.log('Dialog on a preview copy epoched [%g %g] s on %s.', c.effectiveEpoch(), strjoin(codes, ', '));
        end

        function applyNow(obj)
            k = obj.selected(); if isempty(k), return; end
            alt = obj.Plan.Slots(k).alternatives{1};
            try
                before = neuroqc.live.Session.fingerprint(neuroqc.live.Session.current());
                if strcmp(alt.type, 'native')
                    neuroqc.run.Native.applyCommand(alt.params.command);   % the fixed command, no dialog
                elseif strcmp(alt.type, 'eeglab')
                    A = alt.params.args;
                    if numel(obj.Plan.Slots(k).alternatives) == 1 && all(cellfun(@numel, {A.values}) == 1)
                        neuroqc.run.Native.applyCommand(neuroqc.run.Native.eeglabCommand(alt.params.fn, A, ...
                            arrayfun(@(x) x.values{1}, A, 'UniformOutput', false)));
                    else   % several configurations: choose one in the dialog itself
                        neuroqc.run.Native.applyNow(obj.dialogType(obj.Plan.Slots(k)));
                    end
                else
                    neuroqc.run.Native.applyNow(alt.type);
                end
                obj.refreshLive(false);
                if strcmp(before, neuroqc.live.Session.fingerprint(neuroqc.live.Session.current()))
                    neuroqc.utils.log('Dialog cancelled or no change; the dataset is unchanged.');
                    return;
                end
                choice = uiconfirm(obj.Fig, 'Remove this step from the plan now that it is applied?', 'NeuroQC', ...
                    'Options', {'Remove from plan', 'Keep'});
                if strcmp(choice, 'Remove from plan'), obj.removeStep(); end
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function catalogHelp(~)
            for t = neuroqc.plan.Catalog.types()
                d = neuroqc.plan.Catalog.get(t{1});
                fprintf('%-18s %s\n', d.type, d.label);
                for p = d.params
                    fprintf('    %-12s default %-10s search %-22s %s\n', p.name, valText(p.default), valText(p.suggest), p.doc);
                end
            end
        end

        % -------------------------------------------------------------- run
        function c = contract(obj)
            c = neuroqc.eval.Contract('conditions', parseConditions(obj.CondField.Value), ...
                'components', parseComponents(obj.CompField.Value), ...
                'epoch', str2num(obj.EpochField.Value), 'baseline', str2num(obj.BaseField.Value), ... %#ok<ST2NM>
                'trials', obj.TrialRule);
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
            obj.ObjectiveField.Items = [{'composite', 'pareto'} names(:)'];
            obj.ObjectiveField.Value = v;
        end

        function optionsDialog(obj)
            o = obj.Options;
            d = uifigure('Name', 'NeuroQC search options', 'Position', [240 240 520 300], 'WindowStyle', 'modal');
            gl = uigridlayout(d, [7 3]); gl.ColumnWidth = {170, '1x', 110}; gl.RowHeight = repmat({26}, 1, 7);
            uilabel(gl, 'Text', 'Data unit of the dataset');
            du = uidropdown(gl, 'Items', {'uV', 'V'}, 'Value', o.dataUnit, 'Tooltip', 'V: scaled to uV on NeuroQC''s copy (ICA weights too)');
            uilabel(gl, 'Text', '');
            uilabel(gl, 'Text', 'Checkpoint folder');
            ck = uilabel(gl, 'Text', orDash(o.checkpoint));
            uibutton(gl, 'Text', 'Choose...', 'ButtonPushedFcn', @(~, ~) pickDir());
            uilabel(gl, 'Text', 'Search');
            sm = uidropdown(gl, 'Items', {'exhaustive', 'sample'}, 'Value', o.searchMode);
            ss = uispinner(gl, 'Limits', [1 1e5], 'Value', o.sampleSize, 'Tooltip', 'pipelines drawn when sampling');
            uilabel(gl, 'Text', 'Parallel (Parallel Computing Toolbox)');
            pa = uicheckbox(gl, 'Text', '', 'Value', o.parallel);
            uilabel(gl, 'Text', '');
            uilabel(gl, 'Text', 'External QC table (key column)');
            qc = uilabel(gl, 'Text', orDash(qcText(o.externalQC)));
            uibutton(gl, 'Text', 'Import...', 'ButtonPushedFcn', @(~, ~) pickQc());
            uilabel(gl, 'Text', ''); uilabel(gl, 'Text', ''); uilabel(gl, 'Text', '');
            uilabel(gl, 'Text', '');
            uibutton(gl, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) delete(d));
            uibutton(gl, 'Text', 'OK', 'ButtonPushedFcn', @(~, ~) apply());
            function pickDir()
                p = uigetdir(pwd, 'Checkpoint folder (empty or of this same search)');
                if ischar(p), o.checkpoint = p; ck.Text = p; end
            end
            function pickQc()
                [f, p] = uigetfile({'*.csv;*.txt;*.xlsx', 'QC table'}, 'External QC table');
                if ischar(f), o.externalQC = fullfile(p, f); qc.Text = o.externalQC; end
            end
            function apply()
                o.dataUnit = du.Value; o.searchMode = sm.Value; o.sampleSize = ss.Value; o.parallel = pa.Value;
                obj.setOptions(o); delete(d);
            end
        end

        function setOptions(obj, o)
            obj.Options = o;
            neuroqc.utils.log('Search options: unit %s, %s search%s, checkpoint %s, parallel %d, external QC %s', o.dataUnit, ...
                o.searchMode, ternary(strcmp(o.searchMode, 'sample'), sprintf(' (%d)', o.sampleSize), ''), orDash(o.checkpoint), ...
                o.parallel, orDash(qcText(o.externalQC)));
            obj.invalidate('Options changed');
        end

        function resume(obj, folder)
            if nargin < 2
                folder = uigetdir(pwd, 'Checkpoint folder of the interrupted search');
                if ~ischar(folder), return; end
            end
            try
                stop(obj.Timer); cleanup = onCleanup(@() start(obj.Timer)); %#ok<NASGU>
                obj.StatusLabel.Text = 'Resuming... progress in the Command Window'; drawnow;
                r = neuroqc.NeuroQC.resume(folder);
                obj.Result = r; assignin('base', 'neuroqc_result', r);
                obj.showResults();
                obj.StatusLabel.Text = 'Resumed search done. Result in variable neuroqc_result.';
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function editChanlocs(obj)
            try
                neuroqc.run.Native.applyNow('chanlocs');
                obj.refreshLive(false);
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function viewErp(obj)
            % EEGLAB's ERP + scalp map viewer on epoched preview data
            try
                EEG = obj.previewEpoched();
                EEG.setname = sprintf('%s (NeuroQC preview, all conditions)', EEG.setname);
                pop_timtopo(EEG);
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
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
                    E = r.root; E.setname = sprintf('%s (NeuroQC source, start of the search)', r.state.setname);
                else
                    [~, E] = evalc('neuroqc.run.Executor.replay(r, which)');
                    E.setname = sprintf('NeuroQC candidate %d (not adopted): %s', which, r.labels{which});
                end
                if E.trials == 1 && view > 1
                    codes = r.contract.allEvents();
                    [~, E] = evalc('pop_epoch(E, codes, r.contract.effectiveEpoch())');
                end
                switch view
                    case 1, pop_eegplot(E, 1, 1, 0);
                    case 2, pop_timtopo(E);
                    case 3, pop_plottopo(E);
                    case 4
                        assert(~isempty(E.icaweights), 'NeuroQC:Inspect', 'This dataset has no ICA decomposition.');
                        pop_selectcomps(E, 1:min(35, size(E.icaweights, 1)));
                end
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function addCondition(obj, name, codes)
            % Name a condition and pick its codes from the current events
            % (EEGLAB's pop_chansel list, as in pop_epoch's event button).
            if nargin < 3
                EEG = neuroqc.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'NeuroQC'); return; end
                s = neuroqc.live.DataState.fromEEG(EEG);
                if isempty(s.eventTypes), uialert(obj.Fig, 'The dataset has no events.', 'NeuroQC'); return; end
                items = arrayfun(@(k) sprintf('%s  (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:numel(s.eventTypes), 'UniformOutput', false);
                idx = pop_chansel(items, 'withindex', 'off');
                if isempty(idx), return; end
                codes = s.eventTypes(idx);
                a = inputdlg(sprintf('Name of the condition with events %s:', strjoin(codes, ', ')), ...
                    'NeuroQC condition', 1, {sprintf('cond%d', size(parseConditions(obj.CondField.Value), 1) + 1)});
                if isempty(a) || isempty(strtrim(a{1})), return; end
                name = strtrim(a{1});
            end
            conds = parseConditions(obj.CondField.Value);
            assert(~any(strcmpi(conds(:, 1), name)), 'NeuroQC:Contract', 'A condition named %s exists already.', name);
            used = intersect(cellstr(codes), [conds{:, 2}]);
            if ~isempty(used)
                uialert(obj.Fig, sprintf('Event code(s) %s already belong to another condition.', strjoin(used, ', ')), 'NeuroQC');
                return;
            end
            conds(end+1, :) = {name, cellstr(codes)};
            obj.setField(obj.CondField, conditionsText(conds));
            neuroqc.utils.log('Condition %s = events %s', name, strjoin(cellstr(codes), ', '));
        end

        function epochFromEEGLAB(obj, com)
            % EEGLAB's epoching dialog on a copy; its window is the epoch.
            if nargin < 2
                EEG = neuroqc.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'NeuroQC'); return; end
                if EEG.trials > 1
                    uialert(obj.Fig, 'The dataset is already epoched; the epoch is fixed by the data.', 'NeuroQC'); return;
                end
                com = neuroqc.run.Native.captureCall(EEG, '[EEG, ~, LASTCOM] = pop_epoch(EEG);');
                if isempty(com), return; end
            end
            a = neuroqc.run.Native.argsOf(com, 'pop_epoch');
            assert(numel(a) >= 2 && isnumeric(a{2}) && numel(a{2}) == 2, 'NeuroQC:Native', 'No epoch limits in %s', com);
            obj.EpochField.Value = num2str(a{2});
            types = a{1}; if ~iscell(types), types = {types}; end
            types = cellfun(@(x) strtrim(char(string(x))), types, 'UniformOutput', false);
            conds = parseConditions(obj.CondField.Value);
            if isempty(conds) && ~isempty(types)
                conds = [types(:) cellfun(@(t) {t}, types(:), 'UniformOutput', false)];
                obj.CondField.Value = conditionsText(conds);
                neuroqc.utils.log('Conditions set from the epoching events (one per code): %s', strjoin(types, ', '));
            elseif ~isempty(setxor(types, [conds{:, 2}])) && ~isempty(types)
                neuroqc.utils.log(['Note: NeuroQC epochs on the condition events (%s); the events chosen in the dialog ', ...
                    '(%s) are not used. Edit the conditions to change them.'], strjoin([conds{:, 2}], ', '), strjoin(types, ', '));
            end
            extra = a(3:end);
            keys = extra(1:2:end); keys = keys(cellfun(@ischar, keys));
            ignored = setdiff(keys, {'epochinfo','newname'});
            if ~isempty(ignored)
                neuroqc.utils.log('Note: pop_epoch option(s) %s are not part of the NeuroQC epoch step and are not used.', strjoin(ignored, ', '));
            end
            obj.settingsChanged();
            neuroqc.utils.log('Epoch from EEGLAB: [%s] s', obj.EpochField.Value);
        end

        function baselineFromEEGLAB(obj, com)
            % EEGLAB's baseline dialog on epoched preview data (the dataset
            % itself, or a copy epoched with the planned window).
            if nargin < 2
                EEG = neuroqc.live.Session.current();
                if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'NeuroQC'); return; end
                if EEG.trials == 1
                    c = obj.contract();
                    codes = c.allEvents();
                    assert(~isempty(codes), 'NeuroQC:Contract', 'Define the conditions first (the preview is epoched on their events).');
                    [~, EEG] = evalc('pop_epoch(EEG, codes, c.effectiveEpoch(), ''epochinfo'', ''yes'')');   % no baseline removed yet
                    neuroqc.utils.log('Baseline dialog on a preview copy epoched [%g %g] s on %s.', c.effectiveEpoch(), strjoin(codes, ', '));
                end
                com = neuroqc.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_rmbase(EEG);');
                if isempty(com), return; end
            else
                EEG = [];
            end
            a = neuroqc.run.Native.argsOf(com, 'pop_rmbase');
            ms = []; if ~isempty(a), ms = a{1}; end
            if isempty(ms) && numel(a) >= 2 && ~isempty(a{2}) && ~isempty(EEG)
                ms = EEG.times(a{2}([1 end]));                   % given as points
            end
            assert(numel(ms) == 2, 'NeuroQC:Native', 'No baseline range in %s', com);
            obj.BaseField.Value = num2str(ms / 1000);
            if numel(a) >= 3 && ~isempty(a{3})
                neuroqc.utils.log('Note: the baseline dialog selected channels; NeuroQC removes the baseline on all channels.');
            end
            obj.settingsChanged();
            neuroqc.utils.log('Baseline from EEGLAB: [%g %g] ms -> [%s] s', ms, obj.BaseField.Value);
        end

        function addComponent(obj, name, win, roi, measure, polarity)
            if nargin < 2
                a = inputdlg({'Component name', 'Window start (s)', 'Window end (s)'}, 'NeuroQC component', 1, ...
                    {'P3', '0.3', '0.6'});
                if isempty(a), return; end
                name = strtrim(a{1}); win = [str2double(a{2}) str2double(a{3})];
                assert(~isempty(name) && all(isfinite(win)) && win(2) > win(1), 'NeuroQC:Contract', ...
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
            comps = parseComponents(obj.CompField.Value);
            comps(end+1, :) = {name, win, cellstr(roi), {measure, polarity}};
            obj.setField(obj.CompField, componentsText(comps));
        end

        function setRoi(obj, k, roi)
            comps = parseComponents(obj.CompField.Value);
            if isempty(comps), uialert(obj.Fig, 'Add a component first.', 'NeuroQC'); return; end
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
            obj.setField(obj.CompField, componentsText(comps));
        end

        function labels = pickChannels(obj, current)
            % EEGLAB's channel selection over the current dataset's channels.
            labels = {};
            EEG = neuroqc.live.Session.current();
            if isempty(EEG), uialert(obj.Fig, 'No dataset in EEGLAB.', 'NeuroQC'); return; end
            args = {'withindex', 'on'};
            if nargin > 1 && ~isempty(current)
                [~, sel] = ismember(lower(current), lower({EEG.chanlocs.labels}));
                args = [args {'select', sel(sel > 0)}];
            end
            [idx, ~, names] = pop_chansel({EEG.chanlocs.labels}, args{:});
            if ~isempty(idx), labels = {EEG.chanlocs(idx).labels}; elseif iscell(names), labels = names; end
            if ~isempty(labels), neuroqc.utils.log('ROI: %s (%d channels)', strjoin(labels, ' '), numel(labels)); end
        end

        function chooseTrials(obj)
            opts = {'All trials', 'Between a start and an end marker', 'Time ranges (s)', ...
                'EEGLAB event selection (pop_selectevent)'};
            [k, ok] = listdlg('ListString', opts, 'SelectionMode', 'single', 'Name', 'Trials', 'ListSize', [300 90]);
            if ~ok, return; end
            EEG = neuroqc.live.Session.current();
            if isempty(EEG) && k > 1, uialert(obj.Fig, 'No dataset in EEGLAB.', 'NeuroQC'); return; end
            switch k
                case 1
                    obj.setTrialRule(struct('mode', 'all'));
                case 2
                    s = neuroqc.live.DataState.fromEEG(EEG);
                    a = pop_chansel(s.eventTypes, 'selectionmode', 'single', 'withindex', 'off');
                    if isempty(a), return; end
                    b = pop_chansel(s.eventTypes, 'selectionmode', 'single', 'withindex', 'off');
                    if isempty(b), return; end
                    obj.setTrialRule(struct('mode', 'marker_ranges', 'startCode', s.eventTypes{a}, 'endCode', s.eventTypes{b}));
                case 3
                    a = inputdlg('Time ranges in s, one per row as "start end" (Inf = end of recording):', ...
                        'Trials', [4 50], {'0 Inf'});
                    if isempty(a), return; end
                    r = str2num(a{1}); %#ok<ST2NM>
                    assert(size(r, 2) == 2 && all(r(:, 2) > r(:, 1)), 'NeuroQC:Contract', 'Each row: start end, with end > start.');
                    obj.setTrialRule(struct('mode', 'time_ranges', 'ranges', r));
                case 4
                    if ~isfield(EEG, 'urevent') || isempty(EEG.urevent), [~, EEG] = evalc('eeg_checkset(EEG, ''makeur'')'); end
                    [com, sel] = neuroqc.run.Native.captureCall(EEG, '[EEG, ~, LASTCOM] = pop_selectevent(EEG);');
                    if isempty(com), return; end
                    obj.trialRuleFromSelection(sel, com);
            end
        end

        function trialRuleFromSelection(obj, sel, com)
            % The trials are the condition events that the EEGLAB event
            % selection kept (identified by urevent).
            c = obj.contract();
            codes = c.allEvents();
            assert(~isempty(codes), 'NeuroQC:Contract', 'Define the conditions first.');
            ty = arrayfun(@(e) strtrim(char(string(e.type))), sel.event, 'UniformOutput', false);
            keep = ismember(ty, codes) & arrayfun(@(e) isfield(e, 'urevent') && ~isempty(e.urevent), sel.event);
            ids = unique(arrayfun(@(e) double(e.urevent), sel.event(keep)));
            assert(~isempty(ids), 'NeuroQC:TrialRule', 'The event selection keeps no condition event.');
            obj.setTrialRule(struct('mode', 'urevents', 'ids', ids(:)', 'source', com));
        end

        function setTrialRule(obj, rule)
            c = neuroqc.eval.Contract('trials', rule); c.validateTrialRule();
            obj.TrialRule = rule;
            obj.TrialLabel.Text = trialText(rule);
            neuroqc.utils.log('Trial rule: %s', obj.TrialLabel.Text);
            obj.settingsChanged();
        end

        function updateSummary(obj)
            % Trials per condition in the current dataset, under the rule.
            if isempty(obj.SummaryLabel) || ~isvalid(obj.SummaryLabel), return; end
            try
                EEG = neuroqc.live.Session.current();
                c = obj.contract();
                if isempty(EEG) || isempty(c.conditions), obj.SummaryLabel.Text = ''; return; end
                [elig, E] = neuroqc.run.Executor.eligibleUrevents(EEG, c);
                parts = cell(1, numel(c.conditions));
                for k = 1:numel(c.conditions)
                    if E.trials == 1
                        ty = arrayfun(@(e) strtrim(char(string(e.type))), E.event, 'UniformOutput', false);
                        isC = ismember(ty, c.conditions(k).events);
                        n = sum(isC);
                        ne = n; if ~isempty(elig), ne = sum(ismember(arrayfun(@(e) double(e.urevent), E.event(isC)), elig)); end
                    else
                        if ~isempty(elig), E.etc.neuroqc.eligibleUrevents = elig; end
                        T = neuroqc.eval.Measure.trials(E, c);
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
                if any(strcmp(ob, {'composite','pareto'})), opts.objective = ob;
                else, opts.objective = strtrim(strsplit(ob, ',')); end
                for f = fieldnames(obj.LimitFields)'
                    opts.(f{1}) = obj.LimitFields.(f{1}).Value;
                end
                for f = fieldnames(obj.Options)'
                    if ~isempty(obj.Options.(f{1})) || islogical(obj.Options.(f{1})), opts.(f{1}) = obj.Options.(f{1}); end
                end
                obj.StatusLabel.Text = 'Running... progress in the Command Window'; drawnow;
                stop(obj.Timer);
                cleanup = onCleanup(@() start(obj.Timer));
                r = neuroqc.NeuroQC.optimize(obj.Plan, c, opts);
                if dry
                    obj.StatusLabel.Text = sprintf('%d pipelines, %d step runs (shared prefixes)', r.report.nLeaves, r.report.nNodes);
                    return;
                end
                obj.Result = r;
                assignin('base', 'neuroqc_result', r);
                obj.showResults();
                obj.StatusLabel.Text = 'Done. Result in variable neuroqc_result.';
                neuroqc.utils.log('Result stored in the base variable neuroqc_result.');
            catch ME
                obj.StatusLabel.Text = 'Error (see dialog)';
                neuroqc.utils.log('ERROR: %s', ME.message);
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function showResults(obj)
            r = obj.Result; T = r.ranking.table; data = {};
            recs = [r.ranking.byStratum.recommended];
            for k = r.ranking.order(:)'
                ci = ''; if isfinite(T.diffLo(k)), ci = sprintf('[%+.3f %+.3f]', T.diffLo(k), T.diffHi(k)); end
                id = sprintf('%d', k); if any(recs == k), id = [id '*']; end
                txt = r.labels{k}; if ~isempty(T.reason{k}), txt = [T.reason{k} ' | ' txt]; end
                if ~isempty(T.stratum{k}), txt = ['[' T.stratum{k} '] ' txt]; end
                data(end+1, :) = {id, T.status{k}, T.objective(k), ci, T.notDistinguished(k), T.probBest(k), ...
                    T.minRetention(k), T.interpolated(k), T.ampError(k), T.artifactPct(k), txt}; %#ok<AGROW>
            end
            obj.ResultTable.Data = data;
        end

        function k = selectedResult(obj)
            k = [];
            if isempty(obj.Result), uialert(obj.Fig, 'Run a search first.', 'NeuroQC'); return; end
            sel = obj.ResultTable.Selection;
            if isempty(sel), k = obj.Result.ranking.recommended; return; end
            k = str2double(strrep(obj.ResultTable.Data{sel(1, 1), 1}, '*', ''));
        end

        function adopt(obj)
            k = obj.selectedResult(); if isempty(k), return; end
            stop(obj.Timer); cleanup = onCleanup(@() start(obj.Timer)); %#ok<NASGU>
            try
                neuroqc.NeuroQC.adopt(obj.Result, k);
            catch ME
                if ~any(strcmp(ME.identifier, {'NeuroQC:Adopt','NeuroQC:ReplayMismatch','NeuroQC:StaleState'}))
                    uialert(obj.Fig, ME.message, 'NeuroQC'); return;
                end
                choice = uiconfirm(obj.Fig, ME.message, 'NeuroQC: adopt anyway?', ...
                    'Options', {'Adopt anyway', 'Cancel'}, 'DefaultOption', 2, 'CancelOption', 2, 'Icon', 'warning');
                if strcmp(choice, 'Adopt anyway'), neuroqc.NeuroQC.adopt(obj.Result, k, true); end
            end
        end

        function printScript(obj)
            k = obj.selectedResult(); if isempty(k), return; end
            neuroqc.utils.log('EEGLAB commands of candidate %d:', k);
            neuroqc.NeuroQC.script(obj.Result, k);
        end
    end
end

function tok = tokens(s)
% whitespace-separated items; "quoted" items may contain spaces
tok = regexp(strtrim(char(s)), '"[^"]*"|\S+', 'match');
tok = regexprep(tok, '^"(.*)"$', '$1');
end

function t = quoteItem(x)
x = char(x);
if any(isspace(x)) || isempty(x), t = ['"' x '"']; else, t = x; end
end

function conds = parseConditions(txt)
% 'target: 11 21; standard: 31' -> {'target', {'11','21'}; 'standard', {'31'}}
conds = cell(0, 2);
for part = strsplit(strtrim(char(txt)), ';')
    p = strtrim(part{1}); if isempty(p), continue; end
    k = strfind(p, ':');
    assert(~isempty(k), 'NeuroQC:Contract', 'Conditions: name: ev1 ev2; name2: ev3');
    ev = tokens(p(k(1)+1:end));
    assert(~isempty(ev), 'NeuroQC:Contract', 'Condition %s has no event code.', strtrim(p(1:k(1)-1)));
    conds(end+1, :) = {strtrim(p(1:k(1)-1)), ev}; %#ok<AGROW>
end
end

function t = conditionsText(conds)
parts = cell(1, size(conds, 1));
for k = 1:size(conds, 1)
    parts{k} = sprintf('%s: %s', conds{k, 1}, strjoin(cellfun(@quoteItem, conds{k, 2}, 'UniformOutput', false), ' '));
end
t = strjoin(parts, '; ');
end

function comps = parseComponents(txt)
% 'P3: 0.3 0.6 @ Pz CPz # peakLatency negative' -> rows {name, win, roi, measure}
comps = cell(0, 4);
for part = strsplit(strtrim(char(txt)), ';')
    p = strtrim(part{1}); if isempty(p), continue; end
    tok = regexp(p, '^([^:]+):\s*([-\d\.eE]+)\s+([-\d\.eE]+)\s*@\s*([^#]+)(.*)$', 'tokens', 'once');
    assert(~isempty(tok), 'NeuroQC:Contract', 'Components: name: start end @ ch1 ch2 [# measure polarity]; ...');
    meas = strsplit(strtrim(strrep(tok{5}, '#', '')));
    meas = meas(~cellfun(@isempty, meas)); if isempty(meas), meas = {'mean'}; end
    comps(end+1, :) = {strtrim(tok{1}), [str2double(tok{2}) str2double(tok{3})], tokens(tok{4}), meas}; %#ok<AGROW>
end
end

function t = componentsText(comps)
parts = cell(1, size(comps, 1));
for k = 1:size(comps, 1)
    m = cellstr(comps{k, 4});
    tail = '';
    if ~(isscalar(m) && strcmp(m{1}, 'mean')) && ~(numel(m) == 2 && strcmp(m{1}, 'mean'))
        tail = [' # ' strjoin(m, ' ')];
    end
    parts{k} = sprintf('%s: %g %g @ %s%s', comps{k, 1}, comps{k, 2}, ...
        strjoin(cellfun(@quoteItem, comps{k, 3}, 'UniformOutput', false), ' '), tail);
end
t = strjoin(parts, '; ');
end

function t = trialText(r)
switch r.mode
    case 'all', t = 'all trials';
    case 'marker_ranges', t = sprintf('between markers %s and %s', char(string(r.startCode)), char(string(r.endCode)));
    case 'time_ranges', t = sprintf('time ranges %s s', mat2str(r.ranges));
    case 'urevents'
        t = sprintf('%d selected events', numel(r.ids));
        if isfield(r, 'source'), t = [t ' (' r.source ')']; end
    otherwise, t = r.mode;
end
end

function t = qcText(q)
if isempty(q), t = ''; elseif ischar(q) || isstring(q), t = char(q); else, t = sprintf('table (%d rows)', height(q)); end
end

function t = orDash(t)
if isempty(t), t = '-'; end
end

function t = settingsText(slot)
parts = {};
for a = 1:numel(slot.alternatives)
    alt = slot.alternatives{a};
    if strcmp(alt.type, 'none'), parts{end+1} = 'none (skip)'; continue; end %#ok<AGROW>
    if strcmp(alt.type, 'native')
        parts{end+1} = ['EEGLAB: ' strjoin(neuroqc.run.Native.statements(alt.params.command), ' / ')]; %#ok<AGROW>
        continue;
    end
    if strcmp(alt.type, 'eeglab')
        A = alt.params.args;
        kv = arrayfun(@(x) sprintf('%s = %s', x.name, valuesText(x.values)), A, 'UniformOutput', false);
        nComb = prod(cellfun(@numel, {A.values}));
        tail = ''; if nComb > 1, tail = sprintf('  [%d combinations]', nComb); end
        parts{end+1} = sprintf('EEGLAB %s: %s%s', alt.params.fn, strjoin(kv, '; '), tail); %#ok<AGROW>
        continue;
    end
    f = fieldnames(alt.params);
    kv = cellfun(@(n) sprintf('%s = %s', n, valText(alt.params.(n))), f, 'UniformOutput', false);
    if numel(slot.alternatives) > 1, parts{end+1} = sprintf('%s(%s)', alt.type, strjoin(kv, '; ')); %#ok<AGROW>
    else, parts{end+1} = strjoin(kv, '; '); end %#ok<AGROW>
end
t = strjoin(parts, ' | ');
end

function alt = stepAlt(com)
% A captured dialog command as a plan alternative: a single EEGLAB call
% becomes parameterised (its arguments can be searched), a workflow stays
% a fixed native step.
alt = neuroqc.run.Native.eeglabAlt(com);
if isempty(alt), alt = neuroqc.plan.Plan.nativeAlt(com); end
end

function t = valuesText(vals)
% one value as code; several as {v1 | v2 | ...} (the searched list)
c = cellfun(@codeOf, vals, 'UniformOutput', false);
if isscalar(c), t = c{1}; else, t = ['{' strjoin(c, ' | ') '}']; end
end

function t = codeOf(v)
alt = neuroqc.run.Native.eeglabCommand('f', struct('name', 'x', 'key', false, 'values', {{v}}), {v});
t = regexprep(alt, '^EEG = f\(EEG, (.*)\);$', '$1');
end

function p = parseSettings(txt)
% 'cutoff = {0.1, 0.5}; measure = ''kurt''' -> struct. Values are MATLAB
% expressions typed by the user in their own session.
p = struct();
txt = strtrim(char(txt));
if isempty(txt), return; end
for part = regexp(txt, ';(?=(?:[^'']*''[^'']*'')*[^'']*$)', 'split')
    s = strtrim(part{1}); if isempty(s), continue; end
    kv = regexp(s, '^\s*([A-Za-z]\w*)\s*=\s*(.+)$', 'tokens', 'once');
    assert(~isempty(kv), 'NeuroQC:Plan', 'Write settings as name = value; name2 = {v1, v2}');
    p.(kv{1}) = eval(kv{2});
end
end

function t = valText(v)
if ischar(v) || isstring(v), t = ['''' char(v) ''''];
elseif isnumeric(v) || islogical(v), t = mat2str(v);
elseif iscell(v), t = ['{' strjoin(cellfun(@valText, v, 'UniformOutput', false), ', ') '}'];
else, t = class(v);
end
end

function t = suggestText(d)
parts = {};
for p = d.params
    if ~isempty(p.suggest), parts{end+1} = sprintf('%s %s', p.name, valText(p.suggest)); end %#ok<AGROW>
end
if isempty(parts), t = 'none (all parameters fixed by default)'; else, t = strjoin(parts, ', '); end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
