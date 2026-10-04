classdef SimpleDialog < handle
    %SIMPLEDIALOG Simple mode: three choices, then Run.
    %
    %   opts = pipecompare.gui.SimpleDialog.ask(EEG)   % [] if cancelled
    %
    %   1. Data type, judged from the data (epoched or with events ->
    %      event-related; continuous without events -> band power), with the
    %      reason shown; it can be changed.
    %   2. What is measured: event types and an ERP component (ERP CORE
    %      parameters), or a frequency band. The measure is not
    %      preselected; on epoched data the event types the epochs are
    %      time-locked to are. Selected types are one condition each, or
    %      one condition together; too few events are flagged before Run.
    %   3. Which processing is compared (a recipe). The number of pipelines
    %      it gives for these data is shown live, with the steps left out
    %      and why.
    %   Advanced... opens the full panel with these choices filled in.

    properties
        EEG
        State
        Fig
        TypeDrop; TypeWhy
        EventList; PoolBox; MeasureDrop; SegmentField
        Types; Counts          % the event types offered and how many of each
        RecipeDrop
        CountLabel; NotesLabel
        RunButton
        Answer = []            % the options when Run was pressed
    end

    properties (Constant)
        Choose = '(choose)'
        ErpType = 'Event-related (ERP)'
        BandType = 'Continuous (band power)'
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
            obj.Fig = uifigure('Name', 'Compare preprocessing pipelines', 'Position', [200 200 620 470], ...
                'CloseRequestFcn', @(~, ~) obj.close());
            g = uigridlayout(obj.Fig, [10 2]);
            g.RowHeight = {22, 22, 22, '1x', 22, 22, 22, 22, 44, 30};
            g.ColumnWidth = {150, '1x'};
            uilabel(g, 'Text', '1. Data', 'FontWeight', 'bold');
            erp = s.isEpoched || ~isempty(obj.Types);
            obj.TypeDrop = uidropdown(g, 'Items', {obj.ErpType, obj.BandType}, ...
                'Value', pipecompare.utils.ternary(erp, obj.ErpType, obj.BandType), 'ValueChangedFcn', @(~, ~) obj.typeChanged());
            uilabel(g, 'Text', '');
            obj.TypeWhy = uilabel(g, 'Text', obj.typeReason(), 'FontColor', [0.3 0.3 0.3], 'WordWrap', 'on');
            uilabel(g, 'Text', '2. Measure', 'FontWeight', 'bold');
            obj.MeasureDrop = uidropdown(g, 'ValueChangedFcn', @(~, ~) obj.update());
            l = uilabel(g, 'Text', 'Event types (ERP)', 'VerticalAlignment', 'top'); l.Layout.Row = 4;
            items = arrayfun(@(k) sprintf('%s (%d)', obj.Types{k}, obj.Counts(k)), 1:numel(obj.Types), ...
                'UniformOutput', false);
            % epoched data: the types the epochs are time-locked to, read
            % from the data; continuous data: nothing is preselected
            obj.EventList = uilistbox(g, 'Items', items, 'ItemsData', obj.Types, 'Multiselect', 'on', ...
                'Value', obj.Types(isLock), 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '');
            obj.PoolBox = uicheckbox(g, 'Text', 'Score the selected event types as one condition', ...
                'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', 'Segment (s, band power)');
            obj.SegmentField = uieditfield(g, 'numeric', 'Value', 2, 'Limits', [0.1 600], 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '3. Compare', 'FontWeight', 'bold');
            labels = cellfun(@pipecompare.simple.Presets.recipeLabel, pipecompare.simple.Presets.recipeNames(), 'UniformOutput', false);
            obj.RecipeDrop = uidropdown(g, 'Items', [{obj.Choose} labels], 'ItemsData', [{''} pipecompare.simple.Presets.recipeNames()], ...
                'Value', '', 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '');
            obj.CountLabel = uilabel(g, 'Text', '', 'FontWeight', 'bold');
            uilabel(g, 'Text', '');
            obj.NotesLabel = uilabel(g, 'Text', '', 'FontColor', [0.6 0.3 0], 'WordWrap', 'on', 'VerticalAlignment', 'top');
            uilabel(g, 'Text', '');
            b = uigridlayout(g, [1 3]); b.Padding = [0 0 0 0];
            obj.RunButton = uibutton(b, 'Text', 'Run', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run());
            uibutton(b, 'Text', 'Advanced...', 'ButtonPushedFcn', @(~, ~) obj.advanced());
            uibutton(b, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) obj.close());
            obj.typeChanged();
        end

        function delete(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        function t = typeReason(obj)
            s = obj.State;
            if s.isEpoched
                t = sprintf('The data are epoched (%d epochs).', s.trials);
            elseif ~isempty(obj.Types)
                ev = arrayfun(@(k) sprintf('%s (%d)', obj.Types{k}, obj.Counts(k)), 1:min(6, numel(obj.Types)), ...
                    'UniformOutput', false);
                t = sprintf('Continuous data with events: %s%s.', strjoin(ev, ', '), ...
                    pipecompare.utils.ternary(numel(obj.Types) > 6, ', ...', ''));
            else
                t = 'Continuous data without events.';
            end
        end

        function typeChanged(obj)
            erp = strcmp(obj.TypeDrop.Value, obj.ErpType);
            if erp, names = pipecompare.simple.Presets.componentNames(); else, names = pipecompare.simple.Presets.bandNames(); end
            obj.MeasureDrop.Items = [{obj.Choose} names];
            obj.MeasureDrop.Value = obj.Choose;
            obj.EventList.Enable = pipecompare.utils.ternary(erp, 'on', 'off');
            obj.PoolBox.Enable = obj.EventList.Enable;
            obj.SegmentField.Enable = pipecompare.utils.ternary(erp, 'off', 'on');
            obj.update();
        end

        function o = options(obj)
            % the choices as pop_pipecompare options ([] while incomplete)
            o = [];
            erp = strcmp(obj.TypeDrop.Value, obj.ErpType);
            if strcmp(obj.MeasureDrop.Value, obj.Choose) || isempty(obj.RecipeDrop.Value), return; end
            if erp && isempty(obj.EventList.Value), return; end
            o = struct('measure', obj.MeasureDrop.Value, 'events', {cellstr(obj.EventList.Value)}, ...
                'pool', obj.PoolBox.Value, 'recipe', obj.RecipeDrop.Value, 'segment', obj.SegmentField.Value, 'show', 'on');
            if ~erp, o.events = {}; o.pool = false; end
        end

        function [n, msg] = update(obj)
            % live count of the pipelines the choices give on these data
            n = 0; obj.RunButton.Enable = 'off'; obj.NotesLabel.Text = '';
            o = obj.options();
            if isempty(o)
                obj.CountLabel.Text = 'Choose what to measure and what to compare.'; msg = obj.CountLabel.Text; return;
            end
            if obj.tooFewEvents(o), return; end
            try
                c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, o.events, o.segment, o.pool);
                c.validate(obj.State);
                [plan, notes] = pipecompare.simple.Presets.recipe(o.recipe, obj.State, c);
                [leaves, tree] = plan.enumerate(obj.State, c, struct('maxLeaves', Inf));
                n = numel(leaves);
                nIca = sum(arrayfun(@(k) strcmp(tree(k).inst.type, 'ica'), 2:numel(tree)));   % shared prefixes run once
                maxLeaves = 500;                       % the search's default limit (maxLeaves)
                msg = sprintf('%d pipelines will be compared', n);
                if nIca > 0, msg = sprintf('%s (%d ICA decomposition%s)', msg, nIca, pipecompare.utils.ternary(nIca > 1, 's', '')); end
                if n > maxLeaves
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
            if isempty(o.events), return; end
            d = pipecompare.eval.Rank.defaults(); need = d.minTrials;
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
            % The full panel with what has been chosen so far.
            app = pipecompare.gui.Panel();
            o = obj.options();
            if ~isempty(o)
                c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, o.events, o.segment, o.pool);
                [plan, notes] = pipecompare.simple.Presets.recipe(o.recipe, obj.State, c);
                app.Plan = plan; app.showPlan();
                if strcmp(c.analysis, 'erp')
                    for k = 1:numel(c.conditions), app.addCondition(c.conditions(k).name, c.conditions(k).events); end
                    app.EpochField.Value = sprintf('%g %g', c.epoch); app.BaseField.Value = sprintf('%g %g', c.baseline);
                    comp = c.components(1);
                    app.addComponent(comp.name, comp.window, comp.roi, comp.measure, comp.polarity);
                else
                    pipecompare.utils.log(['The panel defines ERP contracts; a band-power contract is set from a ', ...
                        'script for now (pipecompare.eval.Contract(''analysis'', ''bandpower'', ...)).']);
                end
                app.settingsChanged();
                for k = 1:numel(notes), pipecompare.utils.log('Recipe %s: %s.', o.recipe, notes{k}); end
            end
            obj.close();
        end
    end
end
