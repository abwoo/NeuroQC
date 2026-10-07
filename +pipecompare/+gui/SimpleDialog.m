classdef SimpleDialog < handle
    %SIMPLEDIALOG Simple mode: what to measure, then Run.
    %
    %   opts = pipecompare.gui.SimpleDialog.ask(EEG)   % [] if cancelled
    %
    %   1. The data, described in one line (epoched, events, or neither).
    %   2. What is measured: the measures these data support, in one list:
    %      ERP components (ERP CORE parameters) when there are events or
    %      epochs, frequency bands on continuous data, and for each your
    %      own window or band with the electrodes you pick. ERP: the event
    %      types (the epochs' time-locking types are preselected on epoched
    %      data); each is one condition, or one condition together; too few
    %      events are flagged before Run. N2pc and LRP (contralateral
    %      minus ipsilateral) take the event types of each side in two
    %      lists: target on the left / right, left / right hand.
    %   3. Which steps are compared: a list in the order they run (bad
    %      channels, reference, ICA, high-pass, low-pass, epochs, epoch
    %      rejection); tick any of them, or one of the two recipes
    %      (Standard, preselected: all; Filters only). The order is
    %      fixed. Steps these data cannot take are greyed out with the
    %      reason (e.g. filters on epoched data), and the bad channels are
    %      always detected before an average reference. The number of
    %      pipelines is shown live, with the steps left out and why.
    %   Advanced... opens the full panel with these choices filled in.

    properties
        EEG
        State
        Fig
        TypeWhy
        MeasureDrop
        CustomLabel; WindowField; ChannelLabel
        Channels = {}          % electrodes of a custom measure
        ChannelsFor = ''       % which custom measure they were chosen for
        EventLabel; EventList; RightList; EventGrid; PoolBox
        Types; Counts          % the event types offered and how many of each
        StepBoxes; StepNotes   % one per Presets.stepNames, in that order
        Ticks                  % the steps ticked (shown unticked while the data cannot take them)
        Why; Info              % per step: why the data cannot take it, what to know about it
        EpochBox; RefDrop
        CountLabel; NotesLabel
        RunButton; AdvancedButton
        Answer = []            % the options when Run was pressed
        Grid
    end

    properties (Constant)
        Choose = '(choose)'
        CustomErp = 'custom'   % your own window and electrodes (pop_pipecompare 'measure')
        CustomBand = 'band'    % your own band and electrodes
    end

    methods (Static)
        function opts = ask(EEG)
            d = pipecompare.gui.SimpleDialog(EEG);
            c = onCleanup(@() delete(d));
            uiwait(d.Fig);
            opts = d.Answer;
        end
    end

    methods
        function obj = SimpleDialog(EEG)
            obj.EEG = EEG;
            obj.State = pipecompare.live.DataState.fromEEG(EEG);
            s = obj.State;
            % boundary markers (removed segments, merged files) are not
            % time-locking events; on epoched data an event counts once
            % per epoch it time-locks
            keep = ~strcmpi(s.eventTypes, 'boundary');
            obj.Types = s.eventTypes(keep); obj.Counts = s.eventCounts(keep);
            [isLock, at] = ismember(obj.Types, s.lockingTypes);
            obj.Counts(isLock) = s.lockingCounts(at(isLock));
            obj.Fig = uifigure('Name', 'Compare preprocessing pipelines', 'Position', [200 120 720 640], ...
                'CloseRequestFcn', @(~, ~) obj.close());
            g = uigridlayout(obj.Fig, [9 2]); obj.Grid = g;
            g.RowHeight = {'fit', 22, 0, '1x', 22, 'fit', 22, 44, 30};
            g.ColumnWidth = {150, '1x'};
            uilabel(g, 'Text', '1. Data', 'FontWeight', 'bold');
            obj.TypeWhy = uilabel(g, 'Text', obj.typeReason(), 'FontColor', [0.3 0.3 0.3], 'WordWrap', 'on');
            uilabel(g, 'Text', '2. Measure', 'FontWeight', 'bold');
            [items, data] = obj.measures();
            obj.MeasureDrop = uidropdown(g, 'Items', [{obj.Choose} items], 'ItemsData', [{obj.Choose} data], ...
                'Value', obj.Choose, 'ValueChangedFcn', @(~, ~) obj.measureChanged());
            obj.CustomLabel = uilabel(g, 'Text', 'Window (ms)');
            r = uigridlayout(g, [1 3]); r.Padding = [0 0 0 0]; r.ColumnWidth = {120, 110, '1x'};
            obj.WindowField = uieditfield(r, 'text', 'Placeholder', 'e.g. 300 600', 'ValueChangedFcn', @(~, ~) obj.update());
            uibutton(r, 'Text', 'Electrodes...', 'ButtonPushedFcn', @(~, ~) obj.pickChannels());
            obj.ChannelLabel = uilabel(r, 'Text', '', 'FontColor', [0.3 0.3 0.3]);
            obj.EventLabel = uilabel(g, 'Text', 'Event types (ERP)', 'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.EventLabel.Layout.Row = 4;
            ev = arrayfun(@(k) sprintf('%s (%d)', obj.Types{k}, obj.Counts(k)), 1:numel(obj.Types), ...
                'UniformOutput', false);
            % epoched data: the types the epochs are time-locked to, read
            % from the data; continuous data: nothing is preselected. The
            % second list (right side) is shown for N2pc and LRP only.
            obj.EventGrid = uigridlayout(g, [1 2]); obj.EventGrid.Padding = [0 0 0 0];
            obj.EventGrid.ColumnWidth = {'1x', 0};
            obj.EventList = uilistbox(obj.EventGrid, 'Items', ev, 'ItemsData', obj.Types, 'Multiselect', 'on', ...
                'Value', obj.Types(isLock), 'ValueChangedFcn', @(~, ~) obj.update());
            obj.RightList = uilistbox(obj.EventGrid, 'Items', ev, 'ItemsData', obj.Types, 'Multiselect', 'on', ...
                'Value', {}, 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '');
            obj.PoolBox = uicheckbox(g, 'Text', 'Score the selected event types as one condition', ...
                'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '3. Compare (steps run in this order)', 'FontWeight', 'bold', 'WordWrap', 'on', ...
                'VerticalAlignment', 'top');
            obj.stepList(g);
            uilabel(g, 'Text', '');
            obj.CountLabel = uilabel(g, 'Text', '', 'FontWeight', 'bold');
            uilabel(g, 'Text', '');
            obj.NotesLabel = uilabel(g, 'Text', '', 'FontColor', [0.6 0.3 0], 'WordWrap', 'on', 'VerticalAlignment', 'top');
            uilabel(g, 'Text', '');
            b = uigridlayout(g, [1 3]); b.Padding = [0 0 0 0];
            obj.RunButton = uibutton(b, 'Text', 'Run', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run());
            obj.AdvancedButton = uibutton(b, 'Text', 'Advanced...', 'ButtonPushedFcn', @(~, ~) obj.advanced());
            uibutton(b, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) obj.close());
            obj.measureChanged();
        end

        function stepList(obj, g)
            % The steps in the order they run: a tick box for each step
            % that can be compared, the reference (fixed, not compared) and
            % the epochs (always); next to each, why the data cannot take
            % it or what to know about it.
            P = pipecompare.simple.Presets;
            names = P.stepNames();
            [obj.Why, obj.Info] = P.stepAvailability(obj.State);
            obj.Ticks = true(1, numel(names));            % Standard
            obj.StepBoxes = gobjects(1, numel(names)); obj.StepNotes = gobjects(1, numel(names));
            s = uigridlayout(g, [8 2]); s.Padding = [0 0 0 0]; s.RowSpacing = 4;
            s.RowHeight = repmat({22}, 1, 8); s.ColumnWidth = {330, '1x'};
            b = uigridlayout(s, [1 3]); b.Padding = [0 0 0 0]; b.ColumnWidth = {'fit', 'fit', '1x'};
            b.Layout.Row = 1; b.Layout.Column = [1 2];
            uibutton(b, 'Text', 'Standard (all)', 'ButtonPushedFcn', @(~, ~) obj.usePreset('standard'));
            uibutton(b, 'Text', 'Filters only', 'ButtonPushedFcn', @(~, ~) obj.usePreset('filters'));
            grey = [0.3 0.3 0.3];
            uilabel(b, 'Text', 'or tick the steps you want', 'FontColor', grey);
            % rows: bad channels, reference, ICA, high-pass, low-pass, epochs, rejection
            rows = [2 4 5 6 8];
            for k = 1:numel(names)
                h = uicheckbox(s, 'Text', P.stepLabel(names{k}), 'Value', true, ...
                    'ValueChangedFcn', @(h, ~) obj.tick(k, h.Value));
                h.Layout.Row = rows(k); h.Layout.Column = 1; obj.StepBoxes(k) = h;
                l = uilabel(s, 'Text', '', 'FontColor', grey);
                l.Layout.Row = rows(k); l.Layout.Column = 2; obj.StepNotes(k) = l;
            end
            % fixed in every pipeline (not compared): it changes what is measured
            obj.RefDrop = uidropdown(s, 'Items', {'Reference: as recorded', 'Reference: average'}, ...
                'ItemsData', {'asis', 'average'}, 'Value', 'asis', 'ValueChangedFcn', @(~, ~) obj.update());
            obj.RefDrop.Layout.Row = 3; obj.RefDrop.Layout.Column = 1;
            l = uilabel(s, 'Text', 'fixed in every pipeline, not compared', 'FontColor', grey);
            l.Layout.Row = 3; l.Layout.Column = 2;
            obj.EpochBox = uicheckbox(s, 'Text', 'Epochs and baseline', 'Value', true, 'Enable', 'off');
            obj.EpochBox.Layout.Row = 7; obj.EpochBox.Layout.Column = 1;
            l = uilabel(s, 'Text', 'always', 'FontColor', grey);
            l.Layout.Row = 7; l.Layout.Column = 2;
        end

        function usePreset(obj, name)
            % tick the steps of a recipe (Standard, Filters only)
            obj.Ticks = ismember(pipecompare.simple.Presets.stepNames(), pipecompare.simple.Presets.recipeSteps(name));
            obj.update();
        end

        function tick(obj, k, value)
            obj.Ticks(k) = value;
            obj.update();
        end

        function steps = chosenSteps(obj)
            % the steps ticked
            steps = pipecompare.simple.Presets.stepNames();
            steps = steps(obj.Ticks);
        end

        function showSteps(obj)
            % the tick boxes as the data and the reference allow them
            names = pipecompare.simple.Presets.stepNames();
            averaged = any(strcmpi(pipecompare.utils.fieldOr(obj.State, 'reference', ''), {'average', 'averef'}));
            average = strcmp(obj.RefDrop.Value, 'average') || averaged;
            for k = 1:numel(names)
                why = obj.Why.(names{k});
                b = obj.StepBoxes(k); note = obj.StepNotes(k);
                if ~isempty(why)
                    b.Value = false; b.Enable = 'off'; note.Text = why;
                elseif strcmp(names{k}, 'badchannels') && average
                    % a bad channel in the average spreads into every channel
                    b.Value = true; b.Enable = 'off';
                    note.Text = 'always before an average reference';
                else
                    b.Value = obj.Ticks(k); b.Enable = 'on'; note.Text = obj.Info.(names{k});
                end
            end
            m = obj.MeasureDrop.Value;
            if pipecompare.simple.Presets.isBand(m)
                obj.EpochBox.Text = 'Cut into segments';
            elseif obj.State.isEpoched
                obj.EpochBox.Text = 'Baseline (the data are already epoched)';
            else
                obj.EpochBox.Text = 'Epochs and baseline';
            end
        end

        function delete(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        function t = typeReason(obj)
            s = obj.State;
            if s.isEpoched
                t = sprintf('Epoched data (%d epochs): ERP measures.', s.trials);
            elseif ~isempty(obj.Types)
                t = sprintf('Continuous data with %d event type%s: ERP measures or band power.', numel(obj.Types), ...
                    pipecompare.utils.ternary(numel(obj.Types) > 1, 's', ''));
            else
                t = 'Continuous data without events: band power.';
            end
            % where PipeCompare starts, and what was done before it
            t = strjoin([{t} pipecompare.simple.Presets.dataAdvice(s)], ' ');
        end

        function [items, data] = measures(obj)
            % The measures these data support: ERP needs events or epochs,
            % band power continuous data.
            P = pipecompare.simple.Presets;
            items = {}; data = {};
            if obj.State.isEpoched || ~isempty(obj.Types)
                for n = P.componentNames()
                    p = P.component(n{1});
                    items{end+1} = sprintf('ERP: %s (%s, %g-%g ms)', p.name, strjoin(p.sites, '/'), 1000 * p.window); %#ok<AGROW>
                    data{end+1} = p.name; %#ok<AGROW>
                end
                items{end+1} = 'ERP: your own window and electrodes...'; data{end+1} = obj.CustomErp;
            end
            if ~obj.State.isEpoched
                for n = P.bandNames()
                    items{end+1} = sprintf('Band power: %s (%g-%g Hz)', n{1}, P.band(n{1})); %#ok<AGROW>
                    data{end+1} = n{1}; %#ok<AGROW>
                end
                items{end+1} = 'Band power: your own band and electrodes...'; data{end+1} = obj.CustomBand;
            end
        end

        function erp = isErp(obj)
            m = obj.MeasureDrop.Value;
            erp = ~strcmp(m, obj.Choose) && ~pipecompare.simple.Presets.isBand(m);
        end

        function measureChanged(obj)
            m = obj.MeasureDrop.Value;
            custom = any(strcmp(m, {obj.CustomErp, obj.CustomBand}));
            obj.Grid.RowHeight{3} = pipecompare.utils.ternary(custom, 22, 0);
            obj.CustomLabel.Text = pipecompare.utils.ternary(strcmp(m, obj.CustomBand), 'Band (Hz)', 'Window (ms)');
            obj.WindowField.Placeholder = pipecompare.utils.ternary(strcmp(m, obj.CustomBand), 'e.g. 8 12', 'e.g. 300 600');
            if custom && ~strcmp(m, obj.ChannelsFor)
                % a band starts from all EEG channels, as the preset bands;
                % a window from none
                obj.Channels = {};
                if strcmp(m, obj.CustomBand), obj.Channels = pipecompare.simple.Presets.eegChannels(obj.EEG); end
                obj.WindowField.Value = '';   % ms of a window are not Hz of a band
                obj.ChannelsFor = m;
            end
            obj.showChannels();
            erp = obj.isErp() || strcmp(m, obj.Choose);
            lateral = pipecompare.simple.Presets.isLateral(m);
            obj.EventGrid.ColumnWidth{2} = pipecompare.utils.ternary(lateral, '1x', 0);
            obj.EventLabel.Text = 'Event types (ERP)';
            if lateral
                side = pipecompare.utils.ternary(strcmp(m, 'LRP'), 'hand', 'target');
                obj.EventLabel.Text = sprintf('Event types: left %s | right %s (contralateral minus ipsilateral)', side, side);
            end
            obj.EventList.Enable = pipecompare.utils.ternary(erp, 'on', 'off');
            obj.RightList.Enable = obj.EventList.Enable;
            obj.PoolBox.Enable = pipecompare.utils.ternary(erp && ~lateral, 'on', 'off');   % one condition per side
            obj.update();
        end

        function pickChannels(obj)
            % EEGLAB's channel selection over the dataset's channels.
            labels = {obj.EEG.chanlocs.labels};
            [~, sel] = ismember(lower(obj.Channels), lower(labels));
            [idx, ~, names] = pop_chansel(labels, 'withindex', 'on', 'select', sel(sel > 0));
            if ~isempty(idx), obj.Channels = labels(idx); elseif iscell(names) && ~isempty(names), obj.Channels = names; end
            obj.showChannels(); obj.update();
        end

        function showChannels(obj)
            c = obj.Channels;
            if isempty(c), t = 'no electrodes chosen';
            elseif numel(c) <= 6, t = strjoin(c, ' ');
            else, t = sprintf('%d electrodes', numel(c)); end
            obj.ChannelLabel.Text = t;
        end

        function o = options(obj)
            % the choices as pop_pipecompare options ([] while incomplete)
            o = [];
            m = obj.MeasureDrop.Value;
            if strcmp(m, obj.Choose), return; end
            erp = obj.isErp();
            lateral = pipecompare.simple.Presets.isLateral(m);
            if erp && isempty(obj.EventList.Value) && ~(lateral && ~isempty(obj.RightList.Value)), return; end
            steps = obj.chosenSteps();
            o = struct('measure', m, 'events', {cellstr(obj.EventList.Value)}, 'left', {{}}, 'right', {{}}, ...
                'pool', obj.PoolBox.Value, 'window', [], 'band', [], 'channels', {{}}, ...
                'recipe', pipecompare.simple.Presets.recipeOf(steps), 'steps', {steps}, ...
                'reference', obj.RefDrop.Value, 'segment', 2, 'show', 'on');
            if ~erp, o.events = {}; o.pool = false; end
            if lateral
                o.left = cellstr(obj.EventList.Value); o.right = cellstr(obj.RightList.Value);
                o.events = {}; o.pool = false;
            end
            if any(strcmp(m, {obj.CustomErp, obj.CustomBand}))
                v = sscanf(strrep(obj.WindowField.Value, ',', ' '), '%f')';
                if numel(v) ~= 2 || isempty(obj.Channels), o = []; return; end
                o.channels = obj.Channels;
                if strcmp(m, obj.CustomErp), o.window = v / 1000; else, o.band = v; end
            end
        end

        function c = contract(obj, o)
            events = o.events;
            if pipecompare.simple.Presets.isLateral(o.measure), events = struct('left', {o.left}, 'right', {o.right}); end
            c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, events, o.segment, o.pool, ...
                struct('window', o.window, 'band', o.band, 'channels', {o.channels}));
        end

        function [n, msg] = update(obj)
            % live count of the pipelines the choices give on these data
            n = 0; obj.RunButton.Enable = 'off'; obj.NotesLabel.Text = '';
            obj.showSteps();
            o = obj.options();
            if isempty(o)
                msg = 'Choose what to measure.';
                if any(strcmp(obj.MeasureDrop.Value, {obj.CustomErp, obj.CustomBand}))
                    msg = 'Enter two numbers and choose the electrodes.';
                elseif obj.isErp()
                    msg = 'Choose the event types.';
                end
                obj.CountLabel.Text = msg; return;
            end
            if obj.tooFewEvents(o), msg = obj.CountLabel.Text; return; end
            try
                c = obj.contract(o);
                c.validate(obj.State);
                [plan, notes] = pipecompare.simple.Presets.recipe(o.steps, obj.State, c, o.reference, ...
                    pipecompare.simple.Presets.nonEegChannels(obj.EEG));
                [leaves, tree] = plan.enumerate(obj.State, c, struct('maxLeaves', Inf));
                n = numel(leaves);
                nIca = sum(arrayfun(@(k) strcmp(tree(k).inst.type, 'ica'), 2:numel(tree)));   % shared prefixes run once
                maxLeaves = pipecompare.plan.Plan.MaxLeaves;   % the search's default limit
                msg = sprintf('%d pipelines will be compared', n);
                if nIca > 0, msg = sprintf('%s (%d ICA decomposition%s)', msg, nIca, pipecompare.utils.ternary(nIca > 1, 's', '')); end
                if n < 2
                    msg = sprintf('Only %d pipeline: nothing to compare. Tick more steps.', n);
                elseif n > maxLeaves
                    msg = sprintf('%s: above the limit of %d. Use Advanced... to fix some values.', msg, maxLeaves);
                else
                    obj.RunButton.Enable = 'on';
                end
                obj.CountLabel.Text = msg;
                if ~isempty(notes), obj.NotesLabel.Text = ['Left out: ' strjoin(notes, '; ') '.']; end
            catch ME
                msg = ME.message; obj.CountLabel.Text = 'Cannot run these choices:'; obj.NotesLabel.Text = msg;
            end
        end

        function short = tooFewEvents(obj, o)
            % A condition with fewer events than the search requires trials
            % would exclude every pipeline, which would only show after the
            % run: say so now, with the way out when there is one.
            short = false;
            d = pipecompare.eval.Rank.defaults(); need = d.minTrials;
            if pipecompare.simple.Presets.isLateral(o.measure)
                % one condition per side: its event types together
                sides = {'left', 'right'};
                for k = 1:2
                    [~, at] = ismember(o.(sides{k}), obj.Types); n = sum(obj.Counts(at(at > 0)));
                    if isempty(o.(sides{k})) || n >= need, continue; end
                    short = true;
                    obj.CountLabel.Text = 'Too few events for a condition.';
                    obj.NotesLabel.Text = sprintf('The %s side has %d events; each side needs at least %d.', sides{k}, n, need);
                    return;
                end
                return;
            end
            if isempty(o.events), return; end
            [~, at] = ismember(o.events, obj.Types);
            n = obj.Counts(at(at > 0));
            if o.pool, few = sum(n) < need; else, few = any(n < need); end
            if ~few, return; end
            short = true;
            obj.CountLabel.Text = 'Too few events for a condition.';
            if o.pool
                obj.NotesLabel.Text = sprintf('The selected types have %d events together; a condition needs at least %d.', sum(n), need);
                return;
            end
            k = find(n < need, 1);
            t = sprintf('%s has %d events; each condition needs at least %d.', o.events{k}, n(k), need);
            if numel(o.events) > 1 && sum(n) >= need
                t = sprintf('%s If these types are one condition (e.g. one code per block), tick "Score the selected event types as one condition".', t);
            end
            obj.NotesLabel.Text = t;
        end

        function run(obj)
            obj.Answer = obj.options();
            uiresume(obj.Fig); obj.Fig.Visible = 'off';
        end

        function close(obj)
            obj.Answer = [];
            if isvalid(obj.Fig), uiresume(obj.Fig); obj.Fig.Visible = 'off'; end
        end

        function app = advanced(obj)
            % The full panel with what has been chosen so far; choices the
            % panel cannot take are said here, and the dialog stays open.
            app = [];
            o = obj.options(); c = [];
            if ~isempty(o)
                try
                    c = obj.contract(o);
                catch ME
                    uialert(obj.Fig, ME.message, 'PipeCompare'); return;
                end
            end
            app = pipecompare.gui.Panel();
            if ~isempty(c)
                [plan, notes] = pipecompare.simple.Presets.recipe(o.steps, obj.State, c, o.reference, ...
                    pipecompare.simple.Presets.nonEegChannels(obj.EEG));
                app.Plan = plan;
                if strcmp(c.analysis, 'bandpower')
                    app.AnalysisDrop.Value = 'bandpower'; app.SegField.Value = c.segment; app.analysisChanged();
                    b = c.bands(1);
                    app.addBand(b.name, b.freq, b.roi);
                else
                    for k = 1:numel(c.conditions), app.addCondition(c.conditions(k).name, c.conditions(k).events); end
                    app.EpochField.Value = sprintf('%g %g', c.epoch); app.BaseField.Value = sprintf('%g %g', c.baseline);
                    comp = c.components(1); contra = {};
                    if c.isLateral(1), contra = comp.contra; end
                    app.addComponent(comp.name, comp.window, comp.roi, comp.measure, comp.polarity, contra);
                end
                app.showPlan();   % after the fields: the epoch and baseline rows show them
                app.settingsChanged();
                for k = 1:numel(notes), pipecompare.utils.log('Left out: %s.', notes{k}); end
            end
            obj.close();
        end
    end
end
