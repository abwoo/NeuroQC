function v = eeglabVersionSafe()
%eeglabVersionSafe Return EEGLAB version string or 'not_found'
    v = 'not_found';
    try
        if exist('eeglab', 'file')
            if evalin('base', 'exist(''EEG'',''var'')')
                % no-op
            end
            v = 'present';
            % Try common version variables
            try
                pv = which('eeglab');
                txt = fileread(pv);
                tok = regexp(txt, 'eeglabver\s*=\s*''([^'']+)''', 'tokens', 'once');
                if ~isempty(tok)
                    v = tok{1};
                end
            catch
            end
        end
    catch
    end
end