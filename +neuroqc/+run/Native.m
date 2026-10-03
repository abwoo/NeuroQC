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
            cmd = strtrim(char(command));
            assert(~isempty(regexp(cmd, '^\s*\[?\s*EEG\>', 'once')), 'NeuroQC:Native', ...
                'Only a command that returns EEG can be applied: %s', cmd);
            if ~endsWith(cmd, ';'), cmd = [cmd ';']; end
            call = sprintf('%s LASTCOM = ''%s'';', cmd, strrep(cmd, '''', ''''''));
            neuroqc.run.Native.applyCall(call, 'native');
        end

        function type = typeOfCommand(command)
            % The dialog that produces a captured command ('' if none).
            e = neuroqc.live.History.classify(command);
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

        function com = captureCall(EEG, call)
            % Run an EEGLAB call on a copy; return only the command it produced.
            LASTCOM = runCall(EEG, call);
            com = strtrim(char(LASTCOM));
            if isempty(com)
                neuroqc.utils.log('Dialog cancelled; nothing captured.');
            else
                neuroqc.utils.log('Captured: %s', com);
            end
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

function LASTCOM = runCall(EEG, call) %#ok<INUSL>
LASTCOM = '';
eval(call);
end
