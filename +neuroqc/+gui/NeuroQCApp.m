classdef NeuroQCApp < handle
    % NeuroQCApp - 4-step EEGLAB wizard: auto-load current set, pick steps,
    % edit params via EEGLAB pop_* dialogs, enumerate discrete combos only.
    % Signal processing and parameter UI delegate to EEGLAB; NeuroQC owns
    % exhaustive combination + ranking.

    properties
        Figure
        Contract
        Space
        LockSpec
        GoalProfile
        Results
        SourceEEG
        statusLabel
        summaryLabel
        srcEdit
        epochField
        baseField
        compField
        spaceTable
        comboLabel
        goalDD
        wField
        unitDD
        outField
        qcField
        trialMode
        GeneratedOptions
        selectedStepsField
        stepsList
        paramListLabel
        searchOrderCheck
        stepOrderField
        fixedPosField
        maxOrdersField
        useParallelCheck
        adoptCkptBtn
        stageDD
        handoffDD
        completedField
        ExtraOptions
        runBtn
        compareBtn
        compareAllBtn
        rerankBtn
        retryBtn
        gateLabel
        gateLabel4
        resultTable
        logArea
        logPanel
        logToggle
        mainGrid
        condField
        constraintFields = struct()
        constraintSummary
        tabGroup
        paramStepList
        paramTitle
        paramPreview
        scopeGrid
        scopeSourceLabel
        paramSourceLabel
        spaceDlg
        spaceDlgTable
        spaceDlgInfo
        lastCurrentSet
        sourceFromFile
        workflowList
        coverageLabel
        workflowHint
        GenerationState = []
        InputSettingsVerified = true
    end

    methods
        function obj = NeuroQCApp(varargin)
            obj.Contract = [];
            obj.Space = neuroqc.pipeline.SearchSpace.defaultERP();
            obj.Space.resample={250}; obj.Space.highpass={0.1,0.5}; obj.Space.lowpass={30};
            obj.Space.reference={'average'}; obj.Space.interpolate={true}; obj.Space.ica={true};
            obj.Space.fullWorkflow={true}; obj.Space.icPolicy={'conservative','moderate'};
            obj.Space.artifactThresholdUv={100,120}; obj.ExtraOptions=struct();
            obj.LockSpec = struct();
            obj.GoalProfile = neuroqc.optimize.GoalProfile.balanced();
            obj.Results = [];
            obj.SourceEEG = [];
            obj.lastCurrentSet = NaN;
            obj.sourceFromFile = false;
            if nargin >= 1 && ~isempty(varargin{1})
                obj.SourceEEG = varargin{1};
            end
            if nargout == 0
                obj.launch();
            end
        end

        function launch(obj,visible)
            if nargin<2, visible='on'; end
            ver = neuroqc.NeuroQC.version();
            % EEGLAB colors: BACKCOLOR panels, navy Courier text (icadefs)
            obj.Figure = uifigure('Name', sprintf('NeuroQC v%s', ver), ...
                'Visible',visible,'Position', [40 40 1400 900], 'Color', [0.93 0.96 1]);
            grid = uigridlayout(obj.Figure, [3 3]);
            obj.mainGrid = grid;
            grid.RowHeight = {40, '1x', 0};   % row3 = collapsible log (0 = hidden)
            grid.ColumnWidth = {'1x', '1.2x', '1.2x'};
            grid.Padding = [8 8 8 8];
            grid.ColumnSpacing = 10;
            grid.RowSpacing = 6;

            % Row 1: header (EEGLAB main-window style: short title + status)
            hdr = uigridlayout(grid, [1 6]);
            hdr.Layout.Row = 1; hdr.Layout.Column = [1 3];
            hdr.ColumnWidth = {190, '1x', 90, 90, 60, 60};
            hdr.Padding = [0 0 0 0];
            uilabel(hdr, 'Text', sprintf('NeuroQC v%s', ver), ...
                'FontSize', 16, 'FontWeight', 'bold', 'HorizontalAlignment', 'left', ...
                'FontName', 'Courier', 'FontColor', [0 0 0.4]);
            obj.statusLabel = uilabel(hdr, 'Text', 'Loading current EEGLAB set...', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4], 'FontName', 'Courier');
            uibutton(hdr,'Text','Save session', ...
                'Tooltip','Full session: config + results + input snapshot (restore with Open session)', ...
                'ButtonPushedFcn',@(~,~) obj.saveSession());
            uibutton(hdr,'Text','Open session', ...
                'Tooltip','Restore a full saved session (config + results + snapshot)', ...
                'ButtonPushedFcn',@(~,~) obj.loadSession());
            obj.logToggle = uibutton(hdr, 'Text', 'Log', 'FontColor', [0 0 0.4], ...
                'Tooltip', 'Show / hide the NeuroQC log', ...
                'ButtonPushedFcn', @(~,~) obj.toggleLog());
            uibutton(hdr, 'Text', 'About', 'FontColor', [0 0 0.4], ...
                'ButtonPushedFcn', @(~,~) about());

            % Row 2: 4-step tabs (single navigation; no duplicate footer)
            obj.tabGroup = uitabgroup(grid);
            obj.tabGroup.Layout.Row = 2; obj.tabGroup.Layout.Column = [1 3];
            obj.buildStep1Data();
            obj.buildStep2Scope();
            obj.buildStep3Params();
            obj.buildStep4Results();

            % Row 3: collapsible log panel (collapsed by default)
            obj.logPanel = uipanel(grid, 'Title', 'Log', ...
                'ForegroundColor', [0 0 0.4], 'BackgroundColor', [0.93 0.96 1], ...
                'Visible', 'off');
            obj.logPanel.Layout.Row = 3; obj.logPanel.Layout.Column = [1 3];
            gl = uigridlayout(obj.logPanel, [1 1]); gl.Padding = [4 4 4 4];
            obj.logArea = uitextarea(gl, 'Editable', 'off', ...
                'FontName', 'Courier', 'FontSize', 11);

            obj.handoffModeChanged();
            obj.refreshSpaceTable();
            obj.autoLoadCurrentSet(true);
            obj.refreshParamRows();
            if ~isempty(obj.SourceEEG) && ((isfield(obj.SourceEEG,'epoch') && ~isempty(obj.SourceEEG.epoch)) || (isfield(obj.SourceEEG,'trials') && obj.SourceEEG.trials>1)) && isempty(obj.completedField.Value)
                obj.completedField.Value='epoch';obj.handoffModeChanged();
            end
            if isempty(obj.SourceEEG),obj.setStatus('Load an EEG dataset in Data to begin.');
            else,obj.setStatus('Input snapshot loaded across all tabs; choose future steps in Scope.');end
            obj.refreshActionGate();
        end

        function toggleLog(obj)
            if isempty(obj.logPanel) || ~isvalid(obj.logPanel), return; end
            vis = char(string(obj.logPanel.Visible));
            if strcmp(vis, 'on')
                obj.logPanel.Visible = 'off';
                obj.mainGrid.RowHeight{3} = 0;
                obj.logToggle.Text = 'Log';
            else
                obj.logPanel.Visible = 'on';
                obj.mainGrid.RowHeight{3} = 220;
                obj.logToggle.Text = 'Hide log';
            end
        end

        function buildStep1Data(obj)
            t = uitab(obj.tabGroup, 'Title', '1. Data');
            g = uigridlayout(t, [7 3]);
            g.Scrollable='on';
            g.RowHeight = {30, 108, 32, 32, 32, 54, '1x'};
            g.ColumnWidth = {130, '1x', 200};

            uilabel(g, 'Text', 'Source:', 'FontColor', [0 0 0.4]);
            obj.srcEdit = uieditfield(g, 'text', 'Value', '(none)', 'Editable', 'off');
            obj.srcEdit.Layout.Column = [2 3];

            uilabel(g, 'Text', 'Dataset:');
            % EEGLAB main-window style: label/value rows in Courier
            obj.summaryLabel = uilabel(g, 'Text', sprintf([ ...
                'Channels:  -\nRate:      -\nData:      -\nEvents:    -\n' ...
                'ICA:       -\nLocations: -']), ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
                'FontName', 'Courier', 'FontSize', 11, 'FontColor', [0 0 0.4]);
            lg = uigridlayout(g, [4 1]);
            lg.Layout.Row = 2; lg.Layout.Column = 3;
            lg.RowHeight = {'1x', '1x', '1x', '1x'}; lg.Padding = [0 0 0 0];
            uibutton(lg, 'Text', 'Load ...', 'Tooltip', 'Load a .set file (parses EEG.history into Handoff)', ...
                'ButtonPushedFcn', @(~,~) obj.loadFile());
            uibutton(lg, 'Text', 'Refresh', ...
                'Tooltip', 'Switch back to the EEGLAB current set (also clears a loaded .set lock)', ...
                'ButtonPushedFcn', @(~,~) obj.refreshFromEEGLAB());
            uibutton(lg, 'Text', 'Import history', ...
                'Tooltip', ['Parse EEG.history of the current input into Handoff / Completed set. ' ...
                'For a cross-session record use the EEGLAB menu Checkpoint...'], ...
                'ButtonPushedFcn', @(~,~) obj.importHistory());
            uibutton(lg, 'Text', 'History...', ...
                'Tooltip', 'Show the full EEG.history text and how each line maps to a NeuroQC step', ...
                'ButtonPushedFcn', @(~,~) obj.showHistory());

            at(uilabel(g, 'Text', 'Data unit:'), 3, 1);
            obj.unitDD = at(uidropdown(g, 'Items', {'choose','uV','V'}, 'Value', 'choose', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 3, 2);

            at(uilabel(g, 'Text', 'Output folder:'), 4, 1);
            obj.outField = at(uieditfield(g, 'text', 'Value', ''), 4, 2);
            at(uibutton(g, 'Text', 'Browse', ...
                'ButtonPushedFcn', @(~,~) obj.browseOut()), 4, 3);

            at(uilabel(g, 'Text', 'QC file:'), 5, 1);
            obj.qcField = at(uieditfield(g, 'text', 'Placeholder', 'CSV/JSON path (optional)'), 5, 2);
            at(uibutton(g, 'Text', 'Import QC', ...
                'Tooltip', ['Generate: this path is injected automatically into every recipe. ' ...
                'After Generate: re-rank existing results with the file.'], ...
                'ButtonPushedFcn', @(~,~) obj.importQC()), 5, 3);

            at(uilabel(g, 'Text', 'Trial rule:'), 6, 1);
            obj.trialMode = at(uidropdown(g, 'Items', ...
                {'choose','existing selection','already screened: all','loaded options JSON'}, ...
                'Value', 'choose', 'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 6, 2);
            trialButtons=uigridlayout(g,[2 1]);trialButtons.Layout.Row=6;trialButtons.Layout.Column=3;trialButtons.Padding=[0 0 0 0];trialButtons.RowHeight={24,24};
            uibutton(trialButtons,'Text','Options JSON', ...
                'Tooltip','Load search settings only (no results). Full restore uses Save / Open session.', ...
                'ButtonPushedFcn',@(~,~) obj.loadOptions());
            uibutton(trialButtons,'Text','Confirm input settings', ...
                'Tooltip','Mark unit, trial rule and handoff as reviewed for this snapshot (required before Generate / Compare).', ...
                'ButtonPushedFcn',@(~,~) obj.confirmInputSettings());

            note = uilabel(g, 'Text', sprintf([ ...
                'All tabs use the same input snapshot. Refresh explicitly reloads the current EEGLAB EEG.\n' ...
                'This page manages data and input settings only. Parameter capture lives in Step 3 (Capture in EEGLAB);\n' ...
                'choose the steps and their order in Step 2 (Scope), then compare in Step 4.']), ...
                'WordWrap', 'on', 'VerticalAlignment', 'top', ...
                'FontColor', [0 0 0.4]);
            note.Layout.Row = 7; note.Layout.Column = [1 3];
        end

        function buildStep2Scope(obj)
            t = uitab(obj.tabGroup, 'Title', '2. Scope');
            outer=uigridlayout(t,[2 1]);outer.RowHeight={50,'1x'};outer.Padding=[4 4 4 4];
            obj.scopeSourceLabel=uilabel(outer,'Text','No input loaded','WordWrap','on', ...
                'FontColor',[0 0 0.4],'FontSize',11);
            g = uigridlayout(outer, [20 3]);
            g.Layout.Row=2;g.Scrollable='on';obj.scopeGrid=g;
            g.RowHeight = {26, 220, 30, 26, 30, 30, 30, 30, 30, 30, 30, 26, 30, 30, 30, 30, 26, 30, 30, 26, 96, 58};
            g.ColumnWidth = {140, '1x', 200};

            % --- Steps (EEGLAB listbox idiom) ---
            obj.workflowHint=at(uilabel(g, 'Text', 'Available steps (left) | Selected workflow (right)', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4]), 1, [1 3]);
            chooser=uigridlayout(g,[1 3]);chooser.Layout.Row=2;chooser.Layout.Column=[1 3];
            chooser.ColumnWidth={'1x','1x',110};chooser.Padding=[0 0 0 0];
            obj.stepsList = at(uilistbox(chooser, 'Items', neuroqc.pipeline.StageModel.canonicalOrder(), ...
                'Multiselect', 'on', 'Value', {}, 'FontName', 'Courier', ...
                'ValueChangedFcn', @(~,~) obj.stepsListChanged()), 1, 1);
            obj.workflowList=uilistbox(chooser,'Items',{},'Value',{},'FontName','Courier', ...
                'Tooltip','Selected workflow order; use Up / Down to fix the displayed sequence');
            controls=uigridlayout(chooser,[4 1]);controls.Padding=[0 0 0 0];controls.RowHeight={30,30,30,30};
            uibutton(controls,'Text','Up','ButtonPushedFcn',@(~,~) obj.moveWorkflow(-1));
            uibutton(controls,'Text','Down','ButtonPushedFcn',@(~,~) obj.moveWorkflow(1));
            uibutton(controls,'Text','Remove','ButtonPushedFcn',@(~,~) obj.removeWorkflowStep());
            uibutton(controls,'Text','Free order','ButtonPushedFcn',@(~,~) obj.freeWorkflowOrder());
            obj.selectedStepsField = at(uieditfield(g, 'text', 'Value', '', ...
                'Placeholder', 'or comma steps: epoch,baseline', ...
                'ValueChangedFcn', @(~,~) obj.selectedStepsTyped()), 3, [1 2]);
            at(uilabel(g, 'Text', 'Off / fixed / search via selection + values', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.3 0.3 0.5], ...
                'FontSize', 11), 3, 3);

            % --- Handoff ---
            at(uilabel(g, 'Text', 'Handoff', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4]), 4, [1 3]);
            at(uilabel(g, 'Text', 'Mode:'), 5, 1);
            obj.handoffDD = at(uidropdown(g, 'Items', {'prefix (start after)','exact set (non-canonical)'}, ...
                'ItemsData', {'prefix','set'}, 'Value','set', ...
                'ValueChangedFcn', @(~,~) obj.handoffModeChanged()), 5, 2);
            at(uilabel(g, 'Text', 'Default: exact completed set', 'FontColor', [0.3 0.3 0.5]), 5, 3);
            at(uilabel(g, 'Text', 'Start after:'), 6, 1);
            obj.stageDD = at(uidropdown(g, 'Items', [{'raw'} neuroqc.pipeline.StageModel.canonicalOrder()], ...
                'Value', 'raw', ...
                'ValueChangedFcn', @(~,~) obj.refreshSpaceTable()), 6, 2);
            obj.adoptCkptBtn = at(uibutton(g, 'Text', 'Adopt checkpoint', ...
                'Tooltip', ['Read neuroqc_checkpoint (EEGLAB menu Checkpoint...) and set Handoff / Completed set. ' ...
                'For file history use Step 1 Import history'], ...
                'ButtonPushedFcn', @(~,~) obj.adoptCheckpoint()), 6, 3);
            at(uilabel(g, 'Text', 'Completed set:'), 7, 1);
            obj.completedField = at(uieditfield(g, 'text', 'Placeholder', 'exact set only: filter,epoch', ...
                'Enable', 'off', ...
                'ValueChangedFcn', @(~,~) obj.refreshSpaceTable()), 7, 2);
            at(uilabel(g, 'Text', 'Step order:'), 8, 1);
            obj.stepOrderField = at(uieditfield(g, 'text', 'Placeholder', 'Fixed precedence: filter,reref,run_ica,epoch', ...
                'ValueChangedFcn',@(~,~) obj.refreshParamRows()), 8, 2);
            obj.searchOrderCheck=at(uicheckbox(g,'Text','Search unfixed order','Value',false, ...
                'Tooltip','Step order pins relative precedence; enumerate all remaining valid orders', ...
                'ValueChangedFcn',@(~,~) obj.refreshParamRows()),8,3);
            at(uilabel(g, 'Text', 'Fixed slots:'), 9, 1);
            obj.fixedPosField = at(uieditfield(g, 'text', 'Value', '', ...
                'Placeholder', 'filter=1,epoch=6', ...
                'Tooltip', 'Absolute slot per step; requires Search unfixed order', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 9, 2);
            at(uilabel(g, 'Text', 'Max orders:'), 10, 1);
            obj.maxOrdersField = at(uieditfield(g, 'text', 'Value', '10000', ...
                'Tooltip', 'Hard limit: generation errors when legal orders exceed it (never truncates)', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 10, 2);
            at(uilabel(g, 'Text', 'Parallel compare:'), 11, 1);
            obj.useParallelCheck = at(uicheckbox(g, 'Text', '', 'Value', true, ...
                'Tooltip', 'Use parfor for candidate comparison (requires Parallel Computing Toolbox; serial fallback)', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 11, 2);

            % --- Contract (no prefill: type what you actually want) ---
            at(uilabel(g, 'Text', 'Contract (events, epochs, components)', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4]), 12, [1 3]);
            at(uilabel(g, 'Text', 'Epoch window:'), 13, 1);
            obj.epochField = at(uieditfield(g, 'text', 'Value', '', ...
                'Placeholder', 'e.g. -0.2 1  (sec rel. event)', ...
                'Tooltip', 'Epoch window in seconds relative to the event. Empty is not assumed for you.', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 13, 2);
            at(uilabel(g, 'Text', 'Baseline:'), 14, 1);
            obj.baseField = at(uieditfield(g, 'text', 'Value', '', ...
                'Placeholder', 'e.g. -0.2 0  (sec rel. event)', ...
                'Tooltip', 'Baseline window in seconds relative to the event, inside the epoch.', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 14, 2);
            at(uilabel(g, 'Text', 'Events:'), 15, 1);
            obj.condField = at(uieditfield(g, 'text', 'Value', '', ...
                'Placeholder', 'name:code, or use Select events...', ...
                'Tooltip', 'Condition/event codes as name:code, comma separated. Empty waits for your input.', ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 15, 2);
            at(uibutton(g, 'Text', 'Select events...', ...
                'ButtonPushedFcn', @(~,~) obj.pickEventTypes()), 15, 3);
            at(uilabel(g, 'Text', 'Components:'), 16, 1);
            obj.compField = at(uieditfield(g, 'text', ...
                'Value', '', ...
                'Placeholder', 'name:start end @ ch[:type]; ... (any name)', ...
                'Tooltip', ['Free format: any component name, e.g. ' ...
                'WM:0.2 0.4 @ Cz:negative. Type is mean|peak|negative|positive (default mean).'], ...
                'ValueChangedFcn', @(~,~) obj.refreshActionGate()), 16, 2);
            compBtns = uigridlayout(g, [1 2]);
            compBtns.Layout.Row = 16; compBtns.Layout.Column = 3;
            compBtns.ColumnWidth = {'1x', '1.5x'}; compBtns.Padding = [0 0 0 0];
            at(uibutton(compBtns, 'Text', 'New...', ...
                'Tooltip', 'Define a component: name, time window, channels, type', ...
                'ButtonPushedFcn', @(~,~) obj.newComponent()), 1, 1);
            at(uibutton(compBtns, 'Text', 'Channels...', ...
                'Tooltip', 'Set the channels of a component from the current data', ...
                'ButtonPushedFcn', @(~,~) obj.pickComponentChannels()), 1, 2);

            % --- Ranking ---
            at(uilabel(g, 'Text', 'Ranking', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4]), 17, [1 3]);
            at(uilabel(g, 'Text', 'Goal:'), 18, 1);
            obj.goalDD = at(uidropdown(g, 'Items', ...
                {'Balanced','Retain more trials','Lower filter distortion','Stable topography','Custom weights'}, ...
                'ItemsData', {'balanced','minimalRetention','minimalDistortion','topoStability','custom'}, ...
                'Tooltip', 'Ranking profile: switch Goal only changes the weights, never the Constraints.', ...
                'ValueChangedFcn', @(~,~) obj.goalChanged()), 18, 2);
            at(uilabel(g, 'Text', 'Weights:'), 19, 1);
            obj.wField = at(uieditfield(g, 'text', 'Value', '1 1 1 1 1', ...
                'Tooltip', 'Reliability, retention, topography, filter distortion, interpolation. Edit directly (Goal switches to Custom).', ...
                'ValueChangedFcn', @(~,~) obj.weightsChanged()), 19, 2);

            % --- Constraints (hard pass/fail gates; empty = built-in default) ---
            at(uilabel(g, 'Text', 'Constraints (hard gates before ranking)', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'FontColor', [0 0 0.4]), 20, [1 3]);
            cg = uigridlayout(g, [4 4]);
            cg.Layout.Row = 21; cg.Layout.Column = [1 3];
            cg.ColumnWidth = {190, '1x', 200, '1x'};
            cg.RowHeight = repmat({24}, 1, 4);
            cg.Padding = [0 0 0 0];
            spec = { ...
                'maxDistortion', '0.5',   'Relative waveform change (0-1+)' ; ...
                'minRetention', '0.30',   'Min trial retention (0-1)' ; ...
                'maxInterpRatio', '0.30', 'Max interpolated channel ratio' ; ...
                'maxBadRatio', '0.30',    'Max bad channel ratio' ; ...
                'maxConditionRetentionSpread', '0.25', 'Max retention spread across conditions' ; ...
                'minRank', '4',           'Minimum matrix rank' ; ...
                'allowEventLoss', '0',    'Allow event loss: 0 = reject, 1 = allow'};
            obj.constraintFields = struct();
            for ci = 1:size(spec, 1)
                r = ceil(ci / 2);
                if mod(ci, 2) == 1, c0 = 1; else, c0 = 3; end
                lbl = strrep(spec{ci, 1}, 'maxConditionRetentionSpread', 'cond retention spread');
                at(uilabel(cg, 'Text', lbl, 'HorizontalAlignment', 'right', ...
                    'FontSize', 11, 'FontColor', [0 0 0.4]), r, c0);
                obj.constraintFields.(spec{ci, 1}) = at(uieditfield(cg, 'text', ...
                    'Value', spec{ci, 2}, 'HorizontalAlignment', 'right', ...
                    'Tooltip', spec{ci, 3}, ...
                    'ValueChangedFcn', @(~,~) obj.refreshActionGate()), r, c0 + 1);
            end
            % Remaining pair (row 4, col 3-4): live summary of what applies.
            obj.constraintSummary = at(uilabel(cg, 'Text', 'Empty field = built-in default', ...
                'HorizontalAlignment', 'left', 'FontSize', 11, 'FontColor', [0.3 0.3 0.5]), 4, [3 4]);

            note = at(uilabel(g, 'Text', sprintf([ ...
                'Only steps are compared. Conditions come from event codes.\n' ...
                'Trial rule required for epoch/baseline/artifact-rejection comparison.']), ...
                'WordWrap', 'on', 'VerticalAlignment', 'top', 'FontColor', [0 0 0.4]), 22, [1 3]);
        end

        function buildStep3Params(obj)
            t = uitab(obj.tabGroup, 'Title', '3. Params');
            g = uigridlayout(t, [4 1]);
            g.RowHeight = {50, 58, '1x', 58};
            obj.paramSourceLabel=uilabel(g,'Text','No input loaded','WordWrap','on', ...
                'FontColor',[0 0 0.4],'FontSize',11);
            uilabel(g, 'Text', sprintf([ ...
                'Current input and future candidates are shown separately below. ', ...
                'A disabled candidate does not mean the input lacks that feature. ', ...
                'Choose steps in Scope; dialogs capture candidate settings on a copy.']), ...
                'WordWrap', 'on', 'HorizontalAlignment', 'left', ...
                'FontColor', [0 0 0.4]);
            % Left: step list (EEGLAB listbox) | Right: selected-step preview
            body = uigridlayout(g, [1 2]);
            body.Layout.Row = 3;
            body.ColumnWidth = {240, '1x'};
            body.Padding = [0 0 0 0];

            left = uigridlayout(body, [3 1]);
            left.Layout.Column = 1;
            left.RowHeight = {26, '1x',32};
            left.Padding = [0 0 0 0];
            obj.paramListLabel=uilabel(left, 'Text', 'Steps (execution order)', ...
                'FontWeight', 'bold', 'HorizontalAlignment', 'left', ...
                'FontColor', [0 0 0.4]);
            obj.paramStepList = uilistbox(left, ...
                'Items', neuroqc.pipeline.StageModel.canonicalOrder(), ...
                'Value', 'chanloc', 'FontName', 'Courier', ...
                'ValueChangedFcn', @(~,~) obj.paramListChanged());

            orderButtons=uigridlayout(left,[1 1]);orderButtons.Padding=[0 0 0 0];
            uibutton(orderButtons,'Text','History...','Tooltip', ...
                'Full EEG.history of the current input, line by line, with its step mapping', ...
                'ButtonPushedFcn',@(~,~) obj.showHistory());
            right = uigridlayout(body, [2 1]);
            right.Layout.Column = 2;
            right.RowHeight = {26, '1x'};
            right.Padding = [0 0 0 0];
            obj.paramTitle = uilabel(right, 'Text', 'chanloc -- pop_chanedit', ...
                'FontWeight', 'bold', 'HorizontalAlignment', 'left', ...
                'FontName', 'Courier', 'FontColor', [0 0 0.4]);
            obj.paramPreview = uitextarea(right, 'Editable', 'off', ...
                'FontName', 'Courier', 'FontSize', 12);

            % Actions: 3 buttons replace the old 42 per-row buttons
            acts = uigridlayout(g, [2 6]);
            acts.Layout.Row = 4;
            acts.ColumnWidth = {'1.4x', '0.7x', '0.9x', '1.4x', '1.1x', '1.2x'};
            acts.RowHeight = {36, 18};
            acts.Padding = [0 0 0 0];
            uibutton(acts, 'Text', 'Capture in EEGLAB...', ...
                'Tooltip', 'Open the pop_* dialog for the selected step', ...
                'ButtonPushedFcn', @(~,~) obj.editSelectedStep());
            uibutton(acts, 'Text', 'Help', ...
                'ButtonPushedFcn', @(~,~) obj.helpSelectedStep());
            uibutton(acts, 'Text', 'Preview', 'Tooltip', 'Remaining combinations', ...
                'ButtonPushedFcn', @(~,~) obj.previewRemaining());
            obj.runBtn = uibutton(acts, 'Text', 'Generate recipes', ...
                'Tooltip', 'Enumerate discrete recipes (no signal processing)', ...
                'ButtonPushedFcn', @(~,~) obj.runSearch());
            uibutton(acts, 'Text', 'Contract only', ...
                'ButtonPushedFcn', @(~,~) obj.buildContract());
            uibutton(acts, 'Text', 'Space table...', ...
                'ButtonPushedFcn', @(~,~) obj.showSpaceDock());
            obj.gateLabel = uilabel(acts, 'Text', '', 'HorizontalAlignment', 'left', ...
                'FontSize', 11, 'FontColor', [0.7 0 0]);
            obj.gateLabel.Layout.Row = 2; obj.gateLabel.Layout.Column = [1 6];
        end

        function paramListChanged(obj)
            if isempty(obj.paramStepList) || ~isvalid(obj.paramStepList), return; end
            s = char(obj.paramStepList.Value);
            if isempty(s), return; end
            fn = stepPopFunction(s);
            if isempty(fn), fn = '(no single dialog)'; end
            if ~isempty(obj.paramTitle) && isvalid(obj.paramTitle)
                obj.paramTitle.Text = sprintf('%s  --  %s', s, fn);
            end
            if ~isempty(obj.paramPreview) && isvalid(obj.paramPreview)
                obj.paramPreview.Value = cellstr(splitlines(string(obj.stepDetails(s))));
            end
        end

        function editSelectedStep(obj)
            if isempty(obj.paramStepList) || ~isvalid(obj.paramStepList), return; end
            s = char(obj.paramStepList.Value);
            if isempty(s), obj.setStatus('Select a step first'); return; end
            obj.editStepInEEGLAB(s);
        end

        function helpSelectedStep(obj)
            if isempty(obj.paramStepList) || ~isvalid(obj.paramStepList), return; end
            s = char(obj.paramStepList.Value);
            if isempty(s), return; end
            obj.stepHelp(s);
        end

        function buildStep4Results(obj)
            t = uitab(obj.tabGroup, 'Title', '4. Results');
            g = uigridlayout(t, [3 1]);
            g.RowHeight = {48,'1x', 58};
            obj.coverageLabel=uilabel(g,'Text','No candidates generated','WordWrap','on');
            obj.resultTable = uitable(g, 'ColumnSortable', false);
            obj.resultTable.ColumnName = {'ID','Steps','Front','GoalScore','Labels', ...
                'Rel','Reten','Dist','QC','Topo','Reason','Recipe'};
            obj.resultTable.Data = cell(0, 12);
            % EEGLAB-style short action bar
            acts = uigridlayout(g, [2 6]);
            acts.Layout.Row = 3;
            acts.ColumnWidth = repmat({'1x'}, 1, 6);
            acts.RowHeight = {36, 18};
            acts.Padding = [0 0 0 0];
            obj.compareBtn = uibutton(acts, 'Text', 'Compare', 'Tooltip', 'Compare selected candidates', ...
                'ButtonPushedFcn', @(~,~) obj.compareCandidates(false));
            obj.compareAllBtn = uibutton(acts, 'Text', 'Compare all', ...
                'Tooltip', 'Compare every candidate that has not been compared yet', ...
                'ButtonPushedFcn', @(~,~) obj.compareCandidates(true));
            obj.rerankBtn = uibutton(acts, 'Text', 'Re-rank', ...
                'Tooltip', ['Re-apply the Scope Constraints and ranking to already-evaluated candidates. ', ...
                'No candidate is reprocessed. Use after editing Constraints.'], ...
                'ButtonPushedFcn', @(~,~) obj.rerankCandidates());
            obj.retryBtn = uibutton(acts,'Text','Retry failed', ...
                'Tooltip','Rerun execution failures (needs results, components and unchanged settings)', ...
                'ButtonPushedFcn',@(~,~) obj.retryFailed());
            uibutton(acts, 'Text', 'Load', 'Tooltip', 'Adopt selected candidate', ...
                'ButtonPushedFcn', @(~,~) obj.adoptCandidate());
            uibutton(acts, 'Text', 'Recipe...', 'Tooltip', 'Open exported recipe script', ...
                'ButtonPushedFcn', @(~,~) obj.openSelectedRecipe());
            obj.gateLabel4 = uilabel(acts, 'Text', '', 'HorizontalAlignment', 'left', ...
                'FontSize', 11, 'FontColor', [0.7 0 0]);
            obj.gateLabel4.Layout.Row = 2; obj.gateLabel4.Layout.Column = [1 6];
            % Keep spaceTable/comboLabel handles alive (hidden host) for
            % programmatic APIs and tests; the visible editor is showSpaceDock.
            host = uipanel(t, 'Title', 'Search space (advanced)', 'Visible', 'off');
            gh = uigridlayout(host, [1 1]);
            obj.spaceTable = uitable(gh, 'ColumnSortable', true);
            set(obj.spaceTable, 'ColumnName', {'Dimension','Values (use |)','Mode','Count'}, ...
                'ColumnEditable', [false true false false]);
            obj.spaceTable.CellEditCallback = @(~,e) obj.editSpace(e);
            obj.spaceTable.Data = cell(0, 4);
            obj.comboLabel = uilabel(host, 'Text', 'Combos: —', 'Visible', 'off');
        end

        function showSpaceDock(obj)
            obj.refreshSpaceTable();
            if ~isempty(obj.spaceDlg) && isvalid(obj.spaceDlg)
                figure(obj.spaceDlg);
                return;
            end
            f = figure('Name', 'Search space -- pop_neuroqc_space', ...
                'NumberTitle', 'off', 'MenuBar', 'none', 'ToolBar', 'none', ...
                'Color', [.93 .96 1], 'Position', [180 160 660 440]);
            g = uigridlayout(f, [3 1]);
            g.RowHeight = {26, '1x', 40};
            g.Padding = [8 8 8 8];
            obj.spaceDlgInfo = uilabel(g, 'Text', obj.comboLabel.Text, ...
                'HorizontalAlignment', 'left', 'FontName', 'Courier', ...
                'FontColor', [0 0 0.4]);
            obj.spaceDlgTable = uitable(g, 'ColumnSortable', true, ...
                'Data', obj.spaceTable.Data, ...
                'ColumnName', {'Dimension','Values (use |)','Mode','Count'}, ...
                'ColumnEditable', [false true false false]);
            obj.spaceDlgTable.CellEditCallback = @(~,e) obj.editSpace(e);
            acts = uigridlayout(g, [1 5]);
            acts.Layout.Row = 3;
            uibutton(acts, 'Text', 'Lock step...', 'Tooltip', 'Pin every free dimension of one step', ...
                'ButtonPushedFcn', @(~,~) obj.lockStep());
            uibutton(acts, 'Text', 'Unlock step...', 'Tooltip', 'Release all pinned dimensions of one step', ...
                'ButtonPushedFcn', @(~,~) obj.unlockStep());
            uibutton(acts, 'Text', 'Lock...', 'Tooltip', 'Pin one value of the selected dimension', ...
                'ButtonPushedFcn', @(~,~) obj.lockSelected());
            uibutton(acts, 'Text', 'Unlock', ...
                'ButtonPushedFcn', @(~,~) obj.unlockSelected());
            uibutton(acts, 'Text', 'Close', ...
                'ButtonPushedFcn', @(~,~) close(f));
            obj.spaceDlg = f;
        end

        function setStatus(obj, msg)
            % Carries the inert-constraint note so a configured gate that
            % this QC source cannot evaluate is never silently dropped.
            sfx = obj.constraintNote();
            if ~isempty(sfx), msg = [msg ' | ' sfx]; end
            if ~isempty(obj.statusLabel) && isvalid(obj.statusLabel)
                obj.statusLabel.Text = msg;
                drawnow limitrate;
            end
        end

        function note = constraintNote(obj)
            % Short suffix naming Scope knobs this QC source could not evaluate.
            note = '';
            R = obj.Results;
            if isempty(R) || ~isstruct(R) || ~isfield(R, 'constraintSkipped') ...
                    || isempty(R.constraintSkipped)
                return;
            end
            note = [strjoin({R.constraintSkipped.name}, ', ') ...
                ' not evaluated by this QC source'];
        end

        function updateConstraintSummary(obj)
            % Live Constraints summary: gates armed, field errors, and the
            % knobs this QC source could not evaluate.
            if isempty(obj.constraintSummary) || ~isvalid(obj.constraintSummary), return; end
            [~, errs] = obj.constraintLimits();
            if ~isempty(errs)
                obj.constraintSummary.Text = ['Constraint error: ' errs{1}];
                obj.constraintSummary.FontColor = [0.7 0 0];
                return;
            end
            obj.constraintSummary.FontColor = [0.3 0.3 0.5];
            txt = '7 gates active; empty field = built-in default';
            R = obj.Results;
            if ~isempty(R) && isstruct(R) && isfield(R, 'constraintSkipped') ...
                    && ~isempty(R.constraintSkipped)
                bits = arrayfun(@(s) sprintf('%s %d/%d', s.name, s.applied, s.n), ...
                    R.constraintSkipped, 'UniformOutput', false);
                txt = [txt '; NOT evaluated: ' strjoin(bits, ', ')];
            end
            obj.constraintSummary.Text = txt;
        end

        function autoLoadCurrentSet(obj, silent)
            if nargin<2,silent=false;end
            % One explicit snapshot drives every tab and all generated recipes.
            % Preview/Generate must not silently switch to another EEGLAB set.
            if (silent && ~isempty(obj.SourceEEG)) || obj.sourceFromFile
                if ~isempty(obj.srcEdit) && strcmp(obj.srcEdit.Value,'(none)')
                    obj.srcEdit.Value='provided EEG snapshot';
                end
                obj.updateSummary();return;
            end
            incoming=[];label='(none)';current=NaN;
            try
                if evalin('base','exist(''EEG'',''var'')')
                    candidate=evalin('base','EEG');
                    if isstruct(candidate) && isscalar(candidate) && isfield(candidate,'data') && ~isempty(candidate.data)
                        incoming=candidate;label='base:EEG (current snapshot)';
                    end
                end
                if isempty(incoming) && evalin('base','exist(''ALLEEG'',''var'') && exist(''CURRENTSET'',''var'')')
                    sets=evalin('base','ALLEEG');current=evalin('base','CURRENTSET');
                    if isscalar(current) && current>=1 && current<=numel(sets)
                        incoming=sets(current);label=sprintf('ALLEEG(%d)',current);
                    end
                end
            catch ME
                obj.logMsg('Current EEG read: %s',ME.message);
            end
            if ~isempty(incoming)
                changed=isempty(obj.SourceEEG) || ...
                    ~strcmp(neuroqc.utils.hashEEG(obj.SourceEEG),neuroqc.utils.hashEEG(incoming));
                obj.acceptSource(incoming);obj.lastCurrentSet=current;
                obj.srcEdit.Value=label;
                obj.Results=[];obj.GeneratedOptions=[];obj.showResults();
                if ~isempty(obj.resultTable),obj.resultTable.Data=cell(0,12);end
                % Same contract as Load ...: EEG.history drives the Handoff and
                % fills only the Scope fields you left empty. The Handoff parse
                % runs only for a NEW source, so a Refresh never overwrites a
                % Completed set you edited by hand.
                n=0;mapped=0;total=0;filled={};
                try
                    if changed
                        [n,mapped,total]=obj.parseHistoryIntoHandoff(incoming);
                    end
                    filled=obj.fillScopeFromHistory(incoming);
                catch ME
                    obj.logMsg('History parse skipped: %s',ME.message);
                end
                if ~silent
                    note='';
                    if ~isempty(filled)
                        note=sprintf('. Filled empty Scope field(s): %s',strjoin(filled,'; '));
                    end
                    if n>0
                        obj.setStatus(sprintf(['Reloaded current EEG; parsed %d completed step(s) ' ...
                            'from EEG.history (%d of %d line(s) mapped)%s. Generate fresh candidates.'], ...
                            n,mapped,total,note));
                    else
                        obj.setStatus(['Reloaded current EEG; all tabs updated' note ...
                            '. Generate fresh candidates.']);
                    end
                end
            elseif ~silent
                obj.setStatus('No current EEG found; keeping the loaded snapshot.');
            end
            obj.updateSummary();
            obj.refreshActionGate();
        end

        function f=sourceFacts(obj)
            f=struct('name','(none)','channels',0,'rate',NaN,'data','not loaded', ...
                'events',0,'ica','not present','locations',0);
            e=obj.SourceEEG;if isempty(e),return;end
            f.name='unnamed EEG';
            if isfield(e,'setname') && ~isempty(e.setname),f.name=char(string(e.setname));end
            f.channels=e.nbchan;f.rate=e.srate;
            if (isfield(e,'epoch') && ~isempty(e.epoch)) || e.trials>1
                f.data=sprintf('%d epochs',e.trials);
            else,f.data='continuous';end
            if isfield(e,'event'),f.events=numel(e.event);end
            if isfield(e,'icaweights') && ~isempty(e.icaweights)
                f.ica=sprintf('present (%d components)',size(e.icaweights,1));
            end
            if isfield(e,'chanlocs')
                for k=1:numel(e.chanlocs)
                    ch=e.chanlocs(k);valid=true;xyz=[];
                    for name={'X','Y','Z'}
                        key=name{1};
                        if ~isfield(ch,key) || ~isnumeric(ch.(key)) || ~isscalar(ch.(key)) || ~isfinite(ch.(key))
                            valid=false;break;
                        end
                        xyz(end+1)=ch.(key); %#ok<AGROW>
                    end
                    if valid && norm(xyz)>0,f.locations=f.locations+1;end
                end
            end
        end

        function text=sourceBanner(obj)
            f=obj.sourceFacts();
            if isempty(obj.SourceEEG),text='Current input: none. Load EEG in Data.';return;end
            text=sprintf('Current input: %s | %d channels | %g Hz | %s | %d events\nICA: %s | XYZ locations: %d/%d', ...
                f.name,f.channels,f.rate,f.data,f.events,f.ica,f.locations,f.channels);
        end

        function updateSummary(obj)
            if isempty(obj.summaryLabel) || ~isvalid(obj.summaryLabel),return;end
            f=obj.sourceFacts();
            obj.summaryLabel.Text=sprintf('Channels:  %d\nRate:      %g Hz\nData:      %s\nEvents:    %d\nICA:       %s\nLocations: %d/%d valid XYZ', ...
                f.channels,f.rate,f.data,f.events,f.ica,f.locations,f.channels);
            text=obj.sourceBanner();obj.summaryLabel.Tooltip=text;
            for label={obj.scopeSourceLabel,obj.paramSourceLabel}
                if ~isempty(label{1}) && isvalid(label{1}),label{1}.Text=text;label{1}.Tooltip=text;end
            end
            obj.refreshParamRows();
        end

        function browseOut(obj)
            d = uigetdir(pwd, 'Select output folder');
            if isequal(d, 0), return; end
            obj.outField.Value = d;
        end

        function stepsListChanged(obj)
            sel = obj.stepsList.Value;
            if ischar(sel), sel = {sel}; end
            if isstring(sel), sel = cellstr(sel); end
            obj.selectedStepsField.Value = strjoin(sel, ',');
            obj.syncTrialVisibility();
            obj.refreshSpaceTable();
            obj.refreshActionGate();
        end

        function selectedStepsTyped(obj)
            raw = strtrim(obj.selectedStepsField.Value);
            if isempty(raw)
                obj.stepsList.Value = {};
            else
                parts = cellfun(@strtrim, strsplit(raw, ','), 'UniformOutput', false);
                parts = parts(~cellfun(@isempty, parts));
                known = intersect(parts, obj.stepsList.Items, 'stable');
                obj.stepsList.Value = known;
            end
            obj.syncTrialVisibility();
            obj.refreshSpaceTable();
            obj.refreshActionGate();
        end

        function selectAllSteps(obj, on)
            if on
                [done,mode]=obj.handoffScope();done=neuroqc.pipeline.StageModel.normalizeCompleted(done,mode);
                % Everything not already completed stays selectable; steps
                % that look wrong for this input are reported, not dropped.
                selected=setdiff(obj.stepsList.Items,done,'stable');
                notes={};
                if ismember('interpolate',selected)
                    notes{end+1}='interpolate runs only where channel info is available';
                end
                if ~isempty(obj.SourceEEG) && ((isfield(obj.SourceEEG,'epoch') && ~isempty(obj.SourceEEG.epoch)) ...
                        || (isfield(obj.SourceEEG,'trials') && obj.SourceEEG.trials>1))
                    if ismember('epoch',selected)
                        notes{end+1}='the input is already epoched: declare epoch as completed, or remove the epoch step';
                    end
                    if ismember('reject_continuous',selected)
                        notes{end+1}='continuous rejection cannot run on epochs: remove reject_continuous';
                    end
                end
                obj.stepsList.Value = selected;
                obj.selectedStepsField.Value = strjoin(selected, ',');
                msg='Selected every step that is not declared completed; configure native selections before Preview.';
                for k=1:numel(notes)
                    msg=[msg sprintf(' Note: %s.',notes{k})]; %#ok<AGROW>
                    obj.logMsg('Select all note: %s',notes{k});
                end
                obj.setStatus(msg);
            else
                obj.stepsList.Value = {};
                obj.selectedStepsField.Value = '';
            end
            obj.syncTrialVisibility();
            obj.refreshSpaceTable();
            obj.refreshActionGate();
        end

        function steps = selectedStepList(obj)
            if ~isempty(obj.selectedStepsField) && ~isempty(strtrim(obj.selectedStepsField.Value))
                steps = cellfun(@strtrim, strsplit(strtrim(obj.selectedStepsField.Value), ','), ...
                    'UniformOutput', false);
                steps = steps(~cellfun(@isempty, steps));
                return;
            end
            if ~isempty(obj.stepsList)
                steps = obj.stepsList.Value;
                if ischar(steps), steps = {steps}; end
                if isstring(steps), steps = cellstr(steps); end
                if isempty(steps), steps = {}; end
            else
                steps = {};
            end
        end

        function syncTrialVisibility(obj)
            % Keep the trial-rule selector always enabled, but surface the
            % requirement as soon as epoched QC steps enter the scope.
            steps = obj.selectedStepList();
            need = any(ismember(steps, {'epoch','baseline','artifact_reject','auto_reject','reject_jointprob','reject_kurtosis'}));
            if ~isempty(obj.trialMode) && isvalid(obj.trialMode)
                if need
                    obj.trialMode.Tooltip = ['Epoched QC steps selected: Compare needs a formal trial rule ' ...
                        '(existing selection / already screened: all).'];
                else
                    obj.trialMode.Tooltip = '';
                end
            end
        end

        function pickEventTypes(obj)
            try
                assert(~isempty(obj.SourceEEG), 'NeuroQC:Source', 'Load current EEG first');
                assert(exist('eeg_eventtypes', 'file') == 2 && exist('pop_chansel', 'file') == 2, ...
                    'NeuroQC:EEGLAB', 'EEGLAB pop_chansel/eeg_eventtypes not on path');
                types = eeg_eventtypes(obj.SourceEEG);
                assert(~isempty(types), 'NeuroQC:Events', 'Dataset has no event types');
                [~, selStr] = pop_chansel(types);
                if isempty(selStr)
                    obj.setStatus('Event selection cancelled');
                    return;
                end
                picked = parseChanselSelection(selStr);
                if isempty(picked)
                    obj.setStatus('No events selected');
                    return;
                end
                % Prefer name:code when a default cond pattern exists; else bare codes
                names = cell(1, numel(picked));
                for i = 1:numel(picked)
                    names{i} = sprintf('event_%s', picked{i});
                end
                parts = cell(1, numel(picked));
                for i = 1:numel(picked)
                    parts{i} = sprintf('%s:%s', names{i}, picked{i});
                end
                obj.condField.Value = strjoin(parts, ', ');
                obj.refreshActionGate();
                obj.setStatus(sprintf('Selected %d event type(s)', numel(picked)));
                obj.logMsg('Events: %s', strjoin(picked, ', '));
            catch ME
                obj.setStatus(['Events error: ' ME.message]);
                obj.logMsg('%s', ME.message);
            end
        end

        function newComponent(obj)
            % Define or replace a component by name. Any name is accepted;
            % the channel list comes from the current data (pop_chansel).
            try
                assert(~isempty(obj.SourceEEG), 'NeuroQC:Source', 'Load current EEG first');
                known = strjoin(neuroqc.NeuroQC.SupportedERPComponents, ', ');
                answer = inputdlg({ ...
                    sprintf('Component name (any label; common: %s)', known), ...
                    'Window in seconds (start end, e.g. 0.18 0.32)', ...
                    'Type (mean | peak | negative | positive)'}, ...
                    'NeuroQC component', 1, {'', '', 'mean'});
                if isempty(answer), return; end
                name = strtrim(answer{1}); win = strtrim(answer{2});
                typ = lower(strtrim(answer{3}));
                assert(~isempty(name), 'NeuroQC:Component', 'Name the component');
                assert(~isempty(win), 'NeuroQC:Component', 'Give a window, e.g. 0.18 0.32');
                if isempty(typ), typ = 'mean'; end
                assert(any(strcmp(typ, {'mean','peak','negative','positive'})), ...
                    'NeuroQC:Component', 'Type must be mean, peak, negative or positive');
                labels = {};
                if isfield(obj.SourceEEG, 'chanlocs') && ~isempty(obj.SourceEEG.chanlocs)
                    labels = {obj.SourceEEG.chanlocs.labels};
                end
                assert(~isempty(labels), 'NeuroQC:Channels', 'No channel labels');
                assert(exist('pop_chansel', 'file') == 2, 'NeuroQC:Channels', ...
                    'pop_chansel (EEGLAB) is required to pick channels');
                picked = {};
                [~, selStr] = pop_chansel(labels);
                picked = parseChanselSelection(selStr);
                assert(~isempty(picked), 'NeuroQC:Component', 'Choose at least one channel');
                spec = sprintf('%s:%s @ %s', name, win, strjoin(picked, ','));
                if ~strcmp(typ, 'mean'), spec = [spec ':' typ]; end
                obj.compField.Value = upsertComponent(obj.compField.Value, name, spec);
                obj.Contract = [];
                obj.setStatus(sprintf('Component "%s" set (%s, %s)', name, strjoin(picked, ','), typ));
                obj.refreshActionGate();
            catch ME
                obj.setStatus(['Component error: ' ME.message]);
            end
        end

        function pickComponentChannels(obj)
            try
                assert(~isempty(obj.SourceEEG), 'NeuroQC:Source', 'Load current EEG first');
                labels = {};
                if isfield(obj.SourceEEG, 'chanlocs') && ~isempty(obj.SourceEEG.chanlocs)
                    labels = {obj.SourceEEG.chanlocs.labels};
                end
                assert(~isempty(labels), 'NeuroQC:Channels', 'No channel labels');
                if isempty(strtrim(char(obj.compField.Value)))
                    obj.newComponent();
                    return;
                end
                [~, selStr] = pop_chansel(labels);
                if isempty(selStr), return; end
                picked = parseChanselSelection(selStr);
                if isempty(picked), return; end
                specs = strsplit(obj.compField.Value, ';');
                index = 1;
                names = cellfun(@specName, specs, 'UniformOutput', false);
                if numel(specs) > 1
                    [index, ok] = listdlg('PromptString', 'Component to update:', ...
                        'ListString', names, 'SelectionMode', 'single');
                    if ~ok, return; end
                end
                obj.setComponentChannels(index, picked);
            catch ME
                obj.setStatus(['Channel pick error: ' ME.message]);
            end
        end

        function editStepInEEGLAB(obj, step)
            try
                assert(~isempty(obj.SourceEEG), 'NeuroQC:Source', 'Load current EEG first');
                assert(isKnownStep(step), 'NeuroQC:Step', 'Unknown step');
                EEGcopy = obj.captureContext(step);if isempty(EEGcopy),return;end
                com = '';
                switch lower(char(step))
                    case 'chanloc'
                        [~, ~, ~, com] = pop_chanedit(EEGcopy);
                    case 'select_data'
                        [~, com] = pop_select(EEGcopy);
                    case 'select_events'
                        [~, ~, com] = pop_selectevent(EEGcopy);
                    case 'edit_events'
                        [~, com] = pop_editeventvals(EEGcopy);
                    case 'resample'
                        [~, com] = pop_resample(EEGcopy);
                    case {'notch', 'filter'}
                        [~, com] = pop_eegfiltnew(EEGcopy);
                    case 'badchannel'
                        [~, ~, ~, com] = pop_rejchan(EEGcopy);
                    case 'reject_continuous'
                        [~, ~, ~, com] = pop_rejcont(EEGcopy);
                    case 'reref'
                        [~, com] = pop_reref(EEGcopy);
                    case 'run_ica'
                        [~, com] = pop_runica(EEGcopy);
                    case 'epoch'
                        [~, ~, com] = pop_epoch(EEGcopy);
                    case 'baseline'
                        [~, com] = pop_rmbase(EEGcopy);
                    case 'artifact_reject'
                        [~, ~, com] = pop_eegthresh(EEGcopy);
                    case 'auto_reject'
                        [~, ~, com] = pop_autorej(EEGcopy);
                    case 'reject_jointprob'
                        [~, ~, ~, ~, com] = pop_jointprob(EEGcopy);
                    case 'reject_kurtosis'
                        [~, ~, ~, ~, com] = pop_rejkurt(EEGcopy);
                    case 'remove_bad'
                        obj.setStatus('remove_bad: policy step (removes channels from badchannel detection). No dialog params; toggle fullWorkflow in Space table.');
                        return;
                    case 'interpolate'
                        obj.setStatus('interpolate: driven by badchannel detection. Set interpolate=true in Space table to enable; method fixed to spherical.');
                        return;
                    case 'restore_channels'
                        obj.setStatus('restore_channels: restores originalChanlocs from before removal. Enable fullWorkflow + interpolate in Space table.');
                        return;
                    case 'auto_ic_remove'
                        obj.setStatus('auto_ic_remove: ICLabel policy (conservative/moderate). Set icPolicy in Space table; no dialog params.');
                        return;
                    otherwise
                        obj.setStatus(sprintf('No EEGLAB dialog mapped for %s', step));
                        return;
                end
                if isempty(com)
                    obj.setStatus('EEGLAB dialog cancelled (source unchanged)');
                    return;
                end
                applied = obj.parseComIntoSpace(step, com, EEGcopy);
                if applied
                    obj.refreshSpaceTable();
                    obj.refreshParamRows();
                    obj.setStatus(sprintf('Captured %s parameters from EEGLAB', step));
                    obj.logMsg('%s <- %s', step, strtrim(com));
                else
                    obj.logMsg('Could not parse com for %s: %s', step, strtrim(com));
                    obj.setStatus('Opened EEGLAB dialog; edit values in space table manually');
                end
            catch ME
                obj.setStatus(['EEGLAB dialog error: ' ME.message]);
                obj.logMsg('%s', getReport(ME, 'basic', 'hyperlinks', 'off'));
            end
        end

        function applied = parseComIntoSpace(obj, step, com, context)
            applied = false;
            com = char(string(com));
            if nargin<4,context=obj.SourceEEG;end
            if ~captureSupported(step,com,context), return; end
            try
                switch lower(char(step))
                    case 'chanloc'
                        if ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'chanloc', struct('com',com));
                            applied = true;
                        end
                    case 'select_data'
                        if ~isempty(strtrim(com))
                            obj.Space=appendUnique(obj.Space,'selectData',struct('com',com)); applied=true;
                        end
                    case 'select_events'
                        tyTok = regexp(com, '''type''\s*,\s*\{([^}]*)\}', 'tokens', 'once');
                        if ~isempty(tyTok)
                            labs = parseQuotedList(tyTok{1});
                            if ~isempty(labs)
                                obj.Space = appendUnique(obj.Space, 'selectEvents', ...
                                    struct('types', {labs}, 'com', com));
                                applied = true;
                            end
                        elseif ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'selectEvents', ...
                                struct('com', com));
                            applied = true;
                        end
                    case 'edit_events'
                        if ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'editEvents', ...
                                struct('com', com));
                            applied = true;
                        end
                    case 'resample'
                        tok = regexp(com, 'pop_resample\s*\(\s*EEG\s*,\s*([0-9.]+)', 'tokens', 'once');
                        if ~isempty(tok)
                            v = str2double(tok{1});
                            if isfinite(v)
                                obj.Space = appendUnique(obj.Space, 'resample', v);
                                applied = true;
                            end
                        end
                    case {'filter', 'notch'}
                        args=nativeArguments(com,'pop_eegfiltnew');hp=NaN;lp=NaN;rev=false;
                        if contains(args{2},char(39))
                            for k=2:2:numel(args)
                                key=strrep(args{k},char(39),'');
                                switch key
                                    case 'locutoff',hp=str2double(args{k+1});
                                    case 'hicutoff',lp=str2double(args{k+1});
                                    case 'revfilt',rev=ismember(args{k+1},{'1','true'});
                                end
                            end
                        else
                            hp=str2double(args{2});lp=str2double(args{3});
                            if numel(args)>=5,rev=ismember(args{5},{'1','true'});end
                        end
                        if rev
                            freq=(hp+lp)/2;
                            if all(isfinite([hp lp])) && abs(lp-hp-4)<1e-9 && ismember(freq,[50 60])
                                obj.Space=appendUnique(obj.Space,'lineNoise',freq);applied=true;
                            end
                        elseif all(isfinite([hp lp])) && hp>0 && lp>hp
                            obj.Space=appendUnique(obj.Space,'highpass',hp);
                            obj.Space=appendUnique(obj.Space,'lowpass',lp);applied=true;
                        end
                    case 'reref'
                        if ~isempty(regexp(com, 'pop_reref\s*\(\s*EEG\s*,\s*\[\s*\]', 'once'))
                            obj.Space = appendUnique(obj.Space, 'reference', 'average');
                            applied = true;
                        else
                            cellTok = regexp(com, 'pop_reref\s*\(\s*EEG\s*,\s*\{([^}]*)\}', 'tokens', 'once');
                            if ~isempty(cellTok)
                                labs = parseQuotedList(cellTok{1});
                                if ~isempty(labs)
                                    obj.Space = appendUnique(obj.Space, 'reference', labs);
                                    applied = true;
                                end
                            else
                                ref = regexp(com, 'pop_reref\s*\(\s*EEG\s*,\s*''([^'']+)''', 'tokens', 'once');
                                if ~isempty(ref)
                                    obj.Space = appendUnique(obj.Space, 'reference', ref{1});
                                    applied = true;
                                end
                            end
                        end
                    case 'badchannel'
                        th = regexp(com, '''threshold''\s*,\s*([0-9.]+)', 'tokens', 'once');
                        if ~isempty(th)
                            v = str2double(th{1});
                            if isfinite(v), obj.Space = appendUnique(obj.Space, 'badChannelThreshold', v); applied = true; end
                        end
                        meth = regexp(com, '''measure''\s*,\s*''([a-zA-Z]+)''', 'tokens', 'once');
                        if ~isempty(meth)
                            m = lower(meth{1});
                            aliases=struct('kurt','kurtosis','prob','probability','spec','spectrum');
                            if isfield(aliases,m), m=aliases.(m); end
                            if any(strcmp(m, {'kurtosis','probability','spectrum'}))
                                obj.Space = appendUnique(obj.Space, 'badChannel', m);
                                applied = true;
                            else
                                % Fail closed: an explicit unsupported measure
                                % must not be silently dropped from the capture.
                                applied = false;
                            end
                        end
                    case 'reject_continuous'
                        th = regexp(com, '''threshold''\s*,\s*([0-9.]+)', 'tokens', 'once');
                        if ~isempty(th)
                            v = str2double(th{1});
                            if isfinite(v), obj.Space = appendUnique(obj.Space, 'continuousThresholdDb', v); applied = true; end
                        end
                    case 'auto_reject'
                        th = regexp(com, '''threshold''\s*,\s*([0-9.]+)', 'tokens', 'once');
                        if ~isempty(th)
                            v = str2double(th{1});
                            if isfinite(v) && v > 0
                                obj.Space = appendUnique(obj.Space, 'autoRejectThreshold', ...
                                    struct('threshold', v));
                                applied = true;
                            end
                        elseif ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'autoRejectThreshold', true);
                            applied = true;
                        end
                    case {'reject_jointprob','reject_kurtosis'}
                        fn='pop_jointprob'; dim='rejectJointprob';
                        if strcmp(step,'reject_kurtosis'), fn='pop_rejkurt';dim='rejectKurt';end
                        args=nativeArguments(com,fn);
                        if numel(args)>=5 && strcmp(strtrim(args{2}),'1')
                            lo=str2double(args{4});gl=str2double(args{5});
                            raw=strtrim(args{3}); channels=[];
                            allChannels=strcmp(raw,'1:EEG.nbchan');
                            if ~allChannels && ~isempty(regexp(raw,'^[\[\]0-9,\s]+$','once'))
                                channels=sscanf(regexprep(raw,'[\[\],]',' '),'%f')';
                            end
                            if all(isfinite([lo gl])) && lo>0 && gl>0 && (allChannels || ~isempty(channels))
                                params=struct('locthresh',lo,'globthresh',gl);
                                if ~allChannels,params.channels=channels;end
                                obj.Space=appendUnique(obj.Space,dim,params);applied=true;
                            end
                        end
                    case 'artifact_reject'
                        % pop_eegthresh(EEG,1,chans,lo,hi,...)
                        tok = regexp(com, 'pop_eegthresh\s*\([^,]+,[^,]+,[^,]+,\s*([-\d.]+)\s*,\s*([-\d.]+)', 'tokens', 'once');
                        if ~isempty(tok)
                            lo = str2double(tok{1}); hi = str2double(tok{2});
                            if isfinite(hi) && hi > 0
                                obj.Space = appendUnique(obj.Space, 'artifactThresholdUv', hi);
                                applied = true;
                            elseif isfinite(abs(lo)) && abs(lo) > 0
                                obj.Space = appendUnique(obj.Space, 'artifactThresholdUv', abs(lo));
                                applied = true;
                            end
                        end
                    case 'epoch'
                        tok = regexp(com, 'pop_epoch\s*\([^;]*?,\s*\[([^\]]+)\]', 'tokens', 'once');
                        if ~isempty(tok)
                            w = sscanf(tok{1}, '%f');
                            if numel(w) == 2
                                obj.epochField.Value = sprintf('%g %g', w(1), w(2));
                                applied = true;
                            end
                        end
                    case 'baseline'
                        tok = regexp(com, 'pop_rmbase\s*\(\s*EEG\s*,\s*\[([^\]]+)\]', 'tokens', 'once');
                        if ~isempty(tok)
                            w = sscanf(tok{1}, '%f');
                            if numel(w) == 2
                                obj.baseField.Value = sprintf('%g %g', w(1)/1000, w(2)/1000);
                                applied = true;
                            end
                        end
                    case 'remove_bad'
                        % fullWorkflow gate controls remove_bad + reject_continuous + auto_ic_remove + restore_channels
                        if ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'fullWorkflow', true);
                            applied = true;
                        end
                    case 'interpolate'
                        % interpolate dim controls both interpolate and restore_channels
                        if ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'interpolate', true);
                            applied = true;
                        end
                    case 'restore_channels'
                        % restore_channels requires both fullWorkflow and interpolate
                        if ~isempty(strtrim(com))
                            obj.Space = appendUnique(obj.Space, 'fullWorkflow', true);
                            obj.Space = appendUnique(obj.Space, 'interpolate', true);
                            applied = true;
                        end
                    case 'auto_ic_remove'
                        % policy stays discrete; ICLabel labels may appear in com
                        applied = true;
                    otherwise
                        applied = false;
                end
            catch
                applied = false;
            end
        end

        function refreshParamRows(obj)
            obj.refreshActionGate();
            if isempty(obj.paramStepList) || ~isvalid(obj.paramStepList), return; end
            selected=obj.workflowOrder();
            if ~isempty(obj.workflowList) && isvalid(obj.workflowList)
                prev=obj.workflowList.Value;obj.workflowList.Items=selected;
                if ~isempty(prev) && ismember(prev,selected),obj.workflowList.Value=prev;end
            end
            if isempty(selected)
                % Nothing chosen in Scope yet: keep the canonical list as a
                % discovery aid instead of a silently blank Params tab.
                steps=neuroqc.pipeline.StageModel.canonicalOrder();
                label='No steps selected in Scope — showing all available steps';
            else
                % Params shows ONLY the selected steps, in workflow order.
                steps=selected;
                label=sprintf('Selected %d step(s), execution order (edit in Scope)',numel(selected));
            end
            obj.paramStepList.Items = steps;
            if ~isempty(obj.paramListLabel) && isvalid(obj.paramListLabel)
                obj.paramListLabel.Text=label;
            end
            if ~isempty(obj.workflowHint)
                if obj.searchOrderCheck.Value
                    obj.workflowHint.Text='Order SEARCH: right list is a configuration view; Preview shows candidate orders.';
                elseif isempty(selected)
                    obj.workflowHint.Text='Available steps (left) | Selected workflow (right) — none selected yet';
                else
                    obj.workflowHint.Text=sprintf('Selected %d step(s) in execution order | Params shows only these',numel(selected));
                end
            end
            cur = char(string(obj.paramStepList.Value));
            if isempty(cur) || ~any(strcmp(cur, steps))
                obj.paramStepList.Value = steps{1};
            end
            obj.paramListChanged();
        end

        function stepHelp(~, step)
            fn = stepPopFunction(step);
            if ~isempty(fn) && exist('pophelp', 'file') == 2
                try
                    pophelp(fn);
                    return;
                catch
                    % fall through to msgbox
                end
            end
            if ~isempty(fn)
                msgbox(sprintf('EEGLAB function: %s\nNeuroQC exports this step as a pop_* recipe line.', fn), ...
                    ['NeuroQC - ' step]);
            else
                msgbox('No single pop_* dialog; values stay discrete in the search space.', step);
            end
        end

        function txt = stepSpacePreview(obj, step)
            m = neuroqc.pipeline.StageModel.dimensionStages();
            space = obj.effectiveSpace();
            dims = {};
            fn = fieldnames(m);
            for i = 1:numel(fn)
                if any(strcmp(m.(fn{i}), step)), dims{end+1} = fn{i}; end %#ok<AGROW>
            end
            if isempty(dims)
                txt = '(discrete / contract)';
                return;
            end
            parts = cell(1, numel(dims));
            for i = 1:numel(dims)
                d = dims{i};
                if isfield(space, d)
                    parts{i} = sprintf('%s=%s', d, obj.fmtVals(space.(d)));
                else
                    parts{i} = d;
                end
            end
            txt = strjoin(parts, '  ');
        end

        function text=stepDetails(obj,step)
            f=obj.sourceFacts();e=obj.SourceEEG;
            current='Cannot infer whether this step was completed from the current EEG alone.';
            if isempty(e)
                current='No EEG loaded. Load data in the Data tab.';
            else
                switch step
                    case 'chanloc'
                        current=sprintf('XYZ coordinates present for %d/%d channels. Existing locations are part of the input.',f.locations,f.channels);
                    case 'resample'
                        current=sprintf('Current sampling rate: %g Hz.',f.rate);
                    case 'select_data'
                        current=sprintf('%d channels; %s; %d points per trial.',f.channels,f.data,e.pnts);
                    case {'select_events','edit_events'}
                        types={};
                        for k=1:numel(e.event),types{end+1}=char(string(e.event(k).type));end %#ok<AGROW>
                        types=unique(types,'stable');
                        current=sprintf('%d events. Types: %s',f.events,strjoin(types,', '));
                    case 'run_ica'
                        current=['ICA decomposition: ' f.ica '.'];
                    case 'auto_ic_remove'
                        current=['ICA decomposition: ' f.ica '. Classification alone does not prove IC removal.'];
                    case 'epoch'
                        current=f.data;
                        if ~strcmp(f.data,'continuous'),current=sprintf('%s; epoch range [%g %g] seconds.',f.data,e.xmin,e.xmax);end
                    case 'reref'
                        if isfield(e,'ref'),current=['Stored EEG.ref: ' obj.fmtVals({e.ref}) '.'];end
                end
            end
            declared={};
            try
                [done,mode]=obj.handoffScope();declared=neuroqc.pipeline.StageModel.normalizeCompleted(done,mode);
            catch
            end
            selected=obj.selectedStepList();
            if ismember(step,declared)
                plan='Declared completed in Scope; excluded from this search. Verify this declaration against your actual history.';
            elseif ~ismember(step,selected)
                plan='Not selected in Scope. This step will not run; current input is retained.';
            else
                plan='Selected in Scope. Only the candidate settings below will be compared.';
            end
            m=neuroqc.pipeline.StageModel.dimensionStages();space=obj.effectiveSpace();lines={};
            for name=fieldnames(m)'
                d=name{1};if ~ismember(step,m.(d)) || strcmp(d,'fullWorkflow'),continue;end
                vals=space.(d);pieces={};
                for k=1:numel(vals)
                    v=vals{k};
                    if islogical(v) && isscalar(v)
                        if v,pieces{k}='Enabled candidate';
                        elseif ismember(d,{'chanloc','selectData','selectEvents','editEvents'})
                            pieces{k}='No new settings captured (input is unchanged)';
                        else,pieces{k}='Disabled candidate (no operation)';end
                    elseif isempty(v) && ismember(d,{'epochWindow','baselineWindow'})
                        if strcmp(d,'epochWindow'),w=obj.epochField.Value;else,w=obj.baseField.Value;end
                        pieces{k}=['Use Scope window: ' w ' s'];
                    else,pieces{k}=obj.fmtVals({v});end
                end
                lines{end+1}=sprintf('%s: %s',d,strjoin(pieces,' | ')); %#ok<AGROW>
            end
            text=sprintf('CURRENT INPUT — observed state\n%s\n\nTHIS RUN — your Scope selection\n%s\n\nFUTURE CANDIDATES — not input history\n%s\n\nFixed values stay fixed. Capture in EEGLAB edits a copy and adds candidates; it does not apply them to this input.', ...
                current,plan,strjoin(lines,newline));
            histLines = obj.historyLinesForStep(step);
            if ~isempty(histLines)
                text = [text newline newline sprintf('EEG.history — line(s) that map to "%s"', step) ...
                    newline strjoin(histLines, newline)];
            elseif obj.hasHistory()
                text = [text newline newline sprintf( ...
                    'EEG.history — recorded, but no line maps to "%s" for this input.', step)];
            else
                text = [text newline newline 'EEG.history — none recorded for this input.'];
            end
        end

        function tf = hasHistory(obj)
            % True when the current input carries a non-empty EEG.history.
            tf = false;
            if isempty(obj.SourceEEG) || ~isfield(obj.SourceEEG, 'history'), return; end
            h = string(obj.SourceEEG.history);
            tf = ~isempty(h) && any(strlength(strtrim(h)) > 0);
        end

        function lines = historyLinesForStep(obj, step)
            % Verbatim EEG.history lines that classify as this step.
            lines = {};
            if isempty(obj.SourceEEG) || ~isfield(obj.SourceEEG, 'history'), return; end
            h = string(obj.SourceEEG.history);
            if isempty(h) || all(strlength(strtrim(h)) == 0), return; end
            ls = splitlines(h);
            step = char(step);
            for k = 1:numel(ls)
                ln = strtrim(char(ls(k)));
                if isempty(ln), continue; end
                if strcmp(neuroqc.gui.CheckpointDialog.classifyCom(ln), step)
                    lines{end+1} = sprintf('%3d| %s', k, ln); %#ok<AGROW>
                end
            end
        end

        function [hdr, rows, raw, steps, nLines, nMapped] = historyReport(obj)
            % EEG.history as recorded plus its per-line step mapping.
            % Unmapped lines are listed verbatim instead of being dropped.
            h = '';
            if ~isempty(obj.SourceEEG) && isfield(obj.SourceEEG, 'history')
                h = string(obj.SourceEEG.history);
            end
            rows = cell(0, 3); raw = ''; nLines = 0; nMapped = 0;
            if isempty(h) || all(strlength(strtrim(h)) == 0)
                raw = '(EEG.history is empty for this input)';
            else
                raw = char(h);
                ls = splitlines(h);
                for k = 1:numel(ls)
                    ln = strtrim(char(ls(k)));
                    if isempty(ln), continue; end
                    nLines = nLines + 1;
                    step = neuroqc.gui.CheckpointDialog.classifyCom(ln);
                    if isempty(step)
                    note = 'not mapped (kept verbatim)';
                    else
                        note = ['-> ' step]; nMapped = nMapped + 1;
                    end
                    rows(end+1, :) = {k, ln, note}; %#ok<AGROW>
                end
            end
            steps = neuroqc.gui.CheckpointDialog.parseHistory(h);
            completed = '';
            if ~isempty(obj.completedField) && isvalid(obj.completedField)
                completed = char(obj.completedField.Value);
            end
            if isempty(completed), completed = '(empty)'; end
            hdr = sprintf([ ...
                'EEG.history as recorded: %d non-empty line(s), %d mapped to a NeuroQC step, %d not mapped.\n' ...
                'Ordered steps parsed: %s\nCurrent Completed set: %s'], ...
                nLines, nMapped, nLines - nMapped, strjoin(steps, ', '), completed);
        end

        function showHistory(obj)
            % Full EEG.history as recorded, plus per-line step mapping.
            % Nothing is dropped silently: unmapped lines are listed as-is.
            try
                assert(~isempty(obj.SourceEEG), 'NeuroQC:Source', 'Load a dataset first');
                [hdr, rows, raw, ~, nLines, nMapped] = obj.historyReport();
                f = figure('Name', 'EEG.history', 'NumberTitle', 'off', 'MenuBar', 'none', ...
                    'ToolBar', 'none', 'Color', [.93 .96 1], 'Position', [180 120 1040 640]);
                gl = uigridlayout(f, [3 1]);
                gl.RowHeight = {64, '1x', '1x'}; gl.Padding = [8 8 8 8];
                uilabel(gl, 'Text', hdr, 'WordWrap', 'on', 'HorizontalAlignment', 'left', ...
                    'VerticalAlignment', 'top', 'FontColor', [0 0 0.4]);
                uitextarea(gl, 'Value', cellstr(splitlines(string(raw))), ...
                    'Editable', 'off', 'FontName', 'Courier', 'FontSize', 11);
                uitable(gl, 'Data', rows, ...
                    'ColumnName', {'Line', 'History line (verbatim)', 'NeuroQC mapping'}, ...
                    'ColumnEditable', [false false false], ...
                    'ColumnWidth', {50, 620, 220});
                obj.logMsg('History view: %d line(s), %d mapped step(s), %d unmapped.', ...
                    nLines, nMapped, nLines - nMapped);
            catch ME
                obj.setStatus(['History: ' ME.message]);
                obj.logMsg('%s', ME.message);
            end
        end

        function [lim, errs] = constraintLimits(obj)
            % Scope Constraints -> contract.qualityThresholds.
            % Empty field = built-in HardConstraints default (omitted here).
            lim = struct(); errs = {};
            cf = obj.constraintFields;
            if isempty(cf) || ~isstruct(cf), return; end
            nums = {'maxDistortion','minRetention','maxInterpRatio','maxBadRatio', ...
                'maxConditionRetentionSpread','minRank'};
            for k = 1:numel(nums)
                f = nums{k};
                if ~isfield(cf, f) || isempty(cf.(f)), continue; end
                h = cf.(f);
                if ~isvalid(h), continue; end
                raw = strtrim(char(h.Value));
                if isempty(raw), continue; end
                v = str2double(raw);
                if ~isscalar(v) || ~isfinite(v)
                    errs{end+1} = sprintf('Constraint %s must be a number (got "%s")', f, raw); %#ok<AGROW>
                    continue;
                end
                lim.(f) = v;
            end
            if isfield(cf, 'allowEventLoss') && ~isempty(cf.allowEventLoss) && isvalid(cf.allowEventLoss)
                raw = strtrim(char(cf.allowEventLoss.Value));
                if ~isempty(raw)
                    v = str2double(raw);
                    if ~isscalar(v) || ~isfinite(v) || (v ~= 0 && v ~= 1)
                        errs{end+1} = sprintf('Constraint allowEventLoss must be 0 or 1 (got "%s")', raw); %#ok<AGROW>
                    else
                        lim.allowEventLoss = logical(v);
                    end
                end
            end
        end

        function ok=buildContract(obj)
            ok=false;obj.Contract=[];
            try
                c = neuroqc.contract.AnalysisContract();
                c.paradigm = 'custom';
                rawCond = strtrim(obj.condField.Value);
                assert(~isempty(rawCond), 'NeuroQC:Contract', ...
                    'Provide conditions (Select events… or name:code list)');
                parts = strsplit(rawCond, ',');
                nAdded = 0;
                for i = 1:numel(parts)
                    part = strtrim(parts{i});
                    if isempty(part), continue; end
                    kv = strsplit(part, ':');
                    if numel(kv) == 2 && ~isempty(strtrim(kv{1})) && ~isempty(strtrim(kv{2}))
                        c = c.addCondition(strtrim(kv{1}), {strtrim(kv{2})}, strtrim(kv{1}));
                        nAdded = nAdded + 1;
                    elseif numel(kv) == 1 && ~isempty(part)
                        % bare event code
                        c = c.addCondition(['event_' part], {part}, 'event');
                        nAdded = nAdded + 1;
                    else
                        error('NeuroQC:Contract','Invalid condition: %s',part);
                    end
                end
                assert(nAdded > 0, 'NeuroQC:Contract', ...
                    'No conditions parsed from Events (use Select events… or name:code)');
                ew = strictWindow(obj.epochField.Value,'Epoch');
                bw = strictWindow(obj.baseField.Value,'Baseline');
                assert(bw(1)>=ew(1) && bw(2)<=ew(2),'NeuroQC:Contract','Baseline must lie within the epoch');
                c = c.setEpoch(ew(1), ew(2)); c = c.setBaseline(bw(1), bw(2));
                rawComp = strrep(strrep(obj.compField.Value, '；', ';'), '：', ':');
                rawComp = strrep(rawComp, '，', ',');
                specs = strsplit(rawComp, ';');
                for si = 1:numel(specs)
                    spec = strtrim(specs{si});
                    if isempty(spec), continue; end
                    name = sprintf('component%d', si);
                    ctype = 'mean';
                    tok = strsplit(spec, ':');
                    knownTypes = {'mean','peak','negative','positive'};
                    if numel(tok) > 1 && any(strcmpi(strtrim(tok{end}), knownTypes))
                        ctype = lower(strtrim(tok{end}));
                        tok(end) = [];
                    end
                    if numel(tok) == 2
                        name = strtrim(tok{1}); spec = strtrim(tok{2});
                    elseif numel(tok) > 2
                        name = strtrim(tok{1}); spec = strtrim(strjoin(tok(2:end), ':'));
                    end
                    assert(~isempty(name), 'NeuroQC:Contract', ...
                        'Component %d needs a name before the ":"', si);
                    wtok = strsplit(spec, '@');
                    assert(numel(wtok) == 2, 'NeuroQC:Contract', ...
                        'Component format: name:start end @ channel,channel[:type] (got %d @ in "%s"; separate multiple components with ;)', ...
                        numel(wtok) - 1, strtrim(specs{si}));
                    ww = strictWindow(strtrim(wtok{1}),['Component ' name]);
                    chans = cellfun(@strtrim, strsplit(strtrim(wtok{2}), ','), 'UniformOutput', false);
                    chans = chans(~cellfun(@isempty, chans));
                    assert(numel(ww) == 2 && ww(1) < ww(2), 'NeuroQC:Contract', ...
                        'Invalid component window in "%s": need two increasing times', strtrim(specs{si}));
                    assert(~isempty(chans) && ww(1)>=ew(1) && ww(2)<=ew(2),'NeuroQC:Contract','Component needs channels and a window inside the epoch');
                    c = c.addComponent(name, ww(:)', chans, ctype);
                end
                % Components optional at generate time; Compare will prompt if empty.
                assert(~isempty(c.conditions), 'NeuroQC:Contract', 'Provide conditions');
                [lim, limErrs] = obj.constraintLimits();
                assert(isempty(limErrs), 'NeuroQC:Contract', '%s', strjoin(limErrs, '; '));
                c.qualityThresholds = lim;
                ok=true;
                if isempty(c.components)
                    obj.Contract = c;
                    assignin('base', 'neuroqc_contract', c);
                    obj.setStatus('Contract built (no components yet — Compare will ask)');
                    obj.logMsg('Contract conditions: %s; components empty', strjoin({c.conditions.name}, ', '));
                    return;
                end
                obj.Contract = c;
                assignin('base', 'neuroqc_contract', c);
                obj.setStatus('Contract built');
                obj.logMsg('Contract conditions: %s; components: %s', ...
                    strjoin({c.conditions.name}, ', '), strjoin({c.components.name}, ', '));
            catch ME
                obj.setStatus(['Contract error: ' ME.message]);
                obj.logMsg('%s', ME.message);
            end
        end

        function ensureComponentsForCompare(obj)
            assert(obj.buildContract(),'NeuroQC:Contract','Correct the highlighted contract error before comparing');
            if ~isempty(obj.Contract) && ~isempty(obj.Contract.components)
                return;
            end
            % No component yet: ask the user (any name, channels from data).
            obj.newComponent();
            if isempty(obj.Contract)
                obj.buildContract();
            end
            assert(~isempty(obj.Contract) && ~isempty(obj.Contract.components), ...
                'NeuroQC:Contract', 'Components required for Compare');
        end

        function handoffModeChanged(obj)
            useSet = strcmp(obj.handoffDD.Value, 'set');
            if useSet
                obj.stageDD.Enable = 'off';
                obj.completedField.Enable = 'on';
            else
                obj.stageDD.Enable = 'on';
                obj.completedField.Enable = 'off';
                obj.setStatus('Prefix mode declares EVERY canonical step through Start after completed. Use exact set for partial manual work.');
            end
            obj.refreshSpaceTable();
        end

        function adoptCheckpoint(obj)
            % Read neuroqc_checkpoint from base and set Handoff/Completed set.
            if ~evalin('base', 'exist(''neuroqc_checkpoint'',''var'')')
                obj.setStatus('No neuroqc_checkpoint in base; run Checkpoint... first');
                return;
            end
            cp = evalin('base', 'neuroqc_checkpoint');
            if ~neuroqc.gui.CheckpointDialog.matchesSource(cp,obj.SourceEEG)
                obj.setStatus('Checkpoint belongs to another or changed EEG; create a new checkpoint');
                return;
            end
            if isempty(cp.steps)
                obj.setStatus('Checkpoint has no steps');
                return;
            end
            steps = cp.steps;
            % Check if steps form a canonical prefix (prefix handoff)
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            idx = false(1, numel(steps));
            for i = 1:numel(steps)
                idx(i) = ismember(steps{i}, known);
            end
            if ~all(idx)
                obj.setStatus('Checkpoint has unknown steps; use exact set');
                obj.handoffDD.Value = 'set';
                obj.completedField.Value = strjoin(steps, ',');
                obj.handoffModeChanged();
                obj.logMsg('Adopted checkpoint as exact set: %s', strjoin(steps, ','));
                return;
            end
            % Find max canonical index
            maxIdx = 0;
            for i = 1:numel(steps)
                step = steps{i};
                pos = find(strcmp(known, step), 1);
                if ~isempty(pos) && pos > maxIdx, maxIdx = pos; end
            end
            if maxIdx == numel(steps) && maxIdx > 0
                % Perfect prefix
                obj.handoffDD.Value = 'prefix';
                obj.stageDD.Value = known{maxIdx};
            else
                % Not a clean prefix
                obj.handoffDD.Value = 'set';
                obj.completedField.Value = strjoin(steps, ',');
            end
            obj.handoffModeChanged();
            obj.logMsg('Adopted checkpoint: %s (%s mode)', strjoin(steps, ','), obj.handoffDD.Value);
            obj.setStatus(sprintf('Checkpoint adopted: %d steps', numel(steps)));
        end

        function [completed, orderMode] = handoffScope(obj)
            if strcmp(obj.handoffDD.Value, 'set')
                raw = strtrim(obj.completedField.Value);
                if isempty(raw)
                    completed = {};
                    orderMode = 'set';
                else
                    completed = cellfun(@strtrim, strsplit(raw, ','), 'UniformOutput', false);
                    completed = completed(~cellfun(@isempty, completed));
                    orderMode = 'set';
                end
            else
                if strcmp(obj.stageDD.Value, 'raw')
                    completed = {};
                else
                    completed = {obj.stageDD.Value};
                end
                orderMode = 'prefix';
            end
        end

        function refreshSpaceTable(obj)
            obj.refreshActionGate();
            if isempty(obj.spaceTable) || ~isvalid(obj.spaceTable), return; end
            shown=obj.effectiveSpace(); frozen={};
            [completed, orderMode] = obj.handoffScope();
            if ~isempty(completed)
                [shown,locked]=neuroqc.pipeline.StageModel.applyCompleted( ...
                    shown,completed,struct(),orderMode);
                frozen=locked.collapsedDimensions;
            end
            selected = obj.selectedStepList();
            if ~isempty(selected)
                dm=neuroqc.pipeline.StageModel.dimensionStages(); shown.fullWorkflow={true};
                for ff=fieldnames(dm)'
                    field=ff{1};
                    if isempty(intersect(dm.(field),selected)) || strcmp(field,'fullWorkflow')
                        if isfield(shown, field)
                            shown.(field)=shown.(field)(1); frozen{end+1}=field;
                        end
                    end
                end
            end
            fn = fieldnames(obj.Space);
            data = cell(numel(fn), 4);
            for i = 1:numel(fn)
                name = fn{i};
                vals = obj.Space.(name);
                n = numel(vals);
                mode = 'SEARCH'; if n==1,mode='FIXED';end
                if isfield(obj.LockSpec, name)
                    mode = 'LOCKED';
                    n = 1;
                    vals = {obj.LockSpec.(name)};
                end
                if ismember(name,frozen)
                    % Not locked by you: the step is declared completed or
                    % absent from Scope, so the input value is carried through.
                    mode='FROZEN'; n=1; vals={'kept from input (step completed or not in Scope)'};
                end
                data{i,1} = name;
                data{i,2} = obj.fmtVals(vals);
                data{i,3} = mode;
                data{i,4} = n;
            end
            obj.spaceTable.Data = data;
            if ~isempty(obj.comboLabel) && isvalid(obj.comboLabel)
                obj.comboLabel.Text = sprintf('Grid: %d',prod(cellfun(@numel,struct2cell(shown))));
            end
            if ~isempty(obj.spaceDlgTable) && isvalid(obj.spaceDlgTable)
                obj.spaceDlgTable.Data = data;
            end
            if ~isempty(obj.spaceDlgInfo) && isvalid(obj.spaceDlgInfo)
                obj.spaceDlgInfo.Text = obj.comboLabel.Text;
            end
            obj.refreshParamRows();
        end

        function s = fmtVals(~, vals)
            if ~iscell(vals), vals = {vals}; end
            parts = cell(1, numel(vals));
            for k = 1:numel(vals)
                v = vals{k};
                if isempty(v)
                    parts{k} = '[]';
                elseif isnumeric(v) || islogical(v)
                    parts{k} = mat2str(v);
                elseif iscell(v)
                    parts{k} = ['{' strjoin(cellfun(@(x) char(string(x)), v, 'UniformOutput', false), ',') '}'];
                elseif isstruct(v)
                    if isfield(v, 'com')
                        parts{k} = char(v.com);      % captured EEGLAB command
                    else
                        parts{k} = sprintf('[struct %dx%d]', size(v,1), size(v,2));
                    end
                else
                    parts{k} = char(string(v));
                end
            end
            s = strjoin(parts, ' | ');
            if numel(s) > 120
                s = [s(1:117) '...'];
            end
        end

        function lockSelected(obj)
            [tbl, row] = obj.dialogOrHostTable();
            if isempty(row), obj.setStatus('Select a dimension to lock'); return; end
            name = tbl.Data{row(1), 1};
            vals = obj.Space.(name);
            labels=cellfun(@(v) obj.fmtVals({v}),vals,'UniformOutput',false);
            [ix,ok]=listdlg('PromptString',['Lock ' name],'ListString',labels,'SelectionMode','single');
            if ~ok, return; end
            obj.LockSpec.(name)=vals{ix};
            obj.refreshSpaceTable();
            obj.logMsg('Locked %s = %s', name, obj.fmtVals({obj.LockSpec.(name)}));
        end

        function unlockSelected(obj)
            [tbl, row] = obj.dialogOrHostTable();
            if isempty(row), obj.setStatus('Select a dimension to unlock'); return; end
            name = tbl.Data{row(1), 1};
            if isfield(obj.LockSpec, name)
                obj.LockSpec = rmfield(obj.LockSpec, name);
            end
            obj.refreshSpaceTable();
            obj.logMsg('Unlocked %s', name);
        end

        function lockStep(obj)
            % Lock every free dimension owned by one step (fullWorkflow is a
            % shared gate derived from selected steps, never locked here).
            m = neuroqc.pipeline.StageModel.dimensionStages();
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            lockable = {};
            for s = 1:numel(known)
                dims = stepOwnedDims(m, known{s}, obj.Space);
                if ~isempty(dims), lockable{end+1} = known{s}; end %#ok<AGROW>
            end
            if isempty(lockable)
                obj.setStatus('No step owns a lockable dimension in this space');
                return;
            end
            [ix, ok] = listdlg('PromptString', 'Lock all free dimensions of step:', ...
                'ListString', lockable, 'SelectionMode', 'single');
            if ~ok, return; end
            step = lockable{ix};
            dims = stepOwnedDims(m, step, obj.Space);
            n = 0;
            for i = 1:numel(dims)
                d = dims{i};
                if isfield(obj.LockSpec, d), continue; end
                vals = obj.Space.(d);
                if numel(vals) == 1
                    obj.LockSpec.(d) = vals{1};
                else
                    labels = cellfun(@(v) obj.fmtVals({v}), vals, 'UniformOutput', false);
                    [iv, okv] = listdlg('PromptString', sprintf('Lock %s for %s', d, step), ...
                        'ListString', labels, 'SelectionMode', 'single');
                    if ~okv
                        obj.logMsg('Lock step %s: cancelled at %s', step, d);
                        break;
                    end
                    obj.LockSpec.(d) = vals{iv};
                end
                n = n + 1;
            end
            obj.refreshSpaceTable();
            if n > 0
                obj.logMsg('Locked step %s: %d dimension(s)', step, n);
                obj.setStatus(sprintf('Locked %s (%d dimension(s))', step, n));
            else
                obj.setStatus(sprintf('%s: no free dimension to lock', step));
            end
        end

        function unlockStep(obj)
            if isempty(fieldnames(obj.LockSpec))
                obj.setStatus('Nothing is locked');
                return;
            end
            m = neuroqc.pipeline.StageModel.dimensionStages();
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            steps = {};
            locked = fieldnames(obj.LockSpec);
            for s = 1:numel(known)
                for i = 1:numel(locked)
                    d = locked{i};
                    if isfield(m, d) && any(strcmp(m.(d), known{s}))
                        steps{end+1} = known{s}; %#ok<AGROW>
                        break;
                    end
                end
            end
            if isempty(steps)
                obj.setStatus('Locked dimensions are not owned by a step; use Unlock');
                return;
            end
            [ix, ok] = listdlg('PromptString', 'Unlock all pinned dimensions of step:', ...
                'ListString', steps, 'SelectionMode', 'single');
            if ~ok, return; end
            step = steps{ix};
            removed = {};
            locked = fieldnames(obj.LockSpec);
            for i = 1:numel(locked)
                d = locked{i};
                if isfield(m, d) && any(strcmp(m.(d), step))
                    obj.LockSpec = rmfield(obj.LockSpec, d);
                    removed{end+1} = d; %#ok<AGROW>
                end
            end
            obj.refreshSpaceTable();
            if ~isempty(removed)
                obj.logMsg('Unlocked step %s (%s)', step, strjoin(removed, ','));
                obj.setStatus(sprintf('Unlocked %s', step));
            else
                obj.setStatus(sprintf('%s has no locked dimension', step));
            end
        end

        function [tbl, row] = dialogOrHostTable(obj)
            % Prefer the visible Space table dialog; fall back to hidden host.
            tbl = obj.spaceTable; row = [];
            if ~isempty(obj.spaceDlgTable) && isvalid(obj.spaceDlgTable) ...
                    && ~isempty(obj.spaceDlg) && isvalid(obj.spaceDlg)
                tbl = obj.spaceDlgTable;
            end
            if ~isempty(tbl) && isvalid(tbl)
                row = tbl.Selection;
            end
        end

        function syncGoal(obj)
            name = char(obj.goalDD.Value);
            if strcmp(name, 'custom')
                % Custom weights: keep the balanced objective set and let the
                % Weights field supply the numbers.
                p = neuroqc.optimize.GoalProfile.balanced();
                p.name = 'custom';
            else
                p = neuroqc.optimize.GoalProfile.resolve(name);
            end
            obj.GoalProfile = p;
            w=[];if ~isempty(strtrim(obj.wField.Value)),w=str2double(regexp(strtrim(obj.wField.Value),'\s+','split'));end
            assert(all(isfinite(w)) && all(w>=0),'NeuroQC:GoalWeights','Weights must be finite nonnegative numbers');
            if numel(w) == numel(obj.GoalProfile.objectives)
                for k = 1:numel(w)
                    obj.GoalProfile.objectives(k).weight = w(k);
                end
            elseif ~isempty(w)
                error('NeuroQC:GoalWeights','Expected %d weights, got %d',numel(obj.GoalProfile.objectives),numel(w));
            end
            obj.GoalProfile.enablePreservationObjectives = false;
            obj.GoalProfile.validate();
        end

        function space = effectiveSpace(obj)
            space = obj.Space;
            fn = fieldnames(obj.LockSpec);
            for i = 1:numel(fn)
                space.(fn{i}) = {obj.LockSpec.(fn{i})};
            end
        end

        function opts = assembleScopeOptions(obj)
            % Scope/order/lock options shared by Preview and Generate so the
            % two can never disagree. GUI inputs always overwrite loaded
            % options; an empty input explicitly CLEARS a stale value.
            assert(obj.InputSettingsVerified,'NeuroQC:InputReview','Verify imported source-specific settings using Confirm input settings');
            opts = obj.ExtraOptions;
            if strcmp(obj.trialMode.Value,'choose') && isfield(opts,'trialSelection'),opts=rmfield(opts,'trialSelection');end
            [completed, orderMode] = obj.handoffScope();
            opts.completedStages = completed;
            opts.orderMode = orderMode;
            steps = obj.selectedStepList();
            assert(~isempty(steps),'NeuroQC:ScopeRequired', ...
                'Select the next steps to compare (Only steps)');
            opts.selectedSteps = steps;
            opts.searchOrder = obj.searchOrderCheck.Value;

            rawOrder=strtrim(obj.stepOrderField.Value);
            if isempty(rawOrder)
                if isfield(opts,'stepOrder')
                    opts=rmfield(opts,'stepOrder');
                    obj.logMsg('Scope: cleared stale stepOrder from loaded options');
                end
            else
                opts.stepOrder=cellfun(@strtrim,strsplit(rawOrder,','),'UniformOutput',false);
            end

            rawSlots=strtrim(obj.fixedPosField.Value);
            if isempty(rawSlots)
                if isfield(opts,'fixedPositions')
                    opts=rmfield(opts,'fixedPositions');
                    obj.logMsg('Scope: cleared stale fixedPositions from loaded options');
                end
            else
                assert(opts.searchOrder,'NeuroQC:Config', ...
                    'Fixed slots requires the Search unfixed order checkbox');
                opts.fixedPositions=neuroqc.pipeline.StageModel.parseFixedSlots(rawSlots,steps);
            end

            rawMax=strtrim(obj.maxOrdersField.Value);
            if isempty(rawMax)
                if isfield(opts,'maxOrders')
                    opts=rmfield(opts,'maxOrders');
                    obj.logMsg('Scope: cleared stale maxOrders from loaded options');
                end
            else
                maxV=str2double(rawMax);
                assert(isfinite(maxV) && maxV>=1 && maxV==fix(maxV),'NeuroQC:Config', ...
                    'Max orders must be a positive integer');
                opts.maxOrders=maxV;
            end

            opts.lockSpec=obj.LockSpec;
            opts.useParallel=obj.useParallelCheck.Value;

            % Provenance captured by Capture last action... travels with the run
            % (exported as recipe header comments; never re-executed).
            hasCkpt=false;
            try, hasCkpt=evalin('base','exist(''neuroqc_checkpoint'',''var'')'); catch, end
            if hasCkpt
                try
                    ck=evalin('base','neuroqc_checkpoint');
                    if neuroqc.gui.CheckpointDialog.matchesSource(ck,obj.SourceEEG) && isfield(ck,'preHandoffCommands') && ~isempty(ck.preHandoffCommands)
                        opts.preHandoffCommands=ck.preHandoffCommands;
                    elseif isfield(opts,'preHandoffCommands')
                        opts=rmfield(opts,'preHandoffCommands');
                    end
                catch
                end
            elseif isfield(opts,'preHandoffCommands')
                opts=rmfield(opts,'preHandoffCommands');
            end
        end

        function runSearch(obj)
            obj.runBtn.Enable='off';
            cleanup=onCleanup(@() obj.refreshActionGate()); %#ok<NASGU>
            try
                obj.autoLoadCurrentSet(true);
                assert(~isempty(obj.SourceEEG),'NeuroQC:Source','Load EEG first');
                assert(~strcmp(obj.unitDD.Value,'choose'),'NeuroQC:DataUnitRequired', ...
                    'Choose the data unit (uV or V) on the Data tab first');
                assert(obj.buildContract(),'NeuroQC:Contract','Invalid analysis settings; no recipes generated'); obj.syncGoal();
                assert(~isempty(obj.Contract),'NeuroQC:Contract','Contract build failed');
                outDir=obj.outField.Value;
                if isempty(outDir)
                    outDir=fullfile(pwd,['neuroqc_recipes_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
                    obj.outField.Value=outDir;
                elseif isfolder(outDir)
                    entries=dir(outDir);
                    names={entries.name};
                    names=names(~ismember(names,{'.','..'}));
                    if ~isempty(names)
                        outDir=[outDir '_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))];
                        obj.outField.Value=outDir;
                        obj.logMsg('Output dir non-empty; using %s',outDir);
                    end
                end
                obj.refreshSpaceTable();
                opts=obj.assembleScopeOptions();
                switch obj.trialMode.Value
                    case 'existing selection', opts.trialSelection=struct('mode','existing');
                    case 'already screened: all', opts.trialSelection=struct('mode','all');
                    case 'loaded options JSON', assert(isfield(opts,'trialSelection'),'NeuroQC:TrialRule','Options file has no trialSelection');
                end
                opts.dataUnit=obj.unitDD.Value;
                opts.outputDir=outDir;
                opts.goalProfile=obj.GoalProfile;
                qcPath=strtrim(obj.qcField.Value);
                if ~isempty(qcPath)
                    opts.externalQC=qcPath;
                elseif isfield(opts,'externalQC')
                    opts=rmfield(opts,'externalQC');
                    obj.logMsg('Scope: cleared stale externalQC from loaded options');
                end
                if ~isempty(opts.completedStages)
                    obj.logMsg('Handoff completed set (%s): %s',opts.orderMode,strjoin(opts.completedStages,', '));
                end
                space=obj.effectiveSpace(); assignin('base','neuroqc_space',space);
                obj.setStatus('Generating discrete recipes (no EEG processing)...');
                if ~isempty(opts.completedStages)
                    obj.Results=neuroqc.pipeline.ResumeOptimizer.run( ...
                        obj.SourceEEG,obj.Contract,space,opts);
                else
                    obj.Results=neuroqc.advice.RecommendPath.run( ...
                        obj.SourceEEG,obj.Contract,space,opts);
                end
                obj.GeneratedOptions=opts;obj.GenerationState=obj.configurationState();
                obj.writeOptionsSnapshot(opts,outDir);
                obj.saveSession(fullfile(outDir,'wizard_session.mat'),false);
                assignin('base','neuroqc_out',obj.Results);
                obj.showResults(); obj.setStatus(sprintf('Done: %d recipes; %s',numel(obj.Results.pipelines),obj.Results.status));
                obj.logMsg('Recipes: %s',obj.Results.recipesDir);
                selectTab(obj, 4);
            catch ME
                obj.setStatus(['Error: ' ME.message]); obj.logMsg('%s',getReport(ME,'basic','hyperlinks','off'));
            end
        end

        function compareCandidates(obj,allScoped)
            try
                assert(~isempty(obj.Results),'NeuroQC:CandidatesRequired','Generate recipes first');
                obj.ensureComponentsForCompare();obj.assertCurrentConfiguration();
                if allScoped
                    ix=setdiff(1:numel(obj.Results.pipelines),neuroqc.advice.CandidateSession.tested(obj.Results),'stable');
                    if isempty(ix),obj.setStatus('All candidates have been tried. Use Retry failed for execution failures.');return;end
                else
                    selection=obj.resultTable.Selection;
                    assert(~isempty(selection),'NeuroQC:CandidatesRequired','Select candidate rows first');
                    ix=unique(selection(:,1))';
                end
                if ~isempty(obj.GenerationState),obj.GenerationState.compField=obj.compField.Value;end
                obj.saveSession(fullfile(obj.Results.outputDir,'wizard_session.mat'),false);
                obj.setStatus('EEGLAB is trying scoped candidates on copies...');
                obj.Results=neuroqc.advice.CandidateSession.compare(obj.Results,obj.SourceEEG,obj.Contract,[],ix);
                if ~isempty(obj.GenerationState),obj.GenerationState.compField=obj.compField.Value;end
                assignin('base','neuroqc_out',obj.Results); obj.showResults();
                obj.setStatus(sprintf('Compared %d candidates; %s. Inspect before adoption.',numel(ix),obj.Results.status));
                for k=1:numel(obj.Results.trialFailures), obj.logMsg('%s: %s',obj.Results.trialFailures(k).id,obj.Results.trialFailures(k).message); end
            catch ME, obj.setStatus(ME.message); obj.logMsg('%s',getReport(ME,'basic','hyperlinks','off')); end
        end

        function rerankCandidates(obj)
            try
                assert(~isempty(obj.Results) && isfield(obj.Results,'pipelines'), ...
                    'NeuroQC:CandidatesRequired','Generate recipes first');
                obj.assertCurrentConfiguration();
                assert(obj.buildContract(),'NeuroQC:Contract', ...
                    'Correct the highlighted contract error before re-ranking');
                obj.setStatus('Re-ranking evaluated candidates with the current Constraints...');
                obj.Results = neuroqc.advice.CandidateSession.rerank(obj.Results, obj.Contract);
                assignin('base','neuroqc_out',obj.Results);
                obj.showResults();
                obj.logMsg('Re-rank limits: %s', jsonencode(obj.Contract.qualityThresholds));
                obj.setStatus(sprintf('Re-ranked without reprocessing candidates; status %s.', obj.Results.status));
            catch ME
                obj.setStatus(ME.message); obj.logMsg('%s',getReport(ME,'basic','hyperlinks','off'));
            end
        end

        function adoptCandidate(obj)
            try
                selection=obj.resultTable.Selection;
                assert(~isempty(selection) && numel(unique(selection(:,1)))==1,'NeuroQC:Candidate','Select exactly one candidate row');
                EEG=neuroqc.advice.CandidateSession.loadCandidate(obj.Results,selection(1,1));
                if evalin('base','exist(''ALLEEG'',''var'')'), ALLEEG=evalin('base','ALLEEG'); else, ALLEEG=[]; end
                [ALLEEG,EEG,CURRENTSET]=eeg_store(ALLEEG,EEG,0);
                assignin('base','ALLEEG',ALLEEG); assignin('base','EEG',EEG); assignin('base','CURRENTSET',CURRENTSET);
                evalin('base','eeglab redraw'); obj.setStatus('Candidate loaded as a NEW EEGLAB dataset (REVIEW). Original retained.');
            catch ME, obj.setStatus(ME.message); end
        end

        function importQC(obj)
            try
                assert(~isempty(obj.Results),'NeuroQC:NoRecommend','Generate in this window first');
                obj.assertCurrentConfiguration();out=obj.Results;
                path=strtrim(obj.qcField.Value);
                if isempty(path)
                    [f,p]=uigetfile({'*.csv;*.json','QC files (*.csv,*.json)'},'Import external QC');
                    if isequal(f,0), return; end
                    path=fullfile(p,f); obj.qcField.Value=path;
                end
                contract=obj.Contract; if isempty(contract), contract=[]; end
                obj.syncGoal();
                out=neuroqc.advice.RecommendPath.applyExternalQC(out,path,contract,obj.GoalProfile);
                neuroqc.advice.RecommendPath.writeSummary(out,out.outputDir,contract,obj.effectiveSpace(),struct());
                assignin('base','neuroqc_out',out); obj.Results=out;
                obj.showResults(); obj.setStatus(sprintf('QC imported: %s',out.status));
            catch ME, obj.setStatus(['Error: ' ME.message]); obj.logMsg('%s',ME.message); end
        end

        function previewRemaining(obj)
            try
                obj.autoLoadCurrentSet(true);
                assert(~isempty(obj.SourceEEG),'NeuroQC:Source','Load current EEG first');
                assert(obj.buildContract(),'NeuroQC:Contract','Invalid analysis settings');
                info=neuroqc.io.EEGImporter.fromEEG(obj.SourceEEG);
                info=neuroqc.advice.RecommendPath.prepareInfo(info,obj.ExtraOptions);
                % Same option assembly as Generate (incl. fixed slots/maxOrders),
                % so Preview counts can never disagree with what will be built.
                genOpts=obj.assembleScopeOptions();
                [previewPipelines,r]=neuroqc.pipeline.ExhaustiveSearch.generate(obj.effectiveSpace(),info,obj.Contract,genOpts);
                budgetTxt='';
                if isfield(r,'budget')
                    b=r.budget;
                    budgetTxt=sprintf(' | Budget: %s',b.verdict);
                    obj.logMsg('Budget [%s]: effective <= %d pipelines | recipes ~%.1f MB | eval ~%.1f h', ...
                        b.verdict,b.effectiveEstimatePipelines,b.estimatedRecipeMB,b.estimatedEvalHours);
                    obj.logMsg('Budget assumptions: %s',b.assumptions);
                end
                if ~isempty(obj.comboLabel) && isvalid(obj.comboLabel)
                    obj.comboLabel.Text=sprintf('Grid: %d | Valid: %d%s',r.totalCombinations,r.validPipelines,budgetTxt);
                end
                prefix='';
                if isfield(r,'budget') && strcmp(r.budget.verdict,'exceeds')
                    prefix='Budget EXCEEDS guidelines — consider opts.maxPipelines sampling or fewer dimensions. ';
                end
                obj.setStatus([prefix sprintf('Preview: %d parameter combinations; %d legal candidates; %d rejected. See Log for orders/reasons.',r.parameterCombinations,r.validPipelines,r.invalidCombinations)]);
                for pi=1:min(20,numel(previewPipelines)),obj.logMsg('Order %d: %s',pi,strjoin({previewPipelines(pi).steps.type},' > '));end
                for ri=1:min(20,numel(r.rejections)),obj.logMsg('Excluded: %s',r.rejections(ri).reason);end
                obj.logMsg('Remaining combinations=%d; valid=%d; invalid=%d; duplicate=%d',r.totalCombinations,r.validPipelines,r.invalidCombinations,r.duplicateCombinations);
                if ~isempty(r.completedStages), obj.logMsg('Completed set: %s',strjoin(r.completedStages,', ')); end
                if ~isempty(r.stepOrder), obj.logMsg('Step order: %s',strjoin(r.stepOrder,', ')); end
                if isfield(r,'rejectedOrderCombinations') && r.rejectedOrderCombinations>0
                    obj.logMsg('Rejected orders (dependencies/pins): %d',r.rejectedOrderCombinations);
                end
            catch ME
                obj.setStatus(['Preview: ' ME.message]);
                obj.logMsg('%s',ME.message);
            end
        end

        function goalChanged(obj)
            name = char(obj.goalDD.Value);
            if strcmp(name, 'custom')
                obj.setStatus('Custom weights: edit the Weights field directly; presets only refill it when picked.');
            else
                p = neuroqc.optimize.GoalProfile.resolve(name);
                obj.wField.Value = strtrim(sprintf('%g ', [p.objectives.weight]));
            end
            try
                obj.syncGoal();
            catch ME
                obj.setStatus(['Goal: ' ME.message]);
            end
            obj.refreshActionGate();
        end

        function weightsChanged(obj)
            % Hand-edited weights switch the Goal to Custom so the next
            % preset pick is explicit instead of silently overwriting them.
            if ~strcmp(char(obj.goalDD.Value), 'custom')
                obj.goalDD.Value = 'custom';
            end
            try
                obj.syncGoal();
            catch ME
                obj.setStatus(['Goal: ' ME.message]);
            end
            obj.refreshActionGate();
        end

        function editSpace(obj,e)
            try
                src = e.Source;
                if ~isa(src, 'matlab.ui.control.Table') || isempty(src.Data)
                    src = obj.spaceTable;
                end
                name = src.Data{e.Indices(1),1};
                parts=strsplit(char(e.NewData),'|'); values=cell(size(parts));
                for k=1:numel(parts)
                    t=strtrim(parts{k});
                    try, values{k}=jsondecode(t); catch, values{k}=t; end
                end
                obj.Space.(name)=values;
                if isfield(obj.LockSpec,name) && ~any(cellfun(@(v) isequal(v,obj.LockSpec.(name)),values))
                    obj.Space.(name){end+1}=obj.LockSpec.(name);obj.logMsg('Preserved locked %s; unlock explicitly to change it.',name);
                end
                obj.refreshSpaceTable();
                obj.refreshParamRows();
            catch ME
                obj.logMsg('%s',ME.message); obj.refreshSpaceTable();
            end
        end

        function loadFile(obj)
            [name,folder]=uigetfile('*.set'); if isequal(name,0), return; end
            eeg=pop_loadset('filename',name,'filepath',folder);
            obj.acceptSource(eeg); obj.srcEdit.Value=fullfile(folder,name);
            obj.lastCurrentSet = NaN;
            obj.sourceFromFile = true;
            obj.Results=[];obj.GeneratedOptions=[];obj.resultTable.Data=cell(0,12);
            obj.updateSummary();
            [n,mapped,total]=obj.parseHistoryIntoHandoff(eeg);
            filled=obj.fillScopeFromHistory(eeg);
            note='';
            if ~isempty(filled), note=sprintf('. Filled empty Scope field(s): %s',strjoin(filled,'; ')); end
            if n>0
                obj.setStatus(sprintf(['Loaded .set; auto-parsed %d completed step(s) from ' ...
                    'EEG.history (%d of %d line(s) mapped)%s — verify in Handoff'],n,mapped,total,note));
            elseif total>0
                obj.setStatus(sprintf(['Loaded .set; EEG.history has %d line(s) but no ' ...
                    'recognized step — check it with History...'],total));
            else
                obj.setStatus('Loaded .set; select unit and handoff stage.');
            end
        end

        function importHistory(obj)
            % Explicit re-parse of the current input's EEG.history.
            try
                assert(~isempty(obj.SourceEEG),'NeuroQC:Source','Load a dataset first');
                [n,mapped,total]=obj.parseHistoryIntoHandoff(obj.SourceEEG);
                filled=obj.fillScopeFromHistory(obj.SourceEEG);
                note='';
                if ~isempty(filled), note=sprintf('. Filled empty Scope field(s): %s',strjoin(filled,'; ')); end
                if n>0
                    obj.setStatus(sprintf(['Parsed %d completed step(s) from EEG.history ' ...
                        '(%d of %d line(s) mapped)%s — verify in Handoff'],n,mapped,total,note));
                elseif total>0
                    obj.setStatus(sprintf('EEG.history has %d line(s) but no recognized step',total));
                else
                    obj.setStatus('EEG.history is empty or has no recognized steps');
                end
            catch ME
                obj.setStatus(['Import history: ' ME.message]);
                obj.logMsg('%s',ME.message);
            end
        end

        function [n,mapped,total]=parseHistoryIntoHandoff(obj,eeg)
            % Silent parse of EEG.history into the Handoff / Completed set
            % (exact-set mode). Shared by loadFile and Import history.
            % n = parsed steps; mapped/total = line coverage for the status bar.
            n=0;mapped=0;total=0;
            if isempty(eeg) || ~isfield(eeg,'history') || isempty(eeg.history), return; end
            raw=string(eeg.history);
            allLines=splitlines(raw);
            total=sum(strlength(strtrim(allLines))>0);
            for k=1:numel(allLines)
                ln=strtrim(char(allLines(k)));
                if isempty(ln), continue; end
                if ~isempty(neuroqc.gui.CheckpointDialog.classifyCom(ln)), mapped=mapped+1; end
            end
            steps=neuroqc.gui.CheckpointDialog.parseHistory(eeg.history);
            if isempty(steps), return; end
            % Epoched input keeps its safety declaration even if the
            % recorded history never logged the epoch call.
            epoched=(isfield(eeg,'epoch') && ~isempty(eeg.epoch)) || ...
                (isfield(eeg,'trials') && eeg.trials>1);
            if epoched && ~ismember('epoch',steps), steps{end+1}='epoch'; end
            obj.handoffDD.Value='set';
            obj.completedField.Value=strjoin(steps,',');
            obj.handoffModeChanged();
            obj.logMsg('Handoff: parsed EEG.history -> completed set: %s',strjoin(steps,', '));
            obj.logMsg('History coverage: %d of %d non-empty line(s) mapped to a step; open History... for the verbatim text.', ...
                mapped, total);
            n=numel(steps);
        end

        function filled = fillScopeFromHistory(obj, eeg)
            % Epoch / Baseline / Events are derived from EEG.history only
            % where the user left the field empty: a fresh Scope still starts
            % blank, and anything already typed is never overwritten.
            filled = {};
            if isempty(eeg) || ~isfield(eeg,'history') || isempty(eeg.history), return; end
            if isempty(obj.epochField) || ~isvalid(obj.epochField), return; end
            ls = splitlines(string(eeg.history));
            for k = 1:numel(ls)
                ln = strtrim(char(ls(k)));
                if isempty(ln), continue; end
                step = neuroqc.gui.CheckpointDialog.classifyCom(ln);
                if strcmp(step,'epoch')
                    if isempty(strtrim(char(obj.epochField.Value)))
                        tok = regexp(ln,'pop_epoch\s*\([^;]*?,\s*\[([^\]]+)\]','tokens','once');
                        if ~isempty(tok)
                            w = sscanf(tok{1},'%f');
                            if numel(w)==2
                                obj.epochField.Value = sprintf('%g %g',w(1),w(2));
                                filled{end+1} = ['Epoch ' obj.epochField.Value]; %#ok<AGROW>
                            end
                        end
                    end
                    if isempty(strtrim(char(obj.condField.Value)))
                        tok = regexp(ln,'pop_epoch\s*\(\s*EEG\s*,\s*\{([^}]*)\}','tokens','once');
                        if ~isempty(tok)
                            codes = regexp(tok{1},'''([^'']+)''','tokens');
                            vals = cellfun(@(c) strtrim(c{1}), codes, 'UniformOutput', false);
                            if ~isempty(vals)
                                obj.condField.Value = strjoin(vals, ', ');
                                filled{end+1} = ['Events ' obj.condField.Value]; %#ok<AGROW>
                            end
                        end
                    end
                elseif strcmp(step,'baseline')
                    if isempty(strtrim(char(obj.baseField.Value)))
                        tok = regexp(ln,'pop_rmbase\s*\(\s*EEG\s*,\s*\[([^\]]+)\]','tokens','once');
                        if ~isempty(tok)
                            w = sscanf(tok{1},'%f');
                            if numel(w)==2
                                obj.baseField.Value = sprintf('%g %g',w(1)/1000,w(2)/1000);
                                filled{end+1} = ['Baseline ' obj.baseField.Value]; %#ok<AGROW>
                            end
                        end
                    end
                end
            end
            if ~isempty(filled)
                obj.refreshActionGate();
                obj.logMsg('Scope from EEG.history: %s (only empty fields were filled; verify before Generate).', ...
                    strjoin(filled, '; '));
            end
        end

        function refreshFromEEGLAB(obj)
            % Explicit hand-back: stop honoring a loaded .set file and take
            % the current EEGLAB set (ALLEEG(CURRENTSET) / base EEG).
            obj.sourceFromFile = false;
            obj.lastCurrentSet = NaN;   % force re-sync even if the index matches
            obj.autoLoadCurrentSet(false);
        end

        function writeOptionsSnapshot(obj,opts,outDir)
            % Round-trip options (incl. lockSpec + full search space) for loadOptions.
            try
                fpath=fullfile(outDir,'options.json');
                f=fopen(fpath,'w');
                assert(f>0,'NeuroQC:IO','Cannot write %s',fpath);
                cleanup=onCleanup(@() fclose(f)); %#ok<NASGU>
                snap=opts;
                snap.wizard=obj.configurationState();snap.wizard=rmfield(snap.wizard,{'Space','LockSpec','ExtraOptions','handoffDD','completedField','stageDD','selectedStepsField','stepOrderField','fixedPosField','maxOrdersField','searchOrderCheck','useParallelCheck','unitDD','trialMode'});
                if ~isempty(obj.SourceEEG),snap.sourceHash=neuroqc.utils.hashEEG(obj.SourceEEG);end
                snap.space=obj.Space;   % candidate lists so a snapshot reproduces the search space
                fprintf(f,'%s',jsonencode(snap,'PrettyPrint',true));
                obj.logMsg('Options snapshot: %s',fpath);
            catch ME
                obj.logMsg('options.json write failed: %s',ME.message);
            end
        end

        function loadOptions(obj)
            [name,folder]=uigetfile('*.json'); if isequal(name,0), return; end
            try
                o=jsondecode(fileread(fullfile(folder,name)));
                obj.applyOptions(o,name);
            catch ME, obj.logMsg('%s',ME.message); end
        end

        function applyOptions(obj,o,name)
            % Restore GUI state from a decoded options struct (round-trip of
            % writeOptionsSnapshot + legacy hand-written options files).
            if nargin<3, name='(struct)'; end
            if isfield(o,'lockSpec')
                assert(isempty(setdiff(fieldnames(o.lockSpec),fieldnames(neuroqc.pipeline.SearchSpace.defaultERP()))), ...
                    'NeuroQC:UnknownDimension','Unknown locked dimension; options were not applied');
            end
            if isfield(o,'startAfter')
                if strcmp(o.startAfter,'raw'),o.completedStages={};
                else,o.completedStages=neuroqc.pipeline.StageModel.normalizeCompleted({o.startAfter},'prefix');end
                o.orderMode='set';o=rmfield(o,'startAfter');
            end
            % Loading replaces prior scope settings; absent fields cannot retain stale locks.
            obj.stepOrderField.Value='';obj.fixedPosField.Value='';obj.searchOrderCheck.Value=false;
            obj.maxOrdersField.Value='10000';obj.selectedStepsField.Value='';obj.stepsList.Value={};obj.LockSpec=struct();
            obj.handoffDD.Value='set';obj.completedField.Value='';obj.stageDD.Value='raw';
            obj.unitDD.Value='choose';obj.trialMode.Value='choose';obj.useParallelCheck.Value=true;
            if isfield(o,'space') && isstruct(o.space) && isscalar(o.space)
                % Restore the searched candidate lists (jsonencode/jsondecode
                % roundtrip yields cell, numeric/logical array, string or char).
                restoredDims={};
                for ff=fieldnames(o.space)'
                    d=ff{1}; raw=o.space.(d);
                    if iscell(raw), vals=raw;
                    elseif isstruct(raw), vals=num2cell(raw(:))';   % cell-of-structs decodes to struct array
                    elseif isnumeric(raw) || islogical(raw)
                        if isempty(raw), vals={[]};
                        elseif ismember(d,{'epochWindow','baselineWindow'})
                            if isvector(raw), vals={raw(:)'};
                            else, vals=num2cell(raw,2)'; end
                        else, vals=num2cell(raw(:))'; end
                    elseif isstring(raw), vals=cellstr(raw(:))';
                    elseif ischar(raw), vals={raw};
                    else, vals={raw};
                    end
                    obj.Space.(d)=vals;
                    restoredDims{end+1}=d; %#ok<AGROW>
                end
                o=rmfield(o,'space');   % space lives in obj.Space, not in opts
                if ~isempty(restoredDims)
                    obj.logMsg('Options file: restored search space (%d dimensions)',numel(restoredDims));
                end
                obj.refreshSpaceTable();
            end
            obj.ExtraOptions=o;
            if isfield(o,'searchOrder'), obj.searchOrderCheck.Value=logical(o.searchOrder); end
            if isfield(o,'stepOrder'), obj.stepOrderField.Value=strjoin(cellstr(o.stepOrder),','); end
            if isfield(o,'maxOrders') && isscalar(o.maxOrders)
                obj.maxOrdersField.Value=num2str(o.maxOrders);
            end
            if isfield(o,'fixedPositions') && isstruct(o.fixedPositions) && isscalar(o.fixedPositions)
                fp=o.fixedPositions; parts={};
                for ff=fieldnames(fp)'
                    parts{end+1}=sprintf('%s=%d',ff{1},fp.(ff{1})); %#ok<AGROW>
                end
                obj.fixedPosField.Value=strjoin(parts,',');
            end
            if isfield(o,'lockSpec') && isstruct(o.lockSpec) && isscalar(o.lockSpec)
                ls=o.lockSpec; restored=struct(); dropped={};
                for ff=fieldnames(ls)'
                    d=ff{1}; v=ls.(d);
                    if isfield(obj.Space,d) && any(cellfun(@(x) isequal(x,v),obj.Space.(d)))
                        restored.(d)=v;
                    else
                        assert(isfield(obj.Space,d),'NeuroQC:UnknownDimension','Unknown locked dimension %s',d);
                        obj.Space.(d){end+1}=v;restored.(d)=v;
                    end
                end
                obj.LockSpec=restored;
                if ~isempty(dropped)
                    obj.logMsg('lockSpec: dropped values not in current space: %s',strjoin(dropped,','));
                end
                obj.refreshSpaceTable();
            end
            if isfield(o,'completedStages')
                mode='set';if isfield(o,'orderMode'),mode=o.orderMode;end
                done=neuroqc.pipeline.StageModel.normalizeCompleted(o.completedStages,mode);
                obj.handoffDD.Value='set';obj.completedField.Value=strjoin(done,',');
                obj.handoffModeChanged();
            end
            if isfield(o,'useParallel'),obj.useParallelCheck.Value=logical(o.useParallel);end
            if isfield(o,'dataUnit'), obj.unitDD.Value=o.dataUnit; end
            if isfield(o,'trialSelection')
                obj.trialMode.Value='loaded options JSON';
                if strcmp(o.trialSelection.mode,'all'),obj.trialMode.Value='already screened: all';end
                if strcmp(o.trialSelection.mode,'existing'),obj.trialMode.Value='existing selection';end
            end
            if isfield(o,'selectedSteps')
                sel=cellstr(o.selectedSteps);
                obj.selectedStepsField.Value=strjoin(sel,',');
                if ~isempty(obj.stepsList)
                    obj.stepsList.Value=intersect(sel, obj.stepsList.Items, 'stable');
                end
            end
            if isfield(o,'wizard'),obj.restoreConfiguration(o.wizard);end
            if ~isempty(obj.SourceEEG) && isfield(o,'sourceHash')
                obj.InputSettingsVerified=true;
                if ~strcmp(o.sourceHash,neuroqc.utils.hashEEG(obj.SourceEEG))
                    obj.resetInputSettings();
                    obj.setStatus('Options belong to another input. Source-specific settings cleared; re-enter unit, trial rule and completed steps.');
                end
            elseif ~isempty(obj.SourceEEG)
                obj.InputSettingsVerified=false;
                obj.setStatus('Legacy options have no source identity. Use Confirm input settings after checking trial rule, channels and handoff.');
            end
            obj.refreshParamRows();
            obj.refreshActionGate();
            obj.logMsg('Loaded options %s.',name);
        end

        function showResults(obj)
            if isempty(obj.Results) || ~isfield(obj.Results, 'pipelines')
                obj.updateConstraintSummary();
                return;
            end
            R = obj.Results;
            n = numel(R.pipelines);
            front = [];
            if isfield(R,'frontIdx'), front = R.frontIdx; end
            goal = [];
            if isfield(R,'goalRecommendation') && isstruct(R.goalRecommendation), goal = R.goalRecommendation; end
            % Why each candidate lost: execution failure, else hard-constraint reason.
            failOf = containers.Map('KeyType','char','ValueType','char');
            if isfield(R,'trialFailures')
                for k = 1:numel(R.trialFailures)
                    failOf(char(R.trialFailures(k).id)) = char(R.trialFailures(k).message);
                end
            end
            reasonOf = containers.Map('KeyType','char','ValueType','char');
            if isfield(R,'rejectedIdx') && isfield(R,'constraintReasons')
                for k = 1:min(numel(R.rejectedIdx), numel(R.constraintReasons))
                    rid = R.pipelines(R.rejectedIdx(k)).id;
                    txt = R.constraintReasons{k};
                    if iscell(txt), txt = strjoin(txt, '; '); end
                    reasonOf(char(rid)) = char(txt);
                end
            end
            data = cell(n, 12);
            for i = 1:n
                steps = {R.pipelines(i).steps.type};
                id = char(R.pipelines(i).id);
                data{i,1} = R.pipelines(i).id;
                data{i,2} = strjoin(steps, ' > ');
                data{i,3} = double(any(front == i));
                data{i,4} = NaN;
                data{i,5} = '';
                data{i,6} = NaN;
                data{i,7} = NaN;
                data{i,8} = NaN;
                data{i,9} = 'NEEDS_QC';
                data{i,10} = NaN;
                data{i,11} = '';
                data{i,12} = sprintf('recipe_%s.m', R.pipelines(i).id);
                if isKey(failOf, id)
                    data{i,11} = ['execution: ' failOf(id)];
                elseif isKey(reasonOf, id)
                    data{i,11} = reasonOf(id);
                end
                if isfield(R,'results') && ~isempty(R.results)
                    match = find(strcmp({R.results.id}, id), 1);
                    if ~isempty(match)
                        q = R.results(match).quality;
                        data{i,9} = R.results(match).status;
                        data{i,6} = localN(q.reliability);
                        data{i,7} = localN(q.retention);
                        data{i,8} = localN(q.waveformDistortion);
                        if isfield(q,'topoStability'), data{i,10} = localN(q.topoStability); end
                    end
                end
                if ~isempty(goal) && isfield(goal, 'scores') && ~isempty(goal.scores) ...
                        && isfield(goal, 'frontIdx')
                    fi = find(goal.frontIdx == i, 1);
                    if ~isempty(fi)
                        data{i,4} = goal.scores(fi);
                    end
                    if isfield(goal, 'bestOverall') && ~isempty(goal.bestOverall) && goal.bestOverall == i
                        data{i,5} = 'bestEvaluated';
                    end
                    if isfield(goal, 'byObjective')
                        fn = fieldnames(goal.byObjective);
                        for k = 1:numel(fn)
                            if goal.byObjective.(fn{k}).index == i
                                if isempty(data{i,5})
                                    data{i,5} = fn{k};
                                else
                                    data{i,5} = [data{i,5} '|' fn{k}]; %#ok<AGROW>
                                end
                            end
                        end
                    end
                end
                % Nothing is ranked when every candidate was rejected: say so
                % instead of leaving an unexplained NaN in GoalScore.
                if isempty(front) && (isKey(reasonOf, id) || ~isnan(data{i,6}))
                    data{i,4} = 'infeasible';
                end
            end
            obj.resultTable.ColumnName = {'ID','Steps','Front','GoalScore','Labels', ...
                'Rel','Reten','Dist','QC','Topo','Reason','Recipe'};
            obj.resultTable.Data = data;
            tested=neuroqc.advice.CandidateSession.tested(R);
            if numel(tested)<n,label='Recommendation among evaluated candidates only';else,label='All declared candidates tried; recommendation requires QC review';end
            extra='';
            nRejected = 0;
            if isfield(R,'rejectedIdx'), nRejected = numel(R.rejectedIdx); end
            if isempty(front) && (nRejected > 0 || ~isempty(tested))
                % Only claim a dead end when candidates were actually judged.
                rsn = {};
                if isfield(R,'constraintReasons'), rsn = R.constraintReasons; end
                if iscell(rsn) && ~isempty(rsn)
                    first = rsn{1};
                    if iscell(first), first = strjoin(first, '; '); end
                    extra = sprintf([' NO_FEASIBLE_SOLUTION: no candidate passed the hard constraints ' ...
                        '(first reason: %s, %d more). Relax Constraints in Step 2, then Re-rank.'], ...
                        char(first), max(0, numel(rsn) - 1));
                elseif nRejected > 0
                    extra = ' NO_FEASIBLE_SOLUTION: no candidate passed the hard constraints. Relax Constraints in Step 2, then Re-rank.';
                else
                    extra = ' NO_FEASIBLE_SOLUTION: no candidate could be ranked from what has been evaluated.';
                end
            end
            obj.coverageLabel.Text=sprintf('%d / %d tried (%.1f%%). %s.%s',numel(tested),n,100*numel(tested)/max(1,n),label,extra);
            obj.updateConstraintSummary();
        end

        function order=workflowOrder(obj)
            selected=obj.selectedStepList();known=neuroqc.pipeline.StageModel.canonicalOrder();
            selected=known(ismember(known,selected));
            raw=strtrim(obj.stepOrderField.Value);
            if isempty(raw),order=selected;return;end
            pins=cellfun(@strtrim,strsplit(raw,','),'UniformOutput',false);
            pins=pins(ismember(pins,selected));
            specs=cellfun(@(x) {x,struct()},selected,'UniformOutput',false);
            try
                specs=neuroqc.pipeline.StageModel.orderPending(specs,pins);
                order=cellfun(@(x) x{1},specs,'UniformOutput',false);
            catch
                order=[pins setdiff(selected,pins,'stable')];
            end
        end

        function moveWorkflow(obj,delta,step)
            try
                if nargin<3,step=obj.workflowList.Value;end
                order=obj.workflowOrder();i=find(strcmp(order,step),1);
                assert(~isempty(i),'NeuroQC:Scope','Select this step in Scope first');
                j=i+delta;if j<1 || j>numel(order),return;end
                order([i j])=order([j i]);
                neuroqc.pipeline.StageModel.validateStepOrder(order);
                raw=strtrim(obj.fixedPosField.Value);
                if ~isempty(raw)
                    pins=neuroqc.pipeline.StageModel.parseFixedSlots(raw,order);
                    for f=fieldnames(pins)'
                        assert(strcmp(order{pins.(f{1})},f{1}),'NeuroQC:Order','Move conflicts with fixed slot %s; edit that lock first',f{1});
                    end
                end
                obj.stepOrderField.Value=strjoin(order,',');obj.refreshParamRows();
                obj.workflowList.Value=step;obj.paramStepList.Value=step;obj.paramListChanged();
                obj.setStatus('Displayed sequence fixed. Free order clears relative pins and searches remaining legal orders; fixed slots remain.');
            catch ME,obj.setStatus(ME.message);end
        end

        function removeWorkflowStep(obj)
            step=obj.workflowList.Value;if isempty(step),return;end
            selected=setdiff(obj.selectedStepList(),{step},'stable');
            obj.selectedStepsField.Value=strjoin(selected,',');
            raw=strtrim(obj.stepOrderField.Value);
            if ~isempty(raw),pins=strsplit(raw,',');obj.stepOrderField.Value=strjoin(setdiff(strtrim(pins),{step},'stable'),',');end
            if ~isempty(strtrim(obj.fixedPosField.Value))
                obj.setStatus('Update fixed slots after removing a step; Preview checks them before generation.');
            end
            obj.selectedStepsTyped();
        end

        function freeWorkflowOrder(obj)
            obj.stepOrderField.Value='';obj.searchOrderCheck.Value=true;obj.refreshParamRows();
            obj.setStatus('Searching all legal orders subject to Fixed slots. Add Step order to pin relative precedence.');
        end

        function state=configurationState(obj)
            state=struct();
            fields={'epochField','baseField','condField','compField','unitDD','trialMode','selectedStepsField', ...
                'searchOrderCheck','stepOrderField','fixedPosField','maxOrdersField','useParallelCheck', ...
                'stageDD','handoffDD','completedField','goalDD','wField','qcField'};
            for k=1:numel(fields),state.(fields{k})=obj.(fields{k}).Value;end
            for f=fieldnames(obj.constraintFields)'
                state.(['constraint_' f{1}])=obj.constraintFields.(f{1}).Value;
            end
            state.Space=obj.Space;state.LockSpec=obj.LockSpec;state.ExtraOptions=obj.ExtraOptions;
            for f={'wizard','space','sourceHash'}
                if isfield(state.ExtraOptions,f{1}),state.ExtraOptions=rmfield(state.ExtraOptions,f{1});end
            end
        end

        function restoreConfiguration(obj,state)
            for f=fieldnames(state)'
                name=f{1};
                if strncmp(name,'constraint_',11)
                    key=name(12:end);
                    if isfield(obj.constraintFields,key) && ~isempty(obj.constraintFields.(key)) ...
                            && isvalid(obj.constraintFields.(key))
                        obj.constraintFields.(key).Value=state.(name);
                    end
                elseif any(strcmp(name,{'Space','LockSpec','ExtraOptions'})),obj.(name)=state.(name);
                elseif isprop(obj,name) && isprop(obj.(name),'Value'),obj.(name).Value=state.(name);end
            end
            obj.selectedStepsTyped();obj.handoffModeChanged();
        end

        function assertCurrentConfiguration(obj)
            assert(obj.InputSettingsVerified,'NeuroQC:InputReview','Confirm imported input settings first');
            assert(~obj.configurationDrifted(),'NeuroQC:ConfigurationChanged', ...
                'Settings changed since generation. Generate fresh recipes before comparing or importing QC. Previous results are preserved.');
        end

        function drifted = configurationDrifted(obj)
            % True when the UI no longer matches the state that generated
            % the current results (shared by the Compare gate and the
            % click-time assert; same carve-outs as before).
            drifted = false;
            if isempty(obj.GenerationState), return; end
            now = obj.configurationState(); before = obj.GenerationState;
            now.qcField = before.qcField; % QC import path is a result attachment, not a processing change.
            % First comparison may add the initially absent ERP components.
            if isempty(strtrim(before.compField)) && ~isfield(obj.Results,'evaluationContract')
                now.compField = before.compField;
            end
            % Constraints only re-rank already-evaluated candidates; they
            % never invalidate generated recipes, so they are not drift.
            fn = fieldnames(now);
            for k = 1:numel(fn)
                if strncmp(fn{k}, 'constraint_', 11)
                    if isfield(now, fn{k}), now = rmfield(now, fn{k}); end
                    if isfield(before, fn{k}), before = rmfield(before, fn{k}); end
                end
            end
            drifted = ~isequaln(now, before);
        end

        function acceptSource(obj,e)
            changed=~isempty(obj.SourceEEG) && ~strcmp(neuroqc.utils.hashEEG(obj.SourceEEG),neuroqc.utils.hashEEG(e));
            if changed,obj.resetInputSettings();end
            obj.SourceEEG=e;obj.Contract=[];obj.Results=[];obj.GeneratedOptions=[];obj.GenerationState=[];
            if ~isempty(obj.resultTable),obj.resultTable.Data=cell(0,12);end
            if ~isempty(obj.coverageLabel),obj.coverageLabel.Text='New input: generate fresh candidates';end
            if ((isfield(e,'epoch') && ~isempty(e.epoch)) || (isfield(e,'trials') && e.trials>1)) && isempty(obj.completedField.Value)
                obj.handoffDD.Value='set';obj.completedField.Value='epoch';
                obj.logMsg('Handoff inferred: epoch (input is epoched). It claims only this input - verify the Completed set before Generate.');
            end
            obj.refreshActionGate();
        end

        function resetInputSettings(obj)
            obj.ExtraOptions=struct();obj.unitDD.Value='choose';obj.trialMode.Value='choose';
            obj.handoffDD.Value='set';obj.completedField.Value='';obj.stageDD.Value='raw';obj.qcField.Value='';
            % Epoch/Baseline/Events/Components describe the previous dataset;
            % they must never survive a source switch (Load ... refills them
            % from the new EEG.history; anything you type is never touched).
            for f={'epochField','baseField','condField','compField'}
                h=obj.(f{1});
                if ~isempty(h) && isvalid(h), h.Value=''; end
            end
            obj.Contract=[];
            defaults=neuroqc.pipeline.SearchSpace.defaultERP();
            sensitive={'chanloc','selectData','selectEvents','editEvents','rejectJointprob','rejectKurt'};
            for k=1:numel(sensitive)
                f=sensitive{k};if isfield(defaults,f),obj.Space.(f)=defaults.(f);end
                if isfield(obj.LockSpec,f),obj.LockSpec=rmfield(obj.LockSpec,f);end
            end
            obj.InputSettingsVerified=true;obj.handoffModeChanged();
            obj.logMsg('Source changed: cleared trial selection, units, completed stages, Epoch/Baseline/Events/Components, native captured selections and other source-specific options. Generic search values retained.');
            obj.refreshActionGate();
        end

        function confirmInputSettings(obj)
            assert(~strcmp(obj.unitDD.Value,'choose'),'NeuroQC:DataUnitRequired','Choose the input unit first');
            obj.InputSettingsVerified=true;obj.setStatus('Input-specific settings confirmed for this snapshot.');
            obj.refreshActionGate();
        end

        function reasons = actionGate(obj)
            % Preconditions for Generate, evaluated before the click (B1).
            % The methods keep their own asserts; this only drives button
            % Enable plus the inline reason label so nothing errors mid-flow.
            reasons = {};
            if isempty(obj.SourceEEG), reasons{end+1}='Load current EEG first'; end
            if isempty(obj.unitDD) || ~isvalid(obj.unitDD), return; end
            if strcmp(char(obj.unitDD.Value),'choose'), reasons{end+1}='Choose the data unit (uV or V) in Step 1'; end
            if isempty(obj.selectedStepsField) || ~isvalid(obj.selectedStepsField), return; end
            steps = obj.selectedStepList();
            if isempty(steps)
                reasons{end+1}='Select steps in Step 2';
            else
                % Unknown tokens keep the gate honest: the field text is
                % passed through verbatim, so a typo would otherwise show
                % Ready and only fail at Generate (NeuroQC:UnknownStage).
                low = cellfun(@(s) lower(char(s)), steps, 'UniformOutput', false);
                unk = setdiff(low, neuroqc.pipeline.StageModel.canonicalOrder());
                if ~isempty(unk)
                    reasons{end+1}=sprintf('Unknown step(s) in Steps field: %s', strjoin(unk, ', '));
                end
            end
            if ~isempty(obj.condField) && isvalid(obj.condField) && isempty(strtrim(char(obj.condField.Value)))
                reasons{end+1}='Fill Events in Step 2 (Contract)';
            end
            if ~isempty(obj.epochField) && isvalid(obj.epochField) && isempty(strtrim(char(obj.epochField.Value)))
                reasons{end+1}='Fill the Epoch window in Step 2';
            end
            if ~isempty(obj.baseField) && isvalid(obj.baseField) && isempty(strtrim(char(obj.baseField.Value)))
                reasons{end+1}='Fill the Baseline window in Step 2';
            end
            [~, cerr] = obj.constraintLimits();
            for k = 1:numel(cerr), reasons{end+1} = cerr{k}; end %#ok<AGROW>
            % Goal weights must resolve before Generate can be Ready, and the
            % reason shows in the gate instead of dying inside a callback.
            if ~isempty(obj.goalDD) && isvalid(obj.goalDD)
                try
                    obj.syncGoal();
                catch ME
                    reasons{end+1} = ['Goal weights: ' ME.message];
                end
            end
            needTrial = any(ismember(steps,{'epoch','baseline','artifact_reject','auto_reject', ...
                'reject_jointprob','reject_kurtosis'}));
            if needTrial && strcmp(char(obj.trialMode.Value),'choose')
                reasons{end+1}='Choose the Trial rule in Step 1';
            end
            if strcmp(char(obj.trialMode.Value),'loaded options JSON') && ~isfield(obj.ExtraOptions,'trialSelection')
                reasons{end+1}='Loaded options have no trialSelection - pick another Trial rule';
            end
            if ~obj.InputSettingsVerified, reasons{end+1}='Click Confirm input settings in Step 1'; end
        end

        function refreshActionGate(obj)
            % B1/B4: keep Generate / Compare / Retry disabled with a visible reason.
            reasons = obj.actionGate();
            cmp = reasons;
            if isempty(obj.compField) || ~isvalid(obj.compField) || isempty(strtrim(char(obj.compField.Value)))
                cmp{end+1}='Fill Components in Step 2 (required for ERP Compare)';
            end
            if isempty(obj.Results)
                cmp{end+1}='Generate recipes first';
            end
            if obj.configurationDrifted()
                cmp{end+1}='Settings changed since generation - regenerate recipes';
            end
            rk = cmp;
            % Cheap read: testedIndices is stamped by Compare / recover.
            if ~isfield(obj.Results,'testedIndices') || isempty(obj.Results.testedIndices)
                rk{end+1}='Compare at least one candidate before re-ranking';
            end
            obj.setGate(obj.gateLabel, reasons);
            obj.setGate(obj.gateLabel4, cmp);
            if ~isempty(obj.runBtn) && isvalid(obj.runBtn)
                if isempty(reasons), obj.runBtn.Enable='on'; else, obj.runBtn.Enable='off'; end
            end
            if ~isempty(obj.compareBtn) && isvalid(obj.compareBtn)
                st='on'; if ~isempty(cmp), st='off'; end
                obj.compareBtn.Enable=st;
                obj.compareAllBtn.Enable=st;
            end
            if ~isempty(obj.rerankBtn) && isvalid(obj.rerankBtn)
                if isempty(rk), obj.rerankBtn.Enable='on'; else, obj.rerankBtn.Enable='off'; end
            end
            if ~isempty(obj.retryBtn) && isvalid(obj.retryBtn)
                if isempty(cmp), obj.retryBtn.Enable='on'; else, obj.retryBtn.Enable='off'; end
            end
            obj.updateConstraintSummary();
        end

        function setGate(~,lbl,reasons)
            if isempty(lbl) || ~isvalid(lbl), return; end
            if isempty(reasons), lbl.Text='';
            else, lbl.Text=['Required: ' strjoin(reasons,'; ')]; end
        end

        function setComponentChannels(obj,index,picked)
            specs=strsplit(obj.compField.Value,';');assert(index>=1 && index<=numel(specs),'NeuroQC:Component','Choose a component');
            spec=strtrim(specs{index});assert(~isempty(spec),'NeuroQC:Component','That component slot is empty');
            parts=strsplit(spec,'@');
            if numel(parts)==1,specs{index}=[spec ' @ ' strjoin(picked,',')];
            else
                % Preserve a trailing ":type" on the channel list.
                extra='';tp=strsplit(strtrim(parts{2}),':');
                if numel(tp)>1,extra=[':' strjoin(tp(2:end),':')];end
                specs{index}=[strtrim(parts{1}) ' @ ' strjoin(picked,',') extra];
            end
            obj.compField.Value=strjoin(specs,'; ');obj.Contract=[];
            obj.setStatus('Component channels updated. Regenerate if recipes already exist.');
            obj.refreshActionGate();
        end

        function saveSession(obj,file,includeSource)
            if nargin<3,includeSource=true;end
            try
                if nargin<2
                    [f,p]=uiputfile('*.mat','Save NeuroQC session (includes input snapshot)');if isequal(f,0),return;end
                    file=fullfile(p,f);
                end
                session=struct('version',1,'source',obj.SourceEEG,'state',obj.configurationState(), ...
                    'contract',obj.Contract,'results',obj.Results,'generatedOptions',obj.GeneratedOptions, ...
                    'generationState',obj.GenerationState,'inputSettingsVerified',obj.InputSettingsVerified);
                session.sourceHash='';if ~isempty(obj.SourceEEG),session.sourceHash=neuroqc.utils.hashEEG(obj.SourceEEG);end
                if ~includeSource,session.source=[];end
                pending=[file '.partial.mat'];save(pending,'session','-v7.3');movefile(pending,file,'f');
                obj.setStatus('Session saved, including input snapshot, configuration and result references. Keep the recipe/output folder.');
            catch ME,obj.setStatus(ME.message);rethrow(ME);end
        end

        function loadSession(obj,file)
            if nargin<2
                [f,p]=uigetfile('*.mat','Open NeuroQC session');if isequal(f,0),return;end;file=fullfile(p,f);
            end
            d=load(file,'session');assert(isfield(d,'session') && d.session.version==1,'NeuroQC:Session','Unsupported session');s=d.session;
            if isempty(s.source) && isfield(s,'sourceHash') && ~isempty(s.sourceHash)
                assert(~isempty(obj.SourceEEG) && strcmp(neuroqc.utils.hashEEG(obj.SourceEEG),s.sourceHash), ...
                    'NeuroQC:SourceMismatch','Load the original handoff EEG before opening this automatic session');
                s.source=obj.SourceEEG;
            end
            if ~isempty(s.results)
                assert(strcmp(neuroqc.utils.hashEEG(s.source),s.results.inputHash),'NeuroQC:SourceMismatch','Session input mismatch');
                assert(isfolder(s.results.recipesDir),'NeuroQC:Session','Recipe folder missing; restore the original output folder');
                s.results=neuroqc.advice.CandidateSession.recover(s.results);
            end
            obj.SourceEEG=s.source;obj.restoreConfiguration(s.state);obj.Contract=s.contract;
            obj.Results=s.results;obj.GeneratedOptions=s.generatedOptions;obj.GenerationState=s.generationState;
            obj.InputSettingsVerified=s.inputSettingsVerified;obj.sourceFromFile=true;obj.srcEdit.Value=['Session: ' file];
            obj.updateSummary();obj.showResults();obj.setStatus('Session restored. Compare all continues untested candidates.');
            obj.refreshActionGate();
        end

        function retryFailed(obj)
            try
                assert(~isempty(obj.Results),'NeuroQC:NoRecommend','Generate recipes first');
                obj.assertCurrentConfiguration();
                obj.Results=neuroqc.advice.CandidateSession.recover(obj.Results);
                assert(isfield(obj.Results,'trialFailures') && ~isempty(obj.Results.trialFailures),'NeuroQC:Retry','No execution failures to retry');
                obj.ensureComponentsForCompare();
                ix=find(ismember({obj.Results.pipelines.id},{obj.Results.trialFailures.id}));
                obj.Results=neuroqc.advice.CandidateSession.compare(obj.Results,obj.SourceEEG,obj.Contract,struct('retryFailed',true),ix);
                obj.showResults();obj.setStatus('Failed candidates retried; prior attempts archived in candidate_trials.');
            catch ME,obj.setStatus(ME.message);end
        end

        function openSelectedRecipe(obj)
            try
                row=obj.resultTable.Selection;assert(~isempty(row),'NeuroQC:Candidate','Select a candidate');
                edit(fullfile(obj.Results.recipesDir,['recipe_' obj.Results.pipelines(row(1,1)).id '.m']));
            catch ME,obj.setStatus(ME.message);end
        end

        function EEG=captureContext(obj,step,choice)
            EEG=obj.SourceEEG;order=obj.workflowOrder();atStep=find(strcmp(order,step),1);
            if isempty(atStep) || atStep==1,return;end
            assert(obj.buildContract(),'NeuroQC:Contract','Correct the contract before capturing a downstream step');
            opts=obj.assembleScopeOptions();opts.selectedSteps=order(1:atStep-1);opts.stepOrder=opts.selectedSteps;
            opts.searchOrder=false;opts.fixedPositions=struct();opts.dataUnit=obj.unitDD.Value;
            if isfield(opts,'stepModes'),opts=rmfield(opts,'stepModes');end
            switch obj.trialMode.Value
                case 'existing selection',opts.trialSelection=struct('mode','existing');
                case 'already screened: all',opts.trialSelection=struct('mode','all');
            end
            info=neuroqc.advice.RecommendPath.prepareInfo(neuroqc.io.EEGImporter.fromEEG(EEG),opts);
            [pp,~]=neuroqc.pipeline.ExhaustiveSearch.generate(obj.effectiveSpace(),info,obj.Contract,opts);
            assert(~isempty(pp),'NeuroQC:Capture','Configure the preceding steps before capturing this step');
            if nargin<3
                labels=arrayfun(@(p) [p.id ' ' p.fingerprint()],pp,'UniformOutput',false);
                [choice,ok]=listdlg('PromptString','Execute this prefix on a COPY for the native dialog (may take time):', ...
                    'ListString',labels,'SelectionMode','single');
                if ~ok,EEG=[];return;end
            end
            folder=tempname;mkdir(folder);prefix=pp(choice);prefix.id='capture_context';
            neuroqc.advice.EEGLABRecipe.writeRecipe(folder,prefix,obj.Contract,opts);
            oldPath=path;guard=onCleanup(@() path(oldPath));addpath(folder,'-begin');clear recipe_capture_context;
            EEG=recipe_capture_context(EEG);
            obj.logMsg('Native dialog context: %s. Parameter candidates captured in this context must be checked across other prefixes.',prefix.fingerprint());
        end

        function logMsg(obj, fmt, varargin)
            msg = sprintf(fmt, varargin{:});
            if isempty(obj.logArea) || ~isvalid(obj.logArea), fprintf('%s\n',msg); return; end
            obj.logArea.Value = [obj.logArea.Value; {msg}]; %#ok<AGROW>
        end
    end

    methods (Static)
        function app = launchWizardFromMenu()
            eeg = [];
            try
                if evalin('base', 'exist(''EEG'',''var'')')
                    eeg = evalin('base', 'EEG');
                end
            catch
            end
            app = neuroqc.gui.NeuroQCApp(eeg);
            app.launch();
        end
    end
end

function about()
    msgbox(sprintf('NeuroQC %s\nEEGLAB-native dialogs + discrete combo optimizer\nCandidates require validation (REVIEW).', ...
    neuroqc.NeuroQC.version()), 'NeuroQC');
end

function v = localN(x)
    if isnumeric(x) && isscalar(x) && isfinite(x)
        v = x;
    else
        v = NaN;
    end
end

function selectTab(obj, k)
    if isempty(obj.tabGroup) || ~isvalid(obj.tabGroup), return; end
    kids = obj.tabGroup.Children;
    if k >= 1 && k <= numel(kids)
        obj.tabGroup.SelectedTab = kids(k);
    end
end

function c = at(c, r, col)
    % Place a uifigure component on its parent uigridlayout cell.
    % (uibutton/uilabel reject 'Layout.Row' name-value pairs in R2026a.)
    c.Layout.Row = r;
    c.Layout.Column = col;
end

function tf = isKnownStep(step)
    known = neuroqc.pipeline.StageModel.canonicalOrder();
    tf = any(strcmpi(char(step), known));
end

function dims = stepOwnedDims(m, step, space)
    % Dimensions owned by step that exist in space (fullWorkflow excluded:
    % it is a shared gate derived from selected steps, not a step choice).
    dims = {};
    fn = fieldnames(m);
    for i = 1:numel(fn)
        d = fn{i};
        if strcmp(d, 'fullWorkflow'), continue; end
        if any(strcmp(m.(d), step)) && isfield(space, d)
            dims{end+1} = d; %#ok<AGROW>
        end
    end
end

function fn = stepPopFunction(step)
    % Canonical step -> EEGLAB pop_* entry dialog ('' when no single dialog).
    map = struct( ...
        'chanloc', 'pop_chanedit', ...
        'select_data', 'pop_select', ...
        'select_events', 'pop_selectevent', ...
        'edit_events', 'pop_editeventvals', ...
        'resample', 'pop_resample', ...
        'filter', 'pop_eegfiltnew', ...
        'notch', 'pop_eegfiltnew', ...
        'badchannel', 'pop_rejchan', ...
        'reject_continuous', 'pop_rejcont', ...
        'reref', 'pop_reref', ...
        'run_ica', 'pop_runica', ...
        'auto_ic_remove', 'pop_iclabel', ...
        'remove_bad', 'pop_select', ...
        'restore_channels', 'pop_interp', ...
        'epoch', 'pop_epoch', ...
        'baseline', 'pop_rmbase', ...
        'artifact_reject', 'pop_eegthresh', ...
        'auto_reject', 'pop_autorej', ...
        'reject_jointprob', 'pop_jointprob', ...
        'reject_kurtosis', 'pop_rejkurt', ...
        'interpolate', 'pop_interp');
    step = char(step);
    if isfield(map, step), fn = map.(step); else, fn = ''; end
end

function Space = appendUnique(Space, field, value)
    if ~isfield(Space, field) || isempty(Space.(field))
        Space.(field) = {value};
        return;
    end
    cur = Space.(field);
    if ~iscell(cur), cur = {cur}; end
    for i = 1:numel(cur)
        if isequal(cur{i}, value), return; end
    end
    cur{end+1} = value;
    Space.(field) = cur;
end

function picked = parseChanselSelection(selStr)
    picked = {};
    selStr = strtrim(char(string(selStr)));
    if isempty(selStr), return; end
    % pop_chansel may quote names with spaces: 'a b' 'c'
    toks = regexp(selStr, '''([^'']+)''', 'tokens');
    if ~isempty(toks)
        picked = cellfun(@(t) strtrim(t{1}), toks, 'UniformOutput', false);
        return;
    end
    parts = strsplit(selStr);
    picked = parts(~cellfun(@isempty, parts));
end

function labs = parseQuotedList(s)
    labs = {};
    toks = regexp(s, '''([^'']+)''', 'tokens');
    for i = 1:numel(toks)
        labs{end+1} = strtrim(toks{i}{1}); %#ok<AGROW>
    end
    if isempty(labs)
        parts = strsplit(s, ',');
        for i = 1:numel(parts)
            t = strtrim(strrep(parts{i}, '''', ''));
            if ~isempty(t), labs{end+1} = t; end %#ok<AGROW>
        end
    end
end

function args=nativeArguments(com,fn)
% Split an EEGLAB command without evaluating it or losing vector arguments.
tok=regexp(com,[fn '\s*\(([\s\S]*)\)\s*;?\s*$'],'tokens','once');
args={};if isempty(tok),return;end
raw=tok{1}; depth=0;quoted=false;first=1;k=1;
while k<=numel(raw)
 ch=raw(k);
 if ch==char(39)
    if quoted && k<numel(raw) && raw(k+1)==char(39),k=k+2;continue;end
    quoted=~quoted;
 elseif ~quoted
    if any(ch=='([{'),depth=depth+1;end
    if any(ch==')]}'),depth=depth-1;end
    if ch==',' && depth==0,args{end+1}=strtrim(raw(first:k-1));first=k+1;end
 end
 k=k+1;
end
args{end+1}=strtrim(raw(first:end));
end

function ok=captureSupported(step,com,source)
% Reject advanced options that the current search schema cannot reproduce.
% A successful dialog capture must never silently discard signal parameters.
ok=true;
switch step
 case 'resample'
  a=nativeArguments(com,'pop_resample');ok=numel(a)==2;
 case 'baseline'
  a=nativeArguments(com,'pop_rmbase');ok=numel(a)==2;
 case 'reref'
  a=nativeArguments(com,'pop_reref');ok=numel(a)==2;
 case 'artifact_reject'
  a=nativeArguments(com,'pop_eegthresh');
  if numel(a)<7 || numel(a)>9 || ~strcmp(a{2},'1'),ok=false;return;end
  lo=str2double(a{4});hi=str2double(a{5});
  ok=isfinite(lo) && isfinite(hi) && hi>0 && lo==-hi;
  allCh=strcmp(a{3},'1:EEG.nbchan');
  if ~allCh && ~isempty(source) && ~isempty(regexp(a{3},'^[\[\]0-9,\s]+$','once'))
    ch=sscanf(regexprep(a{3},'[\[\],]',' '),'%f')';allCh=isequal(ch,1:source.nbchan);
  end
  whole=strcmp(a{6},'EEG.xmin') && strcmp(a{7},'EEG.xmax');
  if ~whole && ~isempty(source)
    whole=abs(str2double(a{6})-source.xmin)<1e-9 && abs(str2double(a{7})-source.xmax)<1e-9;
  end
  ok=ok && allCh && whole;
 case {'filter','notch'}
  a=nativeArguments(com,'pop_eegfiltnew');
  if numel(a)<3,ok=false;return;end
  if contains(a{2},char(39))
    allowed={'locutoff','hicutoff','plotfreqz','revfilt','filtorder','usefft','minphase'};
    if mod(numel(a)-1,2)~=0,ok=false;return;end
    for k=2:2:numel(a)
      key=strrep(a{k},char(39),'');val=a{k+1};
      if ~ismember(key,allowed),ok=false;return;end
      if ~ismember(key,{'locutoff','hicutoff','plotfreqz','revfilt'}) && ~ismember(val,{'[]','0','false'}),ok=false;return;end
    end
  else
    % Default design order and minimum phase only. Nondefault FIR order is manual-only.
    if numel(a)>=4 && ~strcmp(a{4},'[]'),ok=false;return;end
    if numel(a)>=6 && ~ismember(a{6},{'0','false','[]'}),ok=false;return;end
    if numel(a)>=8 && ~ismember(a{8},{'0','false','[]'}),ok=false;return;end
    if numel(a)>8,ok=false;return;end
  end
 case 'badchannel'
  a=nativeArguments(com,'pop_rejchan'); normOn=false;
  if mod(numel(a)-1,2)~=0,ok=false;return;end
  for k=2:2:numel(a)
    key=strrep(a{k},char(39),''); val=a{k+1};
    if ~ismember(key,{'elec','threshold','norm','measure'}),ok=false;return;end
    if strcmp(key,'norm'),normOn=strcmp(strrep(val,char(39),''),'on');end
    if strcmp(key,'elec') && ~strcmp(val,'1:EEG.nbchan')
      if isempty(source) || isempty(regexp(val,'^[\[\]0-9,\s]+$','once')),ok=false;return;end
      ch=sscanf(regexprep(val,'[\[\],]',' '),'%f')';
      if ~isequal(ch,1:source.nbchan),ok=false;return;end
    end
  end
  ok=normOn;
 case 'auto_reject'
  a=nativeArguments(com,'pop_autorej');
  if mod(numel(a)-1,2)~=0,ok=false;return;end
  for k=2:2:numel(a),if ~ismember(strrep(a{k},char(39),''),{'threshold','nogui'}),ok=false;return;end,end
end
end

function w=strictWindow(raw,label)
tokens=regexp(strtrim(raw),'\s+','split');w=str2double(tokens);
assert(numel(w)==2 && all(isfinite(w)) && w(1)<w(2),'NeuroQC:Contract','%s needs exactly two finite increasing numbers',label);
end

function name=specName(spec)
% Leading name of one component spec ('' when the spec has none).
spec=strtrim(spec);
if isempty(spec),name='';return;end
tok=strsplit(spec,':');
knownTypes={'mean','peak','negative','positive'};
if numel(tok)>1 && any(strcmpi(strtrim(tok{end}),knownTypes)),tok(end)=[];end
if numel(tok)==1,name='';else,name=strtrim(tok{1});end
end

function field=upsertComponent(field,name,spec)
% Replace the component with this name, otherwise append it.
specs=strsplit(char(field),';');
specs=specs(~cellfun(@isempty,cellfun(@strtrim,specs,'UniformOutput',false)));
hit=false;
for k=1:numel(specs)
    if strcmp(specName(specs{k}),name),specs{k}=spec;hit=true;break;end
end
if ~hit,specs{end+1}=spec;end
field=strjoin(specs,'; ');
end
