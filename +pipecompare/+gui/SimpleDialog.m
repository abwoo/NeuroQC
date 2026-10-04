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
    %      events are flagged before Run.
    %   3. Which processing is compared: Standard is preselected. The
    %      number of pipelines is shown live, with the steps left out and
    %      why.
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
        EventList; PoolBox
        Types; Counts          % the event types offered and how many of each
        RecipeDrop
        CountLabel; NotesLabel
        RunButton
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
            obj.Fig = uifigure('Name', 'Compare preprocessing pipelines', 'Position', [200 200 620 440], ...
                'CloseRequestFcn', @(~, ~) obj.close());
            g = uigridlayout(obj.Fig, [9 2]); obj.Grid = g;
            g.RowHeight = {22, 22, 0, '1x', 22, 22, 22, 44, 30};
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
            l = uilabel(g, 'Text', 'Event types (ERP)', 'VerticalAlignment', 'top'); l.Layout.Row = 4;
            ev = arrayfun(@(k) sprintf('%s (%d)', obj.Types{k}, obj.Counts(k)), 1:numel(obj.Types), ...
                'UniformOutput', false);
            % epoched data: the types the epochs are time-locked to, read
            % from the data; continuous data: nothing is preselected
            obj.EventList = uilistbox(g, 'Items', ev, 'ItemsData', obj.Types, 'Multiselect', 'on', ...
                'Value', obj.Types(isLock), 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '');
            obj.PoolBox = uicheckbox(g, 'Text', 'Score the selected event types as one condition', ...
                'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '3. Compare', 'FontWeight', 'bold');
            labels = cellfun(@pipecompare.simple.Presets.recipeLabel, pipecompare.simple.Presets.recipeNames(), 'UniformOutput', false);
            obj.RecipeDrop = uidropdown(g, 'Items', labels, 'ItemsData', pipecompare.simple.Presets.recipeNames(), ...
                'Value', 'standard', 'ValueChangedFcn', @(~, ~) obj.update());
            uilabel(g, 'Text', '');
            obj.CountLabel = uilabel(g, 'Text', '', 'FontWeight', 'bold');
            uilabel(g, 'Text', '');
            obj.NotesLabel = uilabel(g, 'Text', '', 'FontColor', [0.6 0.3 0], 'WordWrap', 'on', 'VerticalAlignment', 'top');
            uilabel(g, 'Text', '');
            b = uigridlayout(g, [1 3]); b.Padding = [0 0 0 0];
            obj.RunButton = uibutton(b, 'Text', 'Run', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run());
            uibutton(b, 'Text', 'Advanced...', 'ButtonPushedFcn', @(~, ~) obj.advanced());
            uibutton(b, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) obj.close());
            obj.measureChanged();
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
                obj.ChannelsFor = m;
            end
            obj.showChannels();
            erp = obj.isErp() || strcmp(m, obj.Choose);
            obj.EventList.Enable = pipecompare.utils.ternary(erp, 'on', 'off');
            obj.PoolBox.Enable = obj.EventList.Enable;
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
            if erp && isempty(obj.EventList.Value), return; end
            o = struct('measure', m, 'events', {cellstr(obj.EventList.Value)}, 'pool', obj.PoolBox.Value, ...
                'window', [], 'band', [], 'channels', {{}}, 'recipe', obj.RecipeDrop.Value, 'segment', 2, 'show', 'on');
            if ~erp, o.events = {}; o.pool = false; end
            if any(strcmp(m, {obj.CustomErp, obj.CustomBand}))
                v = sscanf(strrep(obj.WindowField.Value, ',', ' '), '%f')';
                if numel(v) ~= 2 || isempty(obj.Channels), o = []; return; end
                o.channels = obj.Channels;
                if strcmp(m, obj.CustomErp), o.window = v / 1000; else, o.band = v; end
            end
        end

        function c = contract(obj, o)
            c = pipecompare.simple.Presets.contract(obj.EEG, o.measure, o.events, o.segment, o.pool, ...
                struct('window', o.window, 'band', o.band, 'channels', {o.channels}));
        end

        function [n, msg] = update(obj)
            % live count of the pipelines the choices give on these data
            n = 0; obj.RunButton.Enable = 'off'; obj.NotesLabel.Text = '';
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
                [plan, notes] = pipecompare.simple.Presets.recipe(o.recipe, obj.State, c);
                [leaves, tree] = plan.enumerate(obj.State, c, struct('maxLeaves', Inf));
                n = numel(leaves);
                nIca = sum(arrayfun(@(k) strcmp(tree(k).inst.type, 'ica'), 2:numel(tree)));   % shared prefixes run once
                maxLeaves = 500;                       % the search's default limit (maxLeaves)
                msg = sprintf('%d pipelines will be compared', n);
                if nIca > 0, msg = sprintf('%s (%d ICA decomposition%s)', msg, nIca, pipecompare.utils.ternary(nIca > 1, 's', '')); end
                if n < 2
                    msg = sprintf('Only %d pipeline: nothing to compare. Choose Standard.', n);
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
                c = obj.contract(o);
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
