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
            call = neuroqc.run.Native.menuCall(type);
            [tryStr, catchStr] = neuroqc.run.Native.eeglabStrings(type);
            neuroqc.utils.log('Opening the EEGLAB dialog on the current dataset: %s', call);
            evalin('base', [tryStr call catchStr]);
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
            call = neuroqc.run.Native.menuCall(type);
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
