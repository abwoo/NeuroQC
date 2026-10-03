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
        PlanTable; TypeDrop; OrderDrop
        CondField; EpochField; BaseField; CompField; EventsLabel
        LimitFields = struct()
        ObjectiveField
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
            g.RowHeight = {80, '1x', '1x'}; g.ColumnWidth = {'1x', '1.25x'};

            top = uigridlayout(g, [1 2]); top.Layout.Column = [1 2]; top.ColumnWidth = {'1x', '1x'}; top.Padding = [0 0 0 0];
            obj.DatasetLabel = uilabel(top, 'Text', 'No dataset', 'FontName', 'Courier', 'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.WarnArea = uitextarea(top, 'Editable', 'off', 'FontColor', [0.6 0.2 0], 'Value', {''});

            % history (left, rows 2-3)
            hp = uipanel(g, 'Title', 'EEG.history of the current dataset (live)'); hp.Layout.Row = [2 3]; hp.Layout.Column = 1;
            hg = uigridlayout(hp, [1 1]);
            obj.HistTable = uitable(hg, 'ColumnName', {'line','kind','step','statement'}, ...
                'ColumnWidth', {40, 60, 95, 'auto'}, 'RowName', {});

            % plan (right, row 2)
            pp = uipanel(g, 'Title', 'Plan: steps after the current dataset (fixed = one value, search = {list})');
            pp.Layout.Row = 2; pp.Layout.Column = 2;
            pg = uigridlayout(pp, [3 1]); pg.RowHeight = {'1x', 28, 28};
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
            b2 = uigridlayout(pg, [1 3]); b2.Padding = [0 0 0 0];
            uibutton(b2, 'Text', 'Fix via EEGLAB dialog', 'Tooltip', ...
                'Open the native EEGLAB dialog for the selected step; its command replaces the step as a fixed native step', ...
                'ButtonPushedFcn', @(~, ~) obj.captureStep());
            uibutton(b2, 'Text', 'Apply now in EEGLAB', 'Tooltip', ...
                'Run the selected step on the current dataset through the EEGLAB dialog (recorded in EEG.history); the plan then starts after it', ...
                'ButtonPushedFcn', @(~, ~) obj.applyNow());
            uibutton(b2, 'Text', 'Catalog help', 'ButtonPushedFcn', @(~, ~) obj.catalogHelp());

            % contract + run + results (right, row 3)
            rp = uipanel(g, 'Title', 'Analysis contract, constraints, results'); rp.Layout.Row = 3; rp.Layout.Column = 2;
            rg = uigridlayout(rp, [4 1]); rg.RowHeight = {84, 30, 28, '1x'};
            cg = uigridlayout(rg, [3 4]); cg.Padding = [0 0 0 0]; cg.ColumnWidth = {80, '1x', 70, 110};
            uilabel(cg, 'Text', 'Conditions');
            obj.CondField = uieditfield(cg, 'Placeholder', 'target: 11 21; standard: 31');
            uilabel(cg, 'Text', 'Epoch (s)'); obj.EpochField = uieditfield(cg, 'Value', '-0.2 1');
            uilabel(cg, 'Text', 'Components');
            obj.CompField = uieditfield(cg, 'Placeholder', 'P3: 0.3 0.6 @ Pz CPz POz; N2: 0.2 0.3 @ Fz FCz');
            uilabel(cg, 'Text', 'Baseline (s)'); obj.BaseField = uieditfield(cg, 'Value', '-0.2 0');
            obj.EventsLabel = uilabel(cg, 'Text', 'Event types: -', 'FontColor', [0.3 0.3 0.3]);
            obj.EventsLabel.Layout.Column = [1 4];
            lg = uigridlayout(rg, [1 18]); lg.Padding = [0 0 0 0];
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
            ag = uigridlayout(rg, [1 7]); ag.Padding = [0 0 0 0];
            uilabel(ag, 'Text', 'Objective', 'HorizontalAlignment', 'right');
            obj.ObjectiveField = uieditfield(ag, 'Value', 'composite', 'Tooltip', ...
                'composite | pareto | priority list, e.g. P3.mean, N2.peakLatency');
            uibutton(ag, 'Text', 'Preview count', 'ButtonPushedFcn', @(~, ~) obj.run(true));
            uibutton(ag, 'Text', 'Run search', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.run(false));
            uibutton(ag, 'Text', 'Adopt selected as new dataset', 'ButtonPushedFcn', @(~, ~) obj.adopt());
            uibutton(ag, 'Text', 'Print script of selected', 'ButtonPushedFcn', @(~, ~) obj.printScript());
            obj.StatusLabel = uilabel(ag, 'Text', '', 'FontColor', [0 0 0.5]);
            obj.ResultTable = uitable(rg, 'RowName', {}, 'ColumnName', ...
                {'id','status','objective','diff CI','not distinguished','P(best)','min ret','interp','amp err','art','pipeline / reason'}, ...
                'ColumnWidth', {35, 70, 65, 120, 45, 50, 55, 50, 55, 45, 'auto'});
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
            if ~force, neuroqc.utils.log('Current EEGLAB dataset changed: %s (%d history entries).', s.setname, numel(h)); end
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
        end

        function addStep(obj)
            obj.Plan = obj.Plan.add(obj.TypeDrop.Value);
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
            obj.Plan = obj.Plan.remove(obj.Plan.Slots(k).id); obj.showPlan();
        end

        function moveStep(obj, d)
            k = obj.selected(); if isempty(k), return; end
            obj.Plan = obj.Plan.move(obj.Plan.Slots(k).id, d); obj.showPlan();
        end

        function setOrder(obj, v)
            obj.Plan.OrderMode = v;
        end

        function planEdited(obj, e)
            k = e.Indices(1);
            try
                if e.Indices(2) == 4
                    obj.Plan.Slots(k).pinned = logical(e.NewData);
                else
                    slot = obj.Plan.Slots(k);
                    assert(numel(slot.alternatives) == 1, 'NeuroQC:Plan', 'Edit choice steps from the command line (Plan.addChoice).');
                    p = parseSettings(e.NewData);
                    obj.Plan.Slots(k).alternatives{1}.params = p;
                end
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC'); obj.showPlan();
            end
        end

        function captureStep(obj)
            k = obj.selected(); if isempty(k), return; end
            slot = obj.Plan.Slots(k);
            type = slot.alternatives{1}.type;
            ok = {'resample','highpass','lowpass','linenoise','asr','badchannels','restore','reref','ica'};
            if ~any(strcmp(type, ok))
                uialert(obj.Fig, sprintf(['%s cannot be reproduced by one dialog command (EEGLAB records ', ...
                    'marking and removal separately, or the step comes from the contract). Set its value in ', ...
                    'the settings column instead.'], type), 'NeuroQC');
                return;
            end
            try
                com = neuroqc.run.Native.capture(type);
                if isempty(com), return; end
                id = [slot.id '_native'];
                obj.Plan.Slots(k).alternatives = {struct('type', 'native', 'params', struct('command', com))};
                obj.Plan.Slots(k).id = id;
                obj.showPlan();
            catch ME
                uialert(obj.Fig, ME.message, 'NeuroQC');
            end
        end

        function applyNow(obj)
            k = obj.selected(); if isempty(k), return; end
            type = obj.Plan.Slots(k).alternatives{1}.type;
            try
                before = neuroqc.live.Session.fingerprint(neuroqc.live.Session.current());
                neuroqc.run.Native.applyNow(type);
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
            conds = {};
            for part = strsplit(strtrim(obj.CondField.Value), ';')
                p = strtrim(part{1}); if isempty(p), continue; end
                kv = strsplit(p, ':'); assert(numel(kv) == 2, 'NeuroQC:Contract', 'Conditions: name: ev1 ev2; name2: ev3');
                conds(end+1, :) = {strtrim(kv{1}), strsplit(strtrim(kv{2}))}; %#ok<AGROW>
            end
            comps = {};
            for part = strsplit(strtrim(obj.CompField.Value), ';')
                p = strtrim(part{1}); if isempty(p), continue; end
                tok = regexp(p, '^([^:]+):\s*([-\d\.eE]+)\s+([-\d\.eE]+)\s*@\s*([^#]+)(.*)$', 'tokens', 'once');
                assert(~isempty(tok), 'NeuroQC:Contract', 'Components: name: start end @ ch1 ch2 [# measure polarity]; ...');
                meas = strsplit(strtrim(strrep(tok{5}, '#', '')));
                meas = meas(~cellfun(@isempty, meas)); if isempty(meas), meas = {'mean'}; end
                comps(end+1, :) = {strtrim(tok{1}), [str2double(tok{2}) str2double(tok{3})], strsplit(strtrim(tok{4})), meas}; %#ok<AGROW>
            end
            c = neuroqc.eval.Contract('conditions', conds, 'components', comps, ...
                'epoch', str2num(obj.EpochField.Value), 'baseline', str2num(obj.BaseField.Value)); %#ok<ST2NM>
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
            neuroqc.NeuroQC.adopt(obj.Result, k);
        end

        function printScript(obj)
            k = obj.selectedResult(); if isempty(k), return; end
            neuroqc.utils.log('EEGLAB commands of candidate %d:', k);
            neuroqc.NeuroQC.script(obj.Result, k);
        end
    end
end

function t = orDash(t)
if isempty(t), t = '-'; end
end

function t = settingsText(slot)
parts = {};
for a = 1:numel(slot.alternatives)
    alt = slot.alternatives{a};
    if strcmp(alt.type, 'none'), parts{end+1} = 'none'; continue; end %#ok<AGROW>
    f = fieldnames(alt.params);
    kv = cellfun(@(n) sprintf('%s = %s', n, valText(alt.params.(n))), f, 'UniformOutput', false);
    if numel(slot.alternatives) > 1, parts{end+1} = sprintf('%s(%s)', alt.type, strjoin(kv, '; ')); %#ok<AGROW>
    else, parts{end+1} = strjoin(kv, '; '); end %#ok<AGROW>
end
t = strjoin(parts, ' | ');
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
