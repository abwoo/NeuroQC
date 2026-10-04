classdef PanelValues
    %PANELVALUES Step values in the panel: one value = fixed, several =
    %   searched. Reading what is typed in Edit values..., merging values
    %   from EEGLAB's dialogs into a step, and the text the plan table
    %   shows. No UI here; tested directly (test_panel_text).

    methods (Static)
        function t = settingsText(slot, ctxt)
            % every parameter as it will run: given, default search or default
            if nargin < 2, ctxt = struct('epoch', '', 'baseline', ''); end
            parts = {};
            for a = 1:numel(slot.alternatives)
                alt = slot.alternatives{a};
                if strcmp(alt.type, 'none'), parts{end+1} = 'none (skip)'; continue; end %#ok<AGROW>
                if strcmp(alt.type, 'native')
                    parts{end+1} = ['EEGLAB: ' strjoin(pipecompare.run.Native.statements(alt.params.command), ' / ')]; %#ok<AGROW>
                    continue;
                end
                if strcmp(alt.type, 'eeglab')
                    A = alt.params.args;
                    kv = arrayfun(@(x) sprintf('%s = %s', x.name, pipecompare.gui.PanelValues.valuesText(x.values)), A, 'UniformOutput', false);
                    nComb = prod(cellfun(@numel, {A.values}));
                    tail = ''; if nComb > 1, tail = sprintf('  [%d combinations]', nComb); end
                    parts{end+1} = sprintf('EEGLAB %s: %s%s', alt.params.fn, strjoin(kv, '; '), tail); %#ok<AGROW>
                    continue;
                end
                d = pipecompare.plan.Catalog.get(alt.type);
                kv = {};
                for q = d.params
                    if isfield(alt.params, q.name), kv{end+1} = sprintf('%s = %s', q.name, pipecompare.gui.PanelValues.valText(alt.params.(q.name))); %#ok<AGROW>
                    elseif ~isempty(q.suggest), kv{end+1} = sprintf('%s = %s (default search)', q.name, pipecompare.gui.PanelValues.valText(q.suggest)); %#ok<AGROW>
                    else, kv{end+1} = sprintf('%s = %s (default)', q.name, pipecompare.gui.PanelValues.valText(q.default)); end %#ok<AGROW>
                end
                if strcmp(alt.type, 'epoch')
                    if isempty(strtrim(ctxt.epoch)), kv{end+1} = 'window: not set yet (required, analysis contract)'; %#ok<AGROW>
                    else, kv{end+1} = sprintf('window [%s] s, condition events (from the analysis contract)', ctxt.epoch); end %#ok<AGROW>
                end
                if strcmp(alt.type, 'baseline')
                    if isempty(strtrim(ctxt.baseline)), kv{end+1} = 'pre-stimulus [epoch start 0] s (default; from the analysis contract)'; %#ok<AGROW>
                    else, kv{end+1} = sprintf('[%s] s (from the analysis contract)', ctxt.baseline); end %#ok<AGROW>
                end
                if strcmp(alt.type, 'restore'), kv{end+1} = 'starting montage + channels removed before PipeCompare'; end %#ok<AGROW>
                if numel(slot.alternatives) > 1, parts{end+1} = sprintf('%s(%s)', alt.type, strjoin(kv, '; ')); %#ok<AGROW>
                else, parts{end+1} = strjoin(kv, '; '); end %#ok<AGROW>
            end
            t = strjoin(parts, ' | ');
        end

        function alt = addValues(alt, vals)
            % Values from an EEGLAB dialog join a catalog step: a value that differs
            % from those already set becomes a searched candidate.
            d = pipecompare.plan.Catalog.get(alt.type);
            for f = fieldnames(vals)'
                name = f{1}; v = vals.(name);
                listValued = iscell(d.params(strcmp({d.params.name}, name)).default);
                if ~isfield(alt.params, name), alt.params.(name) = v; continue; end
                L = pipecompare.gui.PanelValues.asList(alt.params.(name), listValued);
                if ~any(cellfun(@(x) isequal(x, v), L)), L{end+1} = v; end %#ok<AGROW>
                alt.params.(name) = pipecompare.gui.PanelValues.fromList(L, listValued);
            end
        end

        function L = asList(v, listValued)
            % a parameter's values as a list (one entry per value)
            if listValued
                if iscell(v) && ~isempty(v) && all(cellfun(@iscell, v)), L = v; else, L = {v}; end
            elseif iscell(v), L = v;
            else, L = {v};
            end
        end

        function v = fromList(L, listValued)
            if isscalar(L), v = L{1}; else, v = L; end
            if listValued && isscalar(L) && ~iscell(v), v = {v}; end
        end

        function alt = setParam(alt, name, values)
            % values: cell, one entry per value; {} = back to the default
            if strcmp(alt.type, 'eeglab')
                i = find(strcmp({alt.params.args.name}, name), 1);
                assert(~isempty(i), 'PipeCompare:Plan', '%s has no argument %s.', alt.params.fn, name);
                assert(~isempty(values), 'PipeCompare:Plan', 'An EEGLAB argument needs a value.');
                alt.params.args(i).values = values(:)';
                return;
            end
            d = pipecompare.plan.Catalog.get(alt.type);
            q = d.params(strcmp({d.params.name}, name));
            assert(~isempty(q), 'PipeCompare:Plan', 'Step %s has no parameter %s.', alt.type, name);
            if isempty(values)
                if isfield(alt.params, name), alt.params = rmfield(alt.params, name); end
            else
                alt.params.(name) = pipecompare.gui.PanelValues.fromList(values(:)', iscell(q.default));
            end
        end

        function rows = paramRows(alt)
            % {name, values text, default text, kind} for the values dialog
            rows = cell(0, 4);
            if strcmp(alt.type, 'eeglab')
                for a = alt.params.args
                    rows(end+1, :) = {a.name, pipecompare.gui.PanelValues.valuesEditText(a.values), '', pipecompare.gui.PanelValues.kindOf(a.values{1})}; %#ok<AGROW>
                end
                return;
            end
            if strcmp(alt.type, 'native'), return; end
            d = pipecompare.plan.Catalog.get(alt.type);
            for q = d.params
                cur = '';
                if isfield(alt.params, q.name), cur = pipecompare.gui.PanelValues.valuesEditText(pipecompare.gui.PanelValues.asList(alt.params.(q.name), iscell(q.default))); end
                if ~isempty(q.suggest), def = ['search ' pipecompare.gui.PanelValues.valuesEditText(q.suggest)]; else, def = pipecompare.gui.PanelValues.valuesEditText({q.default}); end
                if isempty(strtrim(def)), def = 'none'; end
                k = pipecompare.gui.PanelValues.kindOf(q.default); if iscell(q.default), k = 'labels'; end
                rows(end+1, :) = {q.name, cur, def, k}; %#ok<AGROW>
            end
        end

        function k = kindOf(v)
            if iscellstr(v) || (iscell(v) && isempty(v)), k = 'labels';
            elseif ischar(v), k = 'text';
            elseif isnumeric(v) || islogical(v), k = 'number';
            else, k = 'other';
            end
        end

        function t = valuesEditText(L)
            % values as editable text: entries separated by " | "
            parts = cell(1, numel(L));
            for i = 1:numel(L)
                v = L{i};
                if iscellstr(v) || (iscell(v) && isempty(v)), parts{i} = strjoin(cellfun(@pipecompare.gui.PanelText.quoteItem, v, 'UniformOutput', false), ' ');
                elseif ischar(v), parts{i} = v;
                elseif isnumeric(v) && isscalar(v), parts{i} = num2str(v, 15);
                elseif isnumeric(v), parts{i} = mat2str(v);
                else, parts{i} = pipecompare.gui.PanelValues.codeOf(v);
                end
            end
            t = strjoin(parts, ' | ');
        end

        function vals = parseValues(txt, kind)
            % "a | b | c" -> {a, b, c}; numbers stay numbers, channel lists become
            % label lists; nothing is evaluated as MATLAB code.
            txt = strtrim(char(txt));
            if isempty(txt), vals = {}; return; end
            parts = strtrim(regexp(txt, '\s*\|\s*', 'split'));
            parts = parts(~cellfun(@isempty, parts));
            vals = cell(1, numel(parts));
            for i = 1:numel(parts)
                p = parts{i};
                switch kind
                    case 'labels'
                        vals{i} = pipecompare.gui.PanelText.tokens(p);
                    case 'number'
                        assert(~isempty(regexp(p, '^[\s\d\.eE+\-:\[\];,]+$', 'once')), 'PipeCompare:Plan', 'Not a number: %s', p);
                        vals{i} = str2num(p); %#ok<ST2NM> digits, signs and brackets only
                        assert(~isempty(vals{i}), 'PipeCompare:Plan', 'Not a number: %s', p);
                    case 'other'
                        error('PipeCompare:Plan', 'This argument (%s) is set in its EEGLAB dialog (Configure in EEGLAB...).', p);
                    otherwise
                        vals{i} = regexprep(p, '^[''"](.*)[''"]$', '$1');
                end
            end
        end

        function t = valuesText(vals)
            % one value as code; several as {v1 | v2 | ...} (the searched list)
            c = cellfun(@pipecompare.gui.PanelValues.codeOf, vals, 'UniformOutput', false);
            if isscalar(c), t = c{1}; else, t = ['{' strjoin(c, ' | ') '}']; end
        end

        function t = codeOf(v)
            alt = pipecompare.run.Native.eeglabCommand('f', struct('name', 'x', 'key', false, 'values', {{v}}), {v});
            t = regexprep(alt, '^EEG = f\(EEG, (.*)\);$', '$1');
        end

        function t = valText(v)
            if ischar(v) || isstring(v), t = ['''' char(v) ''''];
            elseif isnumeric(v) || islogical(v), t = mat2str(v);
            elseif iscell(v), t = ['{' strjoin(cellfun(@pipecompare.gui.PanelValues.valText, v, 'UniformOutput', false), ', ') '}'];
            else, t = class(v);
            end
        end
    end
end
