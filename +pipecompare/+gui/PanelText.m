classdef PanelText
    %PANELTEXT The panel's contract text fields: parsing what is typed (or
    %   filled from EEGLAB's dialogs) and writing it back, plus the small
    %   number formats of the result table. No UI here; tested directly
    %   (test_panel_text).

    methods (Static)
        function tok = tokens(s)
            % whitespace-separated items; "quoted" items may contain spaces
            tok = regexp(strtrim(char(s)), '"[^"]*"|\S+', 'match');
            tok = regexprep(tok, '^"(.*)"$', '$1');
        end

        function t = quoteItem(x)
            x = char(x);
            if any(isspace(x)) || isempty(x), t = ['"' x '"']; else, t = x; end
        end

        function conds = parseConditions(txt)
            % 'target: 11 21; standard: 31' -> {'target', {'11','21'}; 'standard', {'31'}}
            conds = cell(0, 2);
            for part = strsplit(strtrim(char(txt)), ';')
                p = strtrim(part{1}); if isempty(p), continue; end
                k = strfind(p, ':');
                assert(~isempty(k), 'PipeCompare:Contract', 'Conditions: name: ev1 ev2; name2: ev3');
                ev = pipecompare.gui.PanelText.tokens(p(k(1)+1:end));
                assert(~isempty(ev), 'PipeCompare:Contract', 'Condition %s has no event code.', strtrim(p(1:k(1)-1)));
                conds(end+1, :) = {strtrim(p(1:k(1)-1)), ev}; %#ok<AGROW>
            end
        end

        function t = conditionsText(conds)
            parts = cell(1, size(conds, 1));
            for k = 1:size(conds, 1)
                parts{k} = sprintf('%s: %s', conds{k, 1}, strjoin(cellfun(@pipecompare.gui.PanelText.quoteItem, conds{k, 2}, 'UniformOutput', false), ' '));
            end
            t = strjoin(parts, '; ');
        end

        function comps = parseComponents(txt)
            % 'P3: 0.3 0.6 @ Pz CPz # peakLatency negative' -> rows {name, win, roi, measure, contra}
            % '... # contra PO8 PO7': contralateral minus ipsilateral, for
            % each condition (in their order) the electrode contralateral to it
            comps = cell(0, 5);
            for part = strsplit(strtrim(char(txt)), ';')
                p = strtrim(part{1}); if isempty(p), continue; end
                tok = regexp(p, '^([^:]+):\s*([-\d\.eE]+)\s+([-\d\.eE]+)\s*@\s*([^#]+)(.*)$', 'tokens', 'once');
                assert(~isempty(tok), 'PipeCompare:Contract', 'Components: name: start end @ ch1 ch2 [# measure polarity] [contra ch ch]; ...');
                rest = strtrim(strrep(tok{5}, '#', '')); contra = {};
                [a, b] = regexpi(rest, '(^|\s)contra(\s|$)', 'start', 'end', 'once');
                if ~isempty(a)
                    contra = pipecompare.gui.PanelText.tokens(rest(b+1:end)); rest = rest(1:a-1);
                    assert(~isempty(contra), 'PipeCompare:Contract', 'Component %s: after contra, the electrode contralateral to each condition.', strtrim(tok{1}));
                end
                meas = strsplit(strtrim(rest));
                meas = meas(~cellfun(@isempty, meas)); if isempty(meas), meas = {'mean'}; end
                comps(end+1, :) = {strtrim(tok{1}), [str2double(tok{2}) str2double(tok{3})], pipecompare.gui.PanelText.tokens(tok{4}), meas, contra}; %#ok<AGROW>
            end
        end

        function t = componentsText(comps)
            parts = cell(1, size(comps, 1));
            q = @(c) strjoin(cellfun(@pipecompare.gui.PanelText.quoteItem, cellstr(c), 'UniformOutput', false), ' ');
            for k = 1:size(comps, 1)
                m = cellstr(comps{k, 4});
                tail = '';
                if ~(isscalar(m) && strcmp(m{1}, 'mean')) && ~(numel(m) == 2 && strcmp(m{1}, 'mean'))
                    tail = strjoin(m, ' ');
                end
                if size(comps, 2) >= 5 && ~isempty(comps{k, 5}), tail = strtrim([tail ' contra ' q(comps{k, 5})]); end
                if ~isempty(tail), tail = [' # ' tail]; end
                parts{k} = sprintf('%s: %g %g @ %s%s', comps{k, 1}, comps{k, 2}, q(comps{k, 3}), tail);
            end
            t = strjoin(parts, '; ');
        end

        function bands = parseBands(txt)
            % 'alpha: 8 13 @ O1 Oz O2; theta: 4 8 @ Fz' -> rows {name, [low high] Hz, roi}
            bands = cell(0, 3);
            for part = strsplit(strtrim(char(txt)), ';')
                p = strtrim(part{1}); if isempty(p), continue; end
                tok = regexp(p, '^([^:]+):\s*([-\d\.eE]+)\s+([-\d\.eE]+)\s*@\s*(.+)$', 'tokens', 'once');
                assert(~isempty(tok), 'PipeCompare:Contract', 'Bands: name: low high @ ch1 ch2; ... (Hz)');
                bands(end+1, :) = {strtrim(tok{1}), [str2double(tok{2}) str2double(tok{3})], pipecompare.gui.PanelText.tokens(tok{4})}; %#ok<AGROW>
            end
        end

        function t = bandsText(bands)
            parts = cell(1, size(bands, 1));
            for k = 1:size(bands, 1)
                parts{k} = sprintf('%s: %g %g @ %s', bands{k, 1}, bands{k, 2}, ...
                    strjoin(cellfun(@pipecompare.gui.PanelText.quoteItem, cellstr(bands{k, 3}), 'UniformOutput', false), ' '));
            end
            t = strjoin(parts, '; ');
        end

        function t = trialText(r)
            switch r.mode
                case 'all', t = 'all trials';
                case 'marker_ranges', t = sprintf('between markers %s and %s', char(string(r.startCode)), char(string(r.endCode)));
                case 'time_ranges'
                    t = sprintf('time ranges %s s', mat2str(r.ranges));
                    if isfield(r, 'source'), t = [t ' (' r.source ')']; end
                case 'urevents'
                    t = sprintf('%d selected events', numel(r.ids));
                    if isfield(r, 'source'), t = [t ' (' r.source ')']; end
                otherwise, t = r.mode;
            end
        end

        function t = num(v, f)
            if isfinite(v), t = sprintf(f, v); else, t = '-'; end
        end

        function t = pctText(v)
            if isfinite(v), t = sprintf('%.1f%%', 100 * v); else, t = '-'; end
        end

        function t = orDash(t)
            if isempty(t), t = '-'; end
        end
    end
end
