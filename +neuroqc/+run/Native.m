classdef Native
    %NATIVE Open EEGLAB's own dialogs from NeuroQC.
    %
    %   neuroqc.run.Native.applyNow(type)
    %       Opens the EEGLAB dialog for this kind of step on the CURRENT
    %       dataset, exactly as the EEGLAB menu does (same try/catch
    %       strings, eegh, new dataset, redraw). The operation is recorded
    %       in EEG.history and ALLCOM by EEGLAB itself; NeuroQC's live view
    %       picks it up from the history.
    %
    %   com = neuroqc.run.Native.capture(type)
    %       Opens the same dialog on a temporary copy (shortened for slow
    %       functions) and returns the EEGLAB command it produced, without
    %       touching the dataset. The command becomes a fixed 'native' step
    %       of the plan and is replayed verbatim on every candidate.

    methods (Static)
        function call = menuCall(type)
            % The call EEGLAB's own menu callback makes for this step.
            switch type
                case 'resample', call = '[EEG, LASTCOM] = pop_resample(EEG);';
                case {'highpass','lowpass','linenoise','filter'}, call = '[EEG, LASTCOM] = pop_eegfiltnew(EEG);';
                case 'asr', call = '[EEG, LASTCOM] = pop_clean_rawdata(EEG);';
                case 'badchannels', call = '[EEG, ~, ~, LASTCOM] = pop_rejchan(EEG);';
                case {'restore','interpolate'}, call = '[EEG, LASTCOM] = pop_interp(EEG);';
                case 'reref', call = '[EEG, LASTCOM] = pop_reref(EEG);';
                case 'ica', call = '[EEG, LASTCOM] = pop_runica(EEG);';
                case 'iclabel', call = '[EEG, LASTCOM] = pop_iclabel(EEG);';
                case 'icflag', call = '[EEG, LASTCOM] = pop_icflag(EEG);';
                case 'icremove', call = '[EEG, LASTCOM] = pop_subcomp(EEG);';
                case 'epoch', call = '[EEG, ~, LASTCOM] = pop_epoch(EEG);';
                case 'baseline', call = '[EEG, LASTCOM] = pop_rmbase(EEG);';
                case 'reject_threshold', call = '[EEG, ~, LASTCOM] = pop_eegthresh(EEG, 1);';
                case 'reject_jointprob', call = '[EEG, ~, ~, ~, LASTCOM] = pop_jointprob(EEG, 1);';
                case 'reject_kurtosis', call = '[EEG, ~, ~, ~, LASTCOM] = pop_rejkurt(EEG, 1);';
                case 'select_data', call = '[EEG, LASTCOM] = pop_select(EEG);';
                case 'select_events', call = '[EEG, ~, LASTCOM] = pop_selectevent(EEG);';
                case 'chanlocs', call = '[EEG, ~, ~, LASTCOM] = pop_chanedit(EEG);';
                otherwise, error('NeuroQC:Native', 'No EEGLAB dialog for %s', type);
            end
        end

        function applyNow(type)
            neuroqc.run.Native.applyCall(neuroqc.run.Native.menuCall(type), type);
        end

        function applyCommand(command)
            % Run a captured command (a fixed 'native' plan step) on the
            % current dataset, wrapped like an EEGLAB menu callback, so the
            % operation is stored and recorded in EEG.history.
            st = neuroqc.run.Native.statements(command);
            for k = 1:numel(st)
                assert(~isempty(regexp(st{k}, '^\s*\[?\s*EEG\>', 'once')), 'NeuroQC:Native', ...
                    'Only commands that return EEG can be applied: %s', st{k});
                if ~endsWith(st{k}, ';'), st{k} = [st{k} ';']; end
            end
            cmd = strjoin(st, ' ');   % a workflow is one EEGLAB operation (one new dataset)
            call = sprintf('%s LASTCOM = ''%s'';', cmd, strrep(cmd, '''', ''''''));
            neuroqc.run.Native.applyCall(call, 'native');
        end

        function s = statements(command)
            % The EEGLAB statements of a native step, one per line (a
            % captured workflow such as mark -> reject has several).
            s = strtrim(splitlines(char(command)))';
            s = s(~cellfun(@isempty, s));
        end

        function com = captureWorkflow(type, EEG)
            % A multi-step EEGLAB operation configured in its own dialogs
            % on a copy, returned as one native step (one statement per
            % line, each recorded in EEG.history when it runs):
            %   reject_threshold / reject_jointprob / reject_kurtosis
            %       the marking dialog, then pop_rejepoch of the marked
            %       epochs (every setting of the dialog is kept, e.g.
            %       asymmetric limits, channels, time range)
            %   icremove
            %       pop_iclabel, pop_icflag (classes and thresholds), then
            %       pop_subcomp of the flagged components
            if nargin < 2, EEG = neuroqc.live.Session.current(); end
            assert(~isempty(EEG), 'NeuroQC:NoDataset', 'No dataset is loaded in EEGLAB.');
            com = '';
            switch type
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    assert(EEG.trials > 1, 'NeuroQC:Native', 'Epoch rejection needs epoched (preview) data.');
                    field = struct('reject_threshold', 'rejthresh', 'reject_jointprob', 'rejjp', 'reject_kurtosis', 'rejkurt');
                    c1 = neuroqc.run.Native.captureCall(EEG, neuroqc.run.Native.menuCall(type));
                    if isempty(c1), return; end
                    c1 = strtrim(regexprep(c1, '^\s*\w+\s*=\s*pop_eegthresh\([^;]*\);\s*(?=EEG\s*=)', ''));  % 'Indexes = ...' prefix, if any
                    e = neuroqc.live.History.classify(c1);
                    com = c1;
                    if ~strcmp(e.step, 'reject_epochs')            % marked only: remove the marked epochs
                        com = sprintf('%s\nEEG = pop_rejepoch(EEG, EEG.reject.%s, 0);', c1, field.(type));
                    end
                case 'icremove'
                    assert(~isempty(EEG.icaweights), 'NeuroQC:Native', ['The dataset has no ICA decomposition, so the ', ...
                        'ICLabel dialogs cannot run. For ICA inside the plan use the icremove step and its settings.']);
                    [c1, E1] = neuroqc.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_iclabel(EEG);');
                    if isempty(c1), return; end
                    c2 = neuroqc.run.Native.captureCall(E1, '[EEG, LASTCOM] = pop_icflag(EEG);');
                    if isempty(c2), return; end
                    com = sprintf('%s\n%s\nEEG = pop_subcomp(EEG, [], 0);', c1, c2);
                otherwise
                    error('NeuroQC:Native', 'No EEGLAB workflow for %s', type);
            end
            neuroqc.utils.log('Captured workflow:\n%s', com);
        end

        function type = typeOfCommand(command)
            % The dialog(s) that produce a captured command ('' if none).
            st = neuroqc.run.Native.statements(command);
            e = neuroqc.live.History.classify(st{1});
            wf = {'pop_eegthresh','reject_threshold'; 'pop_jointprob','reject_jointprob'; ...
                'pop_rejkurt','reject_kurtosis'; 'pop_iclabel','icremove'};
            k = find(strcmp(wf(:, 1), e.fn), 1);
            if ~isempty(k), type = wf{k, 2}; return; end
            map = {'pop_resample','resample'; 'pop_eegfiltnew','filter'; 'pop_clean_rawdata','asr'; ...
                'pop_rejchan','badchannels'; 'pop_interp','restore'; 'pop_reref','reref'; 'pop_runica','ica'};
            k = find(strcmp(map(:, 1), e.fn), 1);
            type = ''; if ~isempty(k), type = map{k, 2}; end
        end

        function applyCall(call, type)
            % Evaluate an EEGLAB call on the current dataset in the base
            % workspace, wrapped exactly like an EEGLAB menu callback.
            [tryStr, catchStr] = neuroqc.run.Native.eeglabStrings(type);
            neuroqc.utils.log('EEGLAB on the current dataset: %s', call);
            evalin('base', 'NQC_COM__ = '''';');
            evalin('base', [tryStr call ' NQC_COM__ = LASTCOM;' catchStr]);
            com = strtrim(char(evalin('base', 'NQC_COM__')));
            evalin('base', 'clear NQC_COM__');
            if isempty(com), return; end
            % EEGLAB's eegh skips a command identical to the previous session
            % command (ALLCOM{1}), and then it is missing from EEG.history
            % as well. The dataset history must list every operation.
            EEG = evalin('base', 'EEG');
            h = strtrim(char(EEG.history)); if size(h, 1) > 1, h = strtrim(h(end, :)); end
            if ~endsWith(h, com)
                EEG = eeg_hist(EEG, com);
                assignin('base', 'NQC_EEG__', EEG);
                evalin('base', ['EEG = NQC_EEG__; clear NQC_EEG__; ' ...
                    '[ALLEEG, EEG, CURRENTSET] = eeg_store(ALLEEG, EEG, CURRENTSET);']);
                neuroqc.utils.log(['EEGLAB did not add "%s" to EEG.history (it repeats the previous ', ...
                    'session command); NeuroQC added it.'], com);
            end
        end

        function com = capture(type, EEG)
            % Run the dialog on a copy and return the command it produced.
            if nargin < 2, EEG = neuroqc.live.Session.current(); end
            assert(~isempty(EEG), 'NeuroQC:NoDataset', 'No dataset is loaded in EEGLAB.');
            slow = {'resample','highpass','lowpass','linenoise','filter','asr','badchannels','ica'};
            if any(strcmp(type, slow))
                if EEG.trials == 1
                    EEG = pop_select(EEG, 'time', [0 min(30, (EEG.pnts - 1) / EEG.srate)]);
                else
                    EEG = pop_select(EEG, 'trial', 1:min(20, EEG.trials));
                end
                neuroqc.utils.log('Dialog runs on a shortened copy (only its parameters are kept).');
            end
            com = neuroqc.run.Native.captureCall(EEG, neuroqc.run.Native.menuCall(type));
        end

        function [com, EEGout] = captureCall(EEG, call)
            % Run an EEGLAB call on a copy; return the command it produced
            % (and the processed copy, which the caller may inspect).
            [LASTCOM, EEGout] = runCall(EEG, call);
            com = strtrim(char(LASTCOM));
            if isempty(com)
                neuroqc.utils.log('Dialog cancelled; nothing captured.');
            else
                neuroqc.utils.log('Captured: %s', com);
            end
        end

        function args = argsOf(command, fn)
            % The arguments after EEG of one EEGLAB call, evaluated:
            % 'EEG = pop_rmbase( EEG, [-200 0] ,[]);' -> {[-200 0], []}.
            % The command is one the user produced in an EEGLAB dialog of
            % their own session.
            cmd = strtrim(char(command));
            pat = ['^\s*(\[[^\]]*\]|\w+)\s*=\s*' fn '\s*\(\s*EEG\s*(,|\))'];
            tok = regexp(cmd, pat, 'tokens', 'once');
            assert(~isempty(tok), 'NeuroQC:Native', 'Not a %s(EEG, ...) command: %s', fn, cmd);
            if strcmp(tok{2}, ')'), args = {}; return; end
            body = regexprep(cmd, pat, 'NQC_ARGS__ = argList(');
            args = evalArgs(body);
        end

        function [tryStr, catchStr] = eeglabStrings(type)
            % The exact strings EEGLAB passed to plugins at startup, when
            % available; otherwise the same behaviour spelled out.
            s = getappdata(0, 'neuroqc_eeglab_strings');
            store = any(strcmp(type, {'ica','iclabel','icflag','reject_jointprob','reject_kurtosis'}));
            if ~isempty(s)
                tryStr = s.try_strings.check_data;
                if store, catchStr = s.catch_strings.store_and_hist; else, catchStr = s.catch_strings.new_and_hist; end
            else
                tryStr = 'try, ';
                catchStr = ' catch, eeglab_error; LASTCOM = ''''; end; eeglab_new;';
            end
        end
    end
end

function [LASTCOM, EEG] = runCall(EEG, call)
LASTCOM = '';
eval(call);
end

function NQC_ARGS__ = evalArgs(NQC_BODY__)
NQC_ARGS__ = {};
eval(NQC_BODY__);
end

function c = argList(varargin)
c = varargin;
end
