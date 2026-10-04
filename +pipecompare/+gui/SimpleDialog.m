classdef SimpleDialog < handle
    %SIMPLEDIALOG Simple mode: three choices, then Run.
    %
    %   opts = pipecompare.gui.SimpleDialog.ask(EEG)   % [] if cancelled
    %
    %   1. Data type, judged from the data (epoched or with events ->
    %      event-related; continuous without events -> band power), with the
    %      reason shown; it can be changed.
    %   2. What is measured: event types and an ERP component (ERP CORE
    %      parameters), or a frequency band. Nothing is preselected.
    %   3. Which processing is compared (a recipe). The number of pipelines
    %      it gives for these data is shown live, with the steps left out
    %      and why.
    %   Advanced... opens the full panel with these choices filled in.

    properties
        EEG
        State
        Fig
        TypeDrop; TypeWhy
        EventList; MeasureDrop; SegmentField
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
            obj.Fig = uifigure('Name', 'Compare preprocessing pipelines', 'Position', [200 200 620 470], ...
                'CloseRequestFcn', @(~, ~) obj.close());
            g = uigridlayout(obj.Fig, [9 2]);
            g.RowHeight = {22, 22, 22, '1x', 22, 22, 22, 44, 30};
            g.ColumnWidth = {150, '1x'};
            uilabel(g, 'Text', '1. Data', 'FontWeight', 'bold');
            erp = s.isEpoched || s.nEvents > 0;
            obj.TypeDrop = uidropdown(g, 'Items', {obj.ErpType, obj.BandType}, ...
                'Value', pipecompare.utils.ternary(erp, obj.ErpType, obj.BandType), 'ValueChangedFcn', @(~, ~) obj.typeChanged());
            uilabel(g, 'Text', '');
            obj.TypeWhy = uilabel(g, 'Text', obj.typeReason(), 'FontColor', [0.3 0.3 0.3], 'WordWrap', 'on');
            uilabel(g, 'Text', '2. Measure', 'FontWeight', 'bold');
            obj.MeasureDrop = uidropdown(g, 'ValueChangedFcn', @(~, ~) obj.update());
            l = uilabel(g, 'Text', 'Event types (ERP)', 'VerticalAlignment', 'top'); l.Layout.Row = 4;
            items = arrayfun(@(k) sprintf('%s (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:numel(s.eventTypes), ...
                'UniformOutput', false);
            obj.EventList = uilistbox(g, 'Items', items, 'ItemsData', s.eventTypes, 'Multiselect', 'on', ...
                'Value', {}, 'ValueChangedFcn', @(~, ~) obj.update());
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
            elseif s.nEvents > 0
                ev = arrayfun(@(k) sprintf('%s (%d)', s.eventTypes{k}, s.eventCounts(k)), 1:min(6, numel(s.eventTypes)), ...
                    'UniformOutput', false);
                t = sprintf('Continuous data with events: %s%s.', strjoin(ev, ', '), ...
                    pipecompare.utils.ternary(numel(s.eventTypes) > 6, ', ...', ''));
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
                'recipe', obj.RecipeDrop.Value, 'segment', obj.SegmentField.Value, 'show', 'on');
            if ~erp, o.events = {}; end
        end

        function [n, msg] = update(obj)
            % live count of the pipelines the choices give on these data
            n = 0; obj.RunButton.Enable = 'off'; obj.NotesLabel.Text = '';
            o = obj.options();
            if isempty(o)
                obj.CountLabel.Text = 'Choose what to measure and what to compare.'; msg = obj.CountLabel.Text; return;
            end
            try
                c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, o.events, o.segment);
                c.validate(obj.State);
                [plan, notes] = pipecompare.simple.Presets.recipe(o.recipe, obj.State, c);
                [leaves, tree] = plan.enumerate(obj.State, c, struct('maxLeaves', Inf));
                n = numel(leaves);
                nIca = sum(arrayfun(@(k) strcmp(tree(k).inst.type, 'ica'), 2:numel(tree)));   % shared prefixes run once
                maxLeaves = 500;                       % the search's default limit (maxLeaves)
                msg = sprintf('%d pipelines will be compared', n);
                if nIca > 0, msg = sprintf('%s (%d ICA decompositions)', msg, nIca); end
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
                c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, o.events, o.segment);
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
