classdef CheckpointDialog
    % CheckpointDialog - Parse EEGLAB history into a completed-steps checklist
    % for NeuroQC handoff. Also provides single-shot "Capture last action".

    methods (Static)
        function cp = open(baseEEG)
            % Interactive dialog: reads EEG.history, allows paste/edit, returns
            % struct('steps', completedSteps, 'raw', rawHistory, 'timestamp', now).
            cp = neuroqc.gui.CheckpointDialog.emptyCheckpoint();
            if nargin < 1 || isempty(baseEEG)
                neuroqc.gui.CheckpointDialog.safeErrordlg('No EEG provided to CheckpointDialog');
                return;
            end
            history = '';
            if isfield(baseEEG, 'history') && ~isempty(baseEEG.history)
                history = char(baseEEG.history);
            end
            parsed = neuroqc.gui.CheckpointDialog.parseHistory(history);
            [steps, ok] = neuroqc.gui.CheckpointDialog.showChecklistDialog(history, parsed);
            if ~ok
                cp = neuroqc.gui.CheckpointDialog.emptyCheckpoint();
                cp.raw = history;
                cp.timestamp = datetime('now');
                return;
            end
            cp = struct('steps', {steps}, 'raw', history, 'timestamp', datetime('now'));
            cp.sourceHash = neuroqc.utils.hashEEG(baseEEG);
            assignin('base', 'neuroqc_checkpoint', cp);
            fprintf('Checkpoint recorded: %d steps\n', numel(steps));
        end

        function captured = captureLastAction(baseEEG)
            % Single-shot: read last line of EEG.history, classify.
            % Returns struct('type', 'completed'|'provenance'|'none', 'step', stepOrCom, 'raw', com).
            captured = struct('type', 'none', 'step', '', 'raw', '');
            if nargin < 1 || isempty(baseEEG)
                neuroqc.gui.CheckpointDialog.safeErrordlg('No EEG in workspace');
                return;
            end
            if ~isfield(baseEEG, 'history') || isempty(baseEEG.history)
                neuroqc.gui.CheckpointDialog.safeErrordlg('EEG.history is empty');
                return;
            end
            hist = char(baseEEG.history);
            lines = splitlines(string(hist));
            lines = lines(~cellfun(@isempty, strtrim(cellstr(lines))));
            if isempty(lines)
                neuroqc.gui.CheckpointDialog.safeErrordlg('EEG.history has no lines');
                return;
            end
            last = strtrim(char(lines{end}));
            mapped = neuroqc.gui.CheckpointDialog.classifyCom(last);
            if ~isempty(mapped)
                % Mappable to a canonical step: declare as completed
                cp = neuroqc.gui.CheckpointDialog.loadOrCreateCheckpoint(baseEEG);
                cp.steps = union(cp.steps, {mapped}, 'stable');
                assignin('base', 'neuroqc_checkpoint', cp);
                captured = struct('type', 'completed', 'step', mapped, 'raw', last);
                fprintf('Captured last action as completed: %s\n', mapped);
            else
                % Unmappable: record as provenance only (already in EEG)
                cp = neuroqc.gui.CheckpointDialog.loadOrCreateCheckpoint(baseEEG);
                if ~isfield(cp, 'preHandoffCommands'), cp.preHandoffCommands = {}; end
                cp.preHandoffCommands{end+1} = last;
                assignin('base', 'neuroqc_checkpoint', cp);
                captured = struct('type', 'provenance', 'step', '', 'raw', last);
                fprintf('Captured last action as provenance (unmappable): %s\n', last);
            end
        end

        function steps = parseHistory(hist)
            % Parse full EEG.history text into ordered step list.
            if iscell(hist) || isstring(hist), hist = char(join(string(hist(:)), newline)); end
            if isempty(strtrim(hist)), steps = {}; return; end
            lines = splitlines(string(hist));
            lines = lines(strlength(strtrim(lines))>0);
            steps = {};
            for k = 1:numel(lines)
                step = neuroqc.gui.CheckpointDialog.classifyCom(char(strtrim(lines(k))));
                if ~isempty(step) && ~ismember(step, steps)
                    steps{end+1} = step; %#ok<AGROW>
                end
            end
        end

        function step = classifyCom(com)
            % Classify a single com string to canonical step or ''.
            fn = neuroqc.gui.CheckpointDialog.extractPopFunction(com);
            if isempty(fn), step = ''; return; end
            popMap = neuroqc.gui.CheckpointDialog.popToStepMap();
            if isfield(popMap, fn)
                step = popMap.(fn);
                % Marking/classification alone does not complete removal.
                if ismember(fn, {'pop_eegthresh','pop_jointprob','pop_rejkurt'})
                    args = neuroqc.gui.CheckpointDialog.filtArgs(com, fn);
                    flag = 7; if strcmp(fn,'pop_eegthresh'), flag = 9; end
                    if numel(args)<flag || ~ismember(args{flag},{'1','true'})
                        step = ''; return;
                    end
                end
                if strcmp(fn, 'pop_eegfiltnew') && isempty(step)
                    % Disambiguate notch vs filter from arguments
                    step = neuroqc.gui.CheckpointDialog.disambiguateFilter(com);
                end
            else
                step = '';
            end
        end

        function step = disambiguateFilter(com)
            % 'filter' vs 'notch' from pop_eegfiltnew args (same parsing as
            % NeuroQCApp.parseComIntoSpace): positional (EEG, hp, lp, order, rev)
            % or named pairs ('locutoff', hp, 'hicutoff', lp, 'revfilt', true).
            if isstring(com), com = char(com); end
            args = neuroqc.gui.CheckpointDialog.filtArgs(com);
            if isempty(args), step = 'filter'; return; end
            hp = NaN; lp = NaN; rev = false;
            if numel(args) >= 2 && contains(args{2}, char(39))
                for k = 2:2:numel(args)
                    if k+1 > numel(args), break; end
                    key = strrep(args{k}, char(39), '');
                    switch key
                        case 'locutoff', hp = str2double(args{k+1});
                        case 'hicutoff', lp = str2double(args{k+1});
                        case 'revfilt',  rev = ismember(args{k+1}, {'1','true'});
                    end
                end
            else
                if numel(args) >= 2, hp = str2double(args{2}); end
                if numel(args) >= 3, lp = str2double(args{3}); end
                if numel(args) >= 5, rev = ismember(args{5}, {'1','true'}); end
            end
            if rev
                step = 'notch';          % reversed filter = stop band
            else
                step = 'filter';
            end
        end

        function args = filtArgs(com, fn)
            % Split pop_eegfiltnew(...) argument list without evaluating it.
            if nargin<2, fn='pop_eegfiltnew'; end
            args = {};
            tok = regexp(com, [fn '\s*\(([\s\S]*)\)\s*;?\s*$'], 'tokens', 'once');
            if isempty(tok), return; end
            raw = tok{1}; depth = 0; quoted = false; first = 1; k = 1;
            while k <= numel(raw)
                ch = raw(k);
                if ch == char(39)
                    if quoted && k < numel(raw) && raw(k+1) == char(39), k = k+2; continue; end
                    quoted = ~quoted;
                elseif ~quoted
                    if any(ch == '([{'), depth = depth + 1; end
                    if any(ch == ')]}'), depth = depth - 1; end
                    if ch == ',' && depth == 0
                        args{end+1} = strtrim(raw(first:k-1)); %#ok<AGROW>
                        first = k+1;
                    end
                end
                k = k+1;
            end
            args{end+1} = strtrim(raw(first:end));
        end

        function safeErrordlg(msg)
            % errordlg must never replace the real return contract (and must
            % not fail in -batch); log to console as a fallback.
            fprintf(2, 'NeuroQC: %s\n', msg);
            if usejava('desktop')
                try
                    errordlg(msg, 'NeuroQC');
                catch
                end
            end
        end

        function fn = extractPopFunction(com)
            % Extract pop_* function name from a command string.
            m = regexp(char(com), '^\s*(?:EEG\s*=\s*|\[[^\]]*\]\s*=\s*)?(pop_[a-zA-Z0-9_]+)\s*\(', 'tokens', 'once');
            if ~isempty(m), fn = m{1}; else, fn = ''; end
        end

        function m = popToStepMap()
            % EEGLAB pop_* function -> canonical step name.
            m = struct( ...
                'pop_chanedit', 'chanloc', ...
                'pop_select', 'select_data', ...
                'pop_selectevent', 'select_events', ...
                'pop_editeventvals', 'edit_events', ...
                'pop_resample', 'resample', ...
                'pop_eegfiltnew', '', ...  % notch/filter disambiguated below
                'pop_rejchan', 'badchannel', ...
                'pop_rejcont', 'reject_continuous', ...
                'pop_reref', 'reref', ...
                'pop_runica', 'run_ica', ...
                'pop_iclabel', '', ...
                'pop_subcomp', 'auto_ic_remove', ...
                'pop_interp', 'interpolate', ...
                'pop_epoch', 'epoch', ...
                'pop_rmbase', 'baseline', ...
                'pop_eegthresh', 'artifact_reject', ...
                'pop_autorej', 'auto_reject', ...
                'pop_jointprob', 'reject_jointprob', ...
                'pop_rejkurt', 'reject_kurtosis');
            % pop_eegfiltnew disambiguation handled in parseHistory via args
        end

        function [steps, ok] = showChecklistDialog(history, prechecked)
            % Figure with checklist + paste textarea. Returns cellstr steps.
            steps = {}; ok = false;
            f = figure('Name', 'NeuroQC Checkpoint', 'NumberTitle', 'off', ...
                'MenuBar', 'none', 'ToolBar', 'none', 'Position', [200 180 700 520]);
            g = uigridlayout(f, [5 1]);
            g.RowHeight = {40, '1x', 25, 80, 50};
            g.Padding = [10 10 10 10];

            % Info
            uilabel(g, 'Text', 'EEG.history → completed steps. Edit list, paste extra lines below, then Confirm.', ...
                'FontSize', 12, 'HorizontalAlignment', 'left');

            % Checklist
            known = neuroqc.pipeline.StageModel.canonicalOrder();
            chk = uilistbox(g, 'Items', known, ...
                'Multiselect', 'on', 'FontName', 'Courier');
            chk.Value = prechecked;
            chk.ValueChangedFcn = @(s,~) handleCheck(s);

            % Paste area
            uilabel(g, 'Text', 'Paste additional history lines (one per line) then Re-parse:', ...
                'FontSize', 11, 'HorizontalAlignment', 'left');
            ta = uitextarea(g, 'Value', '', ...
                'FontName', 'Courier', 'FontSize', 11, 'Editable', true);
            ta.Tooltip = 'Paste EEGLAB history lines; click Re-parse to update checklist';

            % Buttons
            btns = uigridlayout(g, [1 3]);
            btns.Layout.Row = 5;
            uibutton(btns, 'Text', 'Re-parse', 'ButtonPushedFcn', @(~,~) reparse());
            uibutton(btns, 'Text', 'Confirm', 'ButtonPushedFcn', @(~,~) confirm());
            uibutton(btns, 'Text', 'Cancel', 'ButtonPushedFcn', @(~,~) cancel());

            function handleCheck(src)
                prechecked = src.Value;
            end
            function reparse()
                txt = ta.Value;
                if isstring(txt), txt = char(txt); end
                parsed = neuroqc.gui.CheckpointDialog.parseHistory(txt);
                chk.Value = union(prechecked, parsed, 'stable');
                prechecked = chk.Value;
            end
            function confirm()
                steps = chk.Value;
                ok = true;
                close(f);
            end
            function cancel()
                steps = {}; ok = false;
                close(f);
            end
            uiwait(f);
        end

        function cp = loadOrCreateCheckpoint(baseEEG)
            % Never inherit another dataset's completed steps or provenance.
            cp = neuroqc.gui.CheckpointDialog.emptyCheckpoint();
            if evalin('base', 'exist(''neuroqc_checkpoint'',''var'')')
                previous = evalin('base', 'neuroqc_checkpoint');
                if neuroqc.gui.CheckpointDialog.matchesSource(previous,baseEEG)
                    cp = previous;
                end
            end
            cp.sourceHash = neuroqc.utils.hashEEG(baseEEG);
            if isfield(baseEEG,'history')
                cp.raw = baseEEG.history;
                cp.steps = union(cp.steps, neuroqc.gui.CheckpointDialog.parseHistory(cp.raw), 'stable');
            end
            cp.timestamp = datetime('now');
        end

        function matches = matchesSource(cp, EEG)
            matches = isstruct(cp) && isscalar(cp) && isfield(cp,'sourceHash') && ...
                ~isempty(cp.sourceHash) && ~isempty(EEG) && ...
                strcmp(cp.sourceHash, neuroqc.utils.hashEEG(EEG));
        end

        function cp = emptyCheckpoint()
            % Scalar struct with an empty steps cell (struct('steps',{}) would
            % build a 0x0 struct array, breaking later dot-assignment).
            cp = struct('steps', {{}}, 'raw', '', 'timestamp', datetime('now'));
        end
    end
end