classdef History
    %HISTORY Parse EEG.history into an ordered list of entries.
    %
    %   entries = pipecompare.live.History.parse(EEG.history)
    %
    %   Every statement is kept, in order, with its line number and raw
    %   text. Nothing is deduplicated: a second pop_reref or pop_runica is
    %   a second entry. Each entry is classified:
    %
    %     kind  'load' | 'process' | 'mark' | 'view' | 'save' | 'admin' |
    %           'comment' | 'unknown'
    %     step  canonical step name for 'process'/'mark' entries
    %           (e.g. 'highpass', 'reref', 'ica', 'icremove', 'epoch', ...)
    %     params struct of the arguments that could be read without
    %           evaluating anything (numbers stay numbers where possible)
    %
    %   The parser never evaluates history text.

    methods (Static)
        function entries = parse(history)
            entries = pipecompare.live.History.emptyEntries();
            lines = pipecompare.live.History.toLines(history);
            for li = 1:numel(lines)
                line = lines{li};
                if isempty(strtrim(line)), continue; end
                stmts = pipecompare.live.History.splitStatements(line);
                for si = 1:numel(stmts)
                    st = strtrim(stmts{si});
                    if isempty(st), continue; end
                    e = pipecompare.live.History.classify(st);
                    e.line = li;
                    e.raw = line;
                    entries(end+1) = e; %#ok<AGROW>
                end
            end
        end

        function lines = toLines(history)
            % EEG.history is a char row with char(10) separators in current
            % EEGLAB, a char matrix (one command per row) in old datasets,
            % and occasionally a cell/string array after user edits.
            if isempty(history), lines = {}; return; end
            if isstring(history), history = cellstr(history); end
            if iscell(history)
                parts = cellfun(@(x) char(x), history(:)', 'UniformOutput', false);
                history = strjoin(parts, newline);
            elseif ischar(history) && size(history, 1) > 1
                rows = cellstr(history); % strips trailing blanks per row
                history = strjoin(rows(:)', newline);
            end
            history = strrep(char(history), sprintf('\r\n'), newline);
            history = strrep(history, sprintf('\r'), newline);
            raw = strsplit(history, newline, 'CollapseDelimiters', false);
            % MATLAB line continuation: "..." outside strings and comments
            % joins a command with the next line (one entry, first line no.).
            lines = cell(size(raw)); k = 1;
            while k <= numel(raw)
                line = raw{k}; j = k;
                while j < numel(raw)
                    code = pipecompare.live.History.stripComment(line);
                    pos = pipecompare.live.History.continuationAt(code);
                    if pos == 0, break; end
                    line = [code(1:pos-1) ' ' strtrim(raw{j+1})];
                    j = j + 1;
                end
                lines{k} = line;
                for q = k+1:j, lines{q} = ''; end
                k = j + 1;
            end
        end

        function stmts = splitStatements(line)
            % Split one history line on top-level ';' and drop trailing
            % comments. Quotes and brackets are respected.
            stmts = {};
            [code, ~] = pipecompare.live.History.stripComment(line);
            if isempty(strtrim(code))
                if ~isempty(strtrim(line)), stmts = {strtrim(line)}; end % pure comment line
                return;
            end
            depth = 0; inQ = false; qc = ''; first = 1; k = 1; n = numel(code);
            while k <= n
                ch = code(k);
                if inQ
                    if ch == qc
                        if k < n && code(k+1) == qc, k = k + 2; continue; end
                        inQ = false;
                    end
                elseif pipecompare.live.History.opensString(code, k)
                    inQ = true; qc = ch;
                elseif any(ch == '([{')
                    depth = depth + 1;
                elseif any(ch == ')]}')
                    depth = max(depth - 1, 0);
                elseif ch == ';' && depth == 0
                    stmts{end+1} = code(first:k-1); %#ok<AGROW>
                    first = k + 1;
                end
                k = k + 1;
            end
            stmts{end+1} = code(first:end);
            stmts = stmts(~cellfun(@(s) isempty(strtrim(s)), stmts));
        end

        function pos = continuationAt(code)
            % Index of the first '...' outside quotes (0 = none). In MATLAB
            % everything after it on the line is ignored.
            pos = 0; inQ = false; qc = ''; k = 1; n = numel(code);
            while k <= n
                ch = code(k);
                if inQ
                    if ch == qc
                        if k < n && code(k+1) == qc, k = k + 2; continue; end
                        inQ = false;
                    end
                elseif pipecompare.live.History.opensString(code, k)
                    inQ = true; qc = ch;
                elseif k + 2 <= n && strcmp(code(k:k+2), '...')
                    pos = k; return;
                end
                k = k + 1;
            end
        end

        function [code, comment] = stripComment(line)
            inQ = false; qc = ''; k = 1; n = numel(line);
            code = line; comment = '';
            while k <= n
                ch = line(k);
                if inQ
                    if ch == qc
                        if k < n && line(k+1) == qc, k = k + 2; continue; end
                        inQ = false;
                    end
                elseif pipecompare.live.History.opensString(line, k)
                    inQ = true; qc = ch;
                elseif ch == '%'
                    code = line(1:k-1); comment = line(k:end); return;
                end
                k = k + 1;
            end
        end

        function tf = opensString(s, k)
            % A quote opens a string unless it is a transpose operator.
            ch = s(k);
            if ch == '"', tf = true; return; end
            if ch ~= '''', tf = false; return; end
            j = k - 1;
            while j >= 1 && s(j) == ' ', j = j - 1; end
            if j < 1, tf = true; return; end
            prev = s(j);
            tf = ~(isstrprop(prev, 'alphanum') || any(prev == ')]}._''') );
            if ~tf && j < k - 1, tf = true; end % "a 'x'" inside brackets: space before quote
        end

        function args = splitArgs(argText)
            % Split a call's argument text on top-level commas.
            args = {};
            if isempty(strtrim(argText)), return; end
            depth = 0; inQ = false; qc = ''; first = 1; k = 1; n = numel(argText);
            while k <= n
                ch = argText(k);
                if inQ
                    if ch == qc
                        if k < n && argText(k+1) == qc, k = k + 2; continue; end
                        inQ = false;
                    end
                elseif pipecompare.live.History.opensString(argText, k)
                    inQ = true; qc = ch;
                elseif any(ch == '([{')
                    depth = depth + 1;
                elseif any(ch == ')]}')
                    depth = depth - 1;
                elseif ch == ',' && depth == 0
                    args{end+1} = strtrim(argText(first:k-1)); %#ok<AGROW>
                    first = k + 1;
                end
                k = k + 1;
            end
            args{end+1} = strtrim(argText(first:end));
        end

        function [fn, args, lhs] = callParts(stmt)
            % 'EEG = pop_x(EEG, a, b)' -> fn 'pop_x', args {'EEG','a','b'}
            fn = ''; args = {}; lhs = '';
            withLhs = regexp(stmt, '^\s*(\[[^\]]*\]|[A-Za-z]\w*(?:\.\w+|\(\d+\))*)\s*=\s*([A-Za-z]\w*)\s*(\(.*)?$', 'tokens', 'once');
            if ~isempty(withLhs)
                lhs = strtrim(withLhs{1}); fn = withLhs{2}; rest = '';
                if numel(withLhs) >= 3, rest = strtrim(withLhs{3}); end
            else
                bare = regexp(stmt, '^\s*([A-Za-z]\w*)\s*(\(.*)?$', 'tokens', 'once');
                if isempty(bare), return; end
                fn = bare{1}; rest = '';
                if numel(bare) >= 2, rest = strtrim(bare{2}); end
            end
            if ~isempty(rest)
                % find the matching closing parenthesis of the call
                depth = 0; inQ = false; qc = ''; close = 0; k = 1;
                while k <= numel(rest)
                    ch = rest(k);
                    if inQ
                        if ch == qc
                            if k < numel(rest) && rest(k+1) == qc, k = k + 2; continue; end
                            inQ = false;
                        end
                    elseif pipecompare.live.History.opensString(rest, k)
                        inQ = true; qc = ch;
                    elseif ch == '(' || ch == '[' || ch == '{'
                        depth = depth + 1;
                    elseif ch == ')' || ch == ']' || ch == '}'
                        depth = depth - 1;
                        if depth == 0, close = k; break; end
                    end
                    k = k + 1;
                end
                if close > 0
                    args = pipecompare.live.History.splitArgs(rest(2:close-1));
                else
                    args = pipecompare.live.History.splitArgs(rest(2:end));
                end
            end
        end

        function e = classify(stmt)
            e = pipecompare.live.History.emptyEntries();
            e(1).statement = stmt;
            e.kind = 'unknown'; e.step = ''; e.fn = ''; e.params = struct(); e.note = '';
            if startsWith(strtrim(stmt), '%')
                e.kind = 'comment'; return;
            end
            [fn, args, lhs] = pipecompare.live.History.callParts(stmt);
            e.fn = fn; e.args = args;
            if isempty(fn)
                if ~isempty(regexp(stmt, '^\s*EEG\.[\w\.]+\s*=', 'once'))
                    e.kind = 'admin'; e.note = 'direct field assignment';
                end
                return;
            end
            if isempty(lhs) && ~isempty(regexp(stmt, '^\s*[A-Za-z]\w*(\.\w+)+\s*=', 'once'))
                e.kind = 'admin'; e.note = 'direct field assignment'; return;
            end
            nv = pipecompare.live.History.nameValues(args);
            switch fn
                case {'pop_loadset','pop_biosig','pop_fileio','pop_loadbv','pop_loadcnt', ...
                        'pop_loadeeg','pop_readegi','pop_mffimport','pop_importdata', ...
                        'pop_loadxdf','pop_importbids','pop_musemonitor','pop_readbdf','pop_loadedf'}
                    e.kind = 'load';
                case {'pop_saveset','pop_export','pop_writeeeg','pop_expica'}
                    e.kind = 'save';
                case {'eeg_checkset','eeg_store','pop_newset','eeglab','eegh','eeg_retrieve','pop_editset','pop_comments'}
                    e.kind = 'admin';
                case {'pop_eegplot','pop_spectopo','pop_topoplot','pop_plottopo','pop_erpimage', ...
                        'pop_timtopo','pop_prop','pop_prop_extended','pop_signalstat','pop_headplot', ...
                        'pop_viewprops','pop_envtopo','figure','pop_eventstat','pop_chanplot'}
                    e.kind = 'view';
                    if strcmp(fn, 'pop_eegplot') && numel(args) >= 4 && strcmp(args{4}, '1')
                        e.note = 'scroll window opened with reject enabled; a rejection, if any, appears as a separate eeg_eegrej entry';
                    end
                case 'pop_chanedit'
                    e.kind = 'process'; e.step = 'chanlocs';
                    if isfield(nv, 'lookup'), e.params.lookup = nv.lookup; end
                case 'pop_select'
                    e.kind = 'process';
                    keys = fieldnames(nv);
                    if any(ismember(keys, {'rmchannel','nochannel','channel'}))
                        e.step = 'channels';
                        for kk = intersect(keys, {'rmchannel','nochannel','channel'})'
                            e.params.(kk{1}) = nv.(kk{1});
                        end
                    else
                        e.step = 'select_data';
                        e.params = nv;
                    end
                case 'pop_selectevent'
                    e.kind = 'process'; e.step = 'select_events'; e.params = nv;
                case {'pop_editeventvals','pop_importevent','pop_adjustevents','pop_editeventfield'}
                    e.kind = 'process'; e.step = 'edit_events';
                case 'pop_resample'
                    e.kind = 'process'; e.step = 'resample';
                    if numel(args) >= 2, e.params.fs = str2double(args{2}); end
                case 'pop_eegfiltnew'
                    e.kind = 'process';
                    p = pipecompare.live.History.filterParams(args);
                    e.params = p;
                    if p.revfilt
                        e.step = 'linenoise';
                    elseif isfinite(p.locutoff) && p.locutoff > 0 && (~isfinite(p.hicutoff) || p.hicutoff <= 0)
                        e.step = 'highpass';
                    elseif isfinite(p.hicutoff) && p.hicutoff > 0 && (~isfinite(p.locutoff) || p.locutoff <= 0)
                        e.step = 'lowpass';
                    else
                        e.step = 'bandpass';
                    end
                case {'pop_eegfilt','pop_firws','pop_basicfilter','pop_iirfilt','pop_firpm','pop_firma'}
                    e.kind = 'process'; e.step = 'filter_other';
                    e.note = 'filter call not parsed for cutoffs; see raw text';
                case {'pop_cleanline','pop_zapline_plus','clean_zapline'}
                    e.kind = 'process'; e.step = 'linenoise';
                case {'pop_clean_rawdata','clean_artifacts','clean_rawdata'}
                    e.kind = 'process'; e.step = 'clean_rawdata'; e.params = nv;
                    e.note = 'may high-pass filter, remove channels and correct/remove bursts depending on options';
                case 'pop_rejchan'
                    e.kind = 'process'; e.step = 'badchannels'; e.params = nv;
                case {'pop_rejcont','eeg_eegrej','pop_rejectdata'}
                    e.kind = 'process'; e.step = 'reject_continuous';
                case 'pop_reref'
                    e.kind = 'process'; e.step = 'reref';
                    if numel(args) >= 2
                        e.params.ref = args{2};
                        if strcmp(regexprep(args{2}, '\s', ''), '[]'), e.params.mode = 'average';
                        else, e.params.mode = 'channels'; end
                    end
                case {'pop_runica','pop_runamica','runamica15','pop_runica_extended'}
                    e.kind = 'process'; e.step = 'ica'; e.params = nv;
                case 'pop_subcomp'
                    e.kind = 'process'; e.step = 'icremove';
                    if numel(args) >= 2
                        e.params.components = args{2};
                        if strcmp(regexprep(args{2}, '\s', ''), '[]')
                            e.note = 'components = [] removes the ICs flagged in EEG.reject.gcompreject; their indices are not in the history';
                        end
                    end
                case {'pop_iclabel','pop_icflag','pop_selectcomps'}
                    e.kind = 'mark'; e.step = 'ic_flags';
                    if strcmp(fn, 'pop_selectcomps')
                        e.note = 'interactive IC flagging; the selection is stored in EEG.reject.gcompreject, not in the history';
                    end
                case 'pop_interp'
                    e.kind = 'process'; e.step = 'interpolate';
                    if numel(args) >= 2, e.params.channels = args{2}; end
                    if numel(args) >= 3, e.params.method = strrep(args{3}, '''', ''); end
                    if numel(args) >= 2 && ~isempty(regexp(args{2}, '(ALLEEG|chanlocs)', 'once'))
                        e.note = 'restores a channel montage; target montage is taken from another dataset/structure';
                    end
                case 'pop_epoch'
                    e.kind = 'process'; e.step = 'epoch';
                    if numel(args) >= 3
                        e.params.types = args{2};
                        e.params.window = str2num(args{3}); %#ok<ST2NM> numeric literal only
                    end
                case 'pop_rmbase'
                    e.kind = 'process'; e.step = 'baseline';
                    if numel(args) >= 2, e.params.windowMs = str2num(args{2}); end %#ok<ST2NM>
                case {'pop_eegthresh','pop_jointprob','pop_rejkurt','pop_rejtrend','pop_rejspec'}
                    % Positional 'reject' flag: 9th argument for pop_eegthresh,
                    % 7th for pop_jointprob / pop_rejkurt.
                    flagPos = 7; if strcmp(fn, 'pop_eegthresh'), flagPos = 9; end
                    if numel(args) >= flagPos && any(strcmp(args{flagPos}, {'1','true'}))
                        e.kind = 'process'; e.step = 'reject_epochs';
                    else
                        e.kind = 'mark'; e.step = 'epoch_flags';
                        e.note = 'epochs marked only; removal happens in a later pop_rejepoch entry';
                    end
                    e.params.method = fn;
                case {'pop_rejepoch','pop_autorej'}
                    e.kind = 'process'; e.step = 'reject_epochs';
                    e.params.method = fn;
                otherwise
                    if startsWith(fn, 'pop_load') || startsWith(fn, 'pop_import')
                        e.kind = 'load';
                    end
            end
            if ~isempty(regexp(stmt, '\<ALLEEG\>|\<CURRENTSET\>|\<STUDY\>', 'once'))
                e.note = strtrim([e.note ' [refers to ALLEEG/CURRENTSET/STUDY: not reproducible from this dataset alone]']);
            end
        end

        function p = filterParams(args)
            % pop_eegfiltnew(EEG, locutoff, hicutoff, filtorder, revfilt, ...)
            % or pop_eegfiltnew(EEG, 'locutoff', x, 'hicutoff', y, 'revfilt', 1)
            p = struct('locutoff', NaN, 'hicutoff', NaN, 'revfilt', false);
            if numel(args) >= 2 && any(args{2}(1) == '''"')
                nv = pipecompare.live.History.nameValues(args);
                if isfield(nv, 'locutoff'), p.locutoff = toNum(nv.locutoff); end
                if isfield(nv, 'hicutoff'), p.hicutoff = toNum(nv.hicutoff); end
                if isfield(nv, 'revfilt'), p.revfilt = isTrue(nv.revfilt); end
            else
                if numel(args) >= 2, p.locutoff = toNum(args{2}); end
                if numel(args) >= 3, p.hicutoff = toNum(args{3}); end
                if numel(args) >= 5, p.revfilt = isTrue(args{5}); end
            end
        end

        function nv = nameValues(args)
            % Read 'name', value pairs that follow the first argument.
            nv = struct();
            k = 2;
            while k + 1 <= numel(args)
                key = args{k};
                if numel(key) >= 2 && any(key(1) == '''"') && key(end) == key(1)
                    name = key(2:end-1);
                    if isvarname(name)
                        nv.(name) = literal(args{k+1});
                    end
                    k = k + 2;
                else
                    k = k + 1;
                end
            end
        end

        function e = emptyEntries()
            e = struct('line', {}, 'raw', {}, 'statement', {}, 'fn', {}, 'args', {}, ...
                'kind', {}, 'step', {}, 'params', {}, 'note', {});
        end

        function print(entries)
            if isempty(entries)
                pipecompare.utils.log('EEG.history is empty.');
                return;
            end
            fprintf('  %-4s %-8s %-18s %s\n', 'line', 'kind', 'step', 'statement');
            for k = 1:numel(entries)
                e = entries(k);
                s = e.statement;
                if numel(s) > 110, s = [s(1:107) '...']; end
                fprintf('  %-4d %-8s %-18s %s\n', e.line, e.kind, e.step, s);
                if ~isempty(e.note), fprintf('  %-4s %-8s %-18s ^ %s\n', '', '', '', e.note); end
            end
        end
    end
end

function v = literal(txt)
% Numbers become numbers, quoted text becomes char; anything else stays text.
txt = strtrim(txt);
if numel(txt) >= 2 && any(txt(1) == '''"') && txt(end) == txt(1)
    v = strrep(txt(2:end-1), [txt(1) txt(1)], txt(1));
    return;
end
n = str2double(txt);
if ~isnan(n) || strcmpi(txt, 'nan'), v = n; return; end
if ~isempty(regexp(txt, '^\[[\d\s\.,:;eE+\-]*\]$', 'once'))
    n = str2num(txt); %#ok<ST2NM> numeric literal matched by the regexp above
    if ~isempty(n) || strcmp(regexprep(txt, '\s', ''), '[]'), v = n; return; end
end
v = txt;
end

function n = toNum(v)
if isnumeric(v), n = double(v); if isempty(n), n = NaN; end; return; end
n = str2double(v);
if isnan(n) && ~isempty(regexp(char(v), '^\[\s*\]$', 'once')), n = NaN; end
end

function tf = isTrue(v)
if isnumeric(v) || islogical(v), tf = ~isempty(v) && logical(v(1)); return; end
tf = any(strcmpi(strtrim(char(v)), {'1','true','on'}));
end
