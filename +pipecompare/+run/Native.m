classdef Native
    %NATIVE Open EEGLAB's own dialogs from PipeCompare.
    %
    %   pipecompare.run.Native.applyNow(type)
    %       Opens the EEGLAB dialog for this kind of step on the CURRENT
    %       dataset, exactly as the EEGLAB menu does (same try/catch
    %       strings, eegh, new dataset, redraw). The operation is recorded
    %       in EEG.history and ALLCOM by EEGLAB itself; PipeCompare's live view
    %       picks it up from the history.
    %
    %   com = pipecompare.run.Native.capture(type)
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
                case {'select_data','channels'}, call = '[EEG, LASTCOM] = pop_select(EEG);';
                case 'select_events', call = '[EEG, ~, LASTCOM] = pop_selectevent(EEG);';
                case 'chanlocs', call = '[EEG, ~, ~, LASTCOM] = pop_chanedit(EEG);';
                otherwise, error('PipeCompare:Native', 'No EEGLAB dialog for %s', type);
            end
        end

        function items = menuSteps()
            % The operations of EEGLAB's own menus (plugins included) that
            % take the dataset and return it, each with the call its menu
            % item makes: what "Add EEGLAB menu step..." offers. File, Plot
            % and Help items (import, save, figures) are not plan steps.
            items = struct('label', {}, 'call', {}, 'fn', {});
            f = findall(groot, 'Type', 'figure', 'Tag', 'EEGLAB');
            if isempty(f), return; end
            pat = '\[\s*EEG\>[^\]=]*\<LASTCOM\s*\]\s*=\s*(pop_\w+)\s*\(\s*EEG\s*[,)][^;]*;';
            for m = findall(f, 'Type', 'uimenu')'
                cb = m.MenuSelectedFcn;
                if ~ischar(cb), continue; end
                [call, tok] = regexp(cb, pat, 'match', 'tokens', 'once');
                if isempty(call) || ~isempty(regexp(call, '\<(ALLEEG|STUDY|CURRENTSET)\>', 'once')), continue; end
                p = m; lab = {strtrim(p.Text)};
                while isa(p.Parent, 'matlab.ui.container.Menu'), p = p.Parent; lab = [{strtrim(p.Text)} lab]; end %#ok<AGROW>
                if any(strcmp(lab{1}, {'File', 'Plot', 'Help', 'Datasets', 'Study'})) || strcmp(tok{1}, 'pop_saveset'), continue; end
                items(end+1) = struct('label', strjoin(lab, ' > '), 'call', call, 'fn', tok{1}); %#ok<AGROW>
            end
            [~, o] = unique({items.label}); items = items(o);
        end

        function applyNow(type)
            pipecompare.run.Native.applyCall(pipecompare.run.Native.menuCall(type), type);
        end

        function applyCommand(command)
            % Run a captured command (a fixed 'native' plan step) on the
            % current dataset, wrapped like an EEGLAB menu callback, so the
            % operation is stored and recorded in EEG.history.
            st = pipecompare.run.Native.statements(command);
            for k = 1:numel(st)
                assert(~isempty(regexp(st{k}, '^\s*\[?\s*EEG\>', 'once')), 'PipeCompare:Native', ...
                    'Only commands that return EEG can be applied: %s', st{k});
                if ~endsWith(st{k}, ';'), st{k} = [st{k} ';']; end
            end
            cmd = strjoin(st, ' ');   % a workflow is one EEGLAB operation (one new dataset)
            call = sprintf('%s LASTCOM = ''%s'';', cmd, strrep(cmd, '''', ''''''));
            pipecompare.run.Native.applyCall(call, 'native');
        end

        function alt = eeglabAlt(command)
            % A single EEGLAB call as a parameterised plan alternative:
            % 'EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30);'
            %   -> type 'eeglab', params.fn = 'pop_eegfiltnew', params.args
            %      = struct array (name, key, values); every argument is
            %      kept, each value list starts with the dialog's value.
            % Returns [] when the command is not one EEG = pop_x(EEG, ...)
            % call (e.g. a captured multi-step workflow).
            alt = [];
            st = pipecompare.run.Native.statements(command);
            if ~isscalar(st), return; end
            [fn, ~, lhs] = pipecompare.live.History.callParts(st{1});
            if isempty(fn) || ~startsWith(fn, 'pop_') || isempty(regexp(lhs, '^\[?\s*EEG\>', 'once')), return; end
            a = pipecompare.run.Native.argsOf(st{1}, fn);
            % trailing name-value pairs: char keys at every other position
            kv = numel(a) + 1;
            for i = numel(a)-1:-2:1
                if ischar(a{i}) && isrow(a{i}) && ~isempty(regexp(a{i}, '^[A-Za-z]\w*$', 'once')), kv = i; else, break; end
            end
            args = struct('name', {}, 'key', {}, 'values', {});
            for i = 1:kv-1
                args(end+1) = struct('name', sprintf('arg%d', i + 1), 'key', false, 'values', {a(i)}); %#ok<AGROW>
            end
            for i = kv:2:numel(a)
                args(end+1) = struct('name', a{i}, 'key', true, 'values', {a(i+1)}); %#ok<AGROW>
            end
            alt = struct('type', 'eeglab', 'params', struct('fn', fn, 'args', args));
        end

        function [alt, changed] = mergeEeglab(alt, other)
            % Add another configuration of the same EEGLAB call: each
            % argument whose value differs becomes searched over the
            % values seen. changed lists those arguments ({} if the other
            % configuration is a different call or layout).
            changed = {};
            if isempty(other) || ~strcmp(alt.params.fn, other.params.fn), return; end
            A = alt.params.args; B = other.params.args;
            if ~isequal({A.name}, {B.name}), return; end
            for i = 1:numel(A)
                v = B(i).values{1};
                if ~any(cellfun(@(x) isequal(x, v), A(i).values))
                    A(i).values{end+1} = v; changed{end+1} = A(i).name; %#ok<AGROW>
                end
            end
            alt.params.args = A;
        end

        function com = eeglabCommand(fn, args, values)
            % The EEGLAB command for one choice of argument values.
            parts = cell(1, numel(args));
            for i = 1:numel(args)
                v = valueCode(values{i});
                if args(i).key, parts{i} = sprintf('''%s'',%s', args(i).name, v); else, parts{i} = v; end
            end
            com = sprintf('EEG = %s(EEG);', fn);
            if ~isempty(parts), com = sprintf('EEG = %s(EEG, %s);', fn, strjoin(parts, ',')); end
        end

        function [vals, notes] = catalogValues(type, command, EEG)
            % The values of a catalog step's parameters set in its EEGLAB
            % dialog (command = what the dialog returned, EEG = the data
            % it ran on, to turn channel indices into labels). Settings of
            % the dialog that the catalog step cannot express are listed
            % in notes, never dropped silently: Configure in EEGLAB then offers
            % to keep the whole command instead.
            vals = struct(); notes = {};
            st = pipecompare.run.Native.statements(command);
            com = st{end};
            setter = struct('icremove', 'pop_icflag', 'reject_threshold', 'pop_eegthresh', ...
                'reject_jointprob', 'pop_jointprob', 'reject_kurtosis', 'pop_rejkurt');
            if isfield(setter, type)                % the statement that holds the settings
                k = find(contains(st, setter.(type)), 1);
                assert(~isempty(k), 'PipeCompare:Native', 'No %s in the dialog command.', setter.(type));
                com = st{k};
            end
            [fn] = pipecompare.live.History.callParts(com);
            a = pipecompare.run.Native.argsOf(com, fn);
            labs = {EEG.chanlocs.labels};
            [nv, pos] = nameValues(a);
            function chk(allowed)
                % options the step reproduces exactly; any other one is a note
                extra = setdiff(fieldnames(nv), allowed);
                if ~isempty(extra)
                    notes{end+1} = sprintf('%s option(s) %s are not part of the %s step', fn, strjoin(extra, ', '), type);
                end
            end
            function differs(name, stepValue, what)
                % a named option whose value differs from what the step uses
                if ~isfield(nv, name), return; end
                v = nv.(name);
                same = isequal(v, stepValue) || (ischar(v) && ischar(stepValue) && strcmpi(v, stepValue)) || ...
                    (isnumeric(v) && isnumeric(stepValue) && isequal(size(v), size(stepValue)) && all(abs(v(:) - stepValue(:)) < 1e-9));
                if ~same, notes{end+1} = sprintf('%s = %s (the %s step uses %s)', name, valueCode(v), type, what); end
            end
            switch type
                case {'highpass','lowpass','linenoise'}
                    assert(strcmp(fn, 'pop_eegfiltnew'), 'PipeCompare:Native', 'Expected pop_eegfiltnew, got %s', fn);
                    lo = pipecompare.utils.fieldOr(nv, 'locutoff', []); hi = pipecompare.utils.fieldOr(nv, 'hicutoff', []); rev = pipecompare.utils.fieldOr(nv, 'revfilt', 0);
                    switch type
                        case 'highpass'
                            assert(~isempty(lo) && lo > 0 && ~rev, 'PipeCompare:Native', 'The dialog did not set a high-pass edge (lower edge).');
                            vals.cutoff = lo;
                            if ~isempty(hi) && hi > 0, notes{end+1} = sprintf('the low-pass edge %g Hz is not part of the highpass step', hi); end
                        case 'lowpass'
                            assert(~isempty(hi) && hi > 0 && ~rev, 'PipeCompare:Native', 'The dialog did not set a low-pass edge (higher edge).');
                            vals.cutoff = hi;
                            if ~isempty(lo) && lo > 0, notes{end+1} = sprintf('the high-pass edge %g Hz is not part of the lowpass step', lo); end
                        case 'linenoise'
                            assert(~isempty(lo) && ~isempty(hi) && rev, 'PipeCompare:Native', 'Set a notch: both edges and "notch filter the data instead of pass band".');
                            vals.freq = (lo + hi) / 2; vals.halfwidth = (hi - lo) / 2;
                    end
                    chk({'locutoff','hicutoff','revfilt','plotfreqz'});
                case 'resample'
                    vals.fs = pos{1};
                    if numel(pos) > 1 && ~all(cellfun(@isempty, pos(2:end)))
                        notes{end+1} = 'the anti-aliasing filter settings of pop_resample are not part of the resample step (it uses the defaults)';
                    end
                    chk({});
                case 'asr'
                    vals.cutoff = pipecompare.utils.fieldOr(nv, 'BurstCriterion', 20);
                    off = {'FlatlineCriterion','ChannelCriterion','LineNoiseCriterion','Highpass','WindowCriterion'};
                    on = off(cellfun(@(f) isfield(nv, f) && ~(ischar(nv.(f)) && strcmpi(nv.(f), 'off')), off));
                    if ~isempty(on), notes{end+1} = sprintf('the asr step only corrects bursts; %s not used', strjoin(on, ', ')); end
                    differs('BurstRejection', 'off', '''off'' (repair, not removal)');
                    differs('Distance', 'Euclidian', 'Euclidian');
                    differs('BurstCriterionRefMaxBadChns', 0.075, '0.075');
                    differs('BurstCriterionRefTolerances', [-inf 5.5], '[-Inf 5.5]');
                    chk([off {'BurstCriterion','BurstRejection','Distance','MaxMem','availableRAM_GB', ...
                        'BurstCriterionRefMaxBadChns','BurstCriterionRefTolerances','WindowCriterionTolerances', ...
                        'ChannelCriterionMaxBadTime','NoLocsChannelCriterion','NoLocsChannelCriterionExcluded', 'fusechanrej'}]);
                case 'badchannels'
                    vals.measure = pipecompare.utils.fieldOr(nv, 'measure', 'kurt'); vals.threshold = pipecompare.utils.fieldOr(nv, 'threshold', 5);
                    elec = pipecompare.utils.fieldOr(nv, 'elec', 1:numel(labs));
                    if numel(elec) < numel(labs), vals.exclude = labs(setdiff(1:numel(labs), elec)); end
                    if numel(vals.threshold) > 1, notes{end+1} = 'only the upper threshold is used'; vals.threshold = max(vals.threshold); end
                    differs('norm', 'on', '''on'' (z-scored measure)');
                    if strcmp(vals.measure, 'spec'), differs('freqrange', [1 min(50, EEG.srate / 2 - 1)], sprintf('[1 %g] Hz', min(50, EEG.srate / 2 - 1)));
                    elseif isfield(nv, 'freqrange'), notes{end+1} = 'freqrange only applies to the spec measure'; end
                    chk({'elec','threshold','norm','measure','freqrange'});
                case 'reref'
                    ref = pos{1};
                    if isempty(ref), vals.mode = 'average'; else, vals.mode = 'channels'; vals.channels = asLabels(ref, labs); end
                    if isfield(nv, 'exclude'), vals.exclude = asLabels(nv.exclude, labs); end
                    chk({'exclude'});
                case 'channels'
                    if isfield(nv, 'rmchannel'), vals.labels = asLabels(nv.rmchannel, labs);
                    elseif isfield(nv, 'nochannel'), vals.labels = asLabels(nv.nochannel, labs);
                    elseif isfield(nv, 'channel'), vals.labels = setdiff(labs, asLabels(nv.channel, labs), 'stable');
                    else, error('PipeCompare:Native', 'The dialog selected no channels to remove.');
                    end
                    vals.action = 'remove';
                    chk({'rmchannel','nochannel','channel'});
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    if ~isequal(pos{1}, 1)
                        notes{end+1} = 'the dialog tests ICA components, the step tests the channel data';
                    end
                    elec = pos{2};
                    if numel(elec) < numel(labs), vals.exclude = labs(setdiff(1:numel(labs), elec)); end
                    if strcmp(type, 'reject_threshold')
                        lo = pos{3}; hi = pos{4};
                        assert(isscalar(lo) && isscalar(hi), 'PipeCompare:Native', 'Per-channel limits: keep the whole EEGLAB command to use them.');
                        vals.uv = hi;
                        if lo ~= -hi, notes{end+1} = sprintf('asymmetric limits [%g %g]: the step uses +/-%g', lo, hi, hi); end
                        if numel(pos) >= 6 && EEG.trials > 1 && (abs(pos{5} - EEG.xmin) > 1 / EEG.srate || abs(pos{6} - EEG.xmax) > 1 / EEG.srate)
                            notes{end+1} = sprintf('time range [%g %g] s: the step tests the whole epoch [%g %g] s', pos{5}, pos{6}, EEG.xmin, EEG.xmax);
                        end
                    else
                        vals.sd = pos{3};
                        if numel(pos) >= 4 && ~isequal(pos{4}, pos{3})
                            notes{end+1} = sprintf('global limit %g differs from the local %g: the step uses %g for both', pos{4}, pos{3}, pos{3});
                        end
                    end
                case 'ica'
                    vals.extended = pipecompare.utils.fieldOr(nv, 'extended', 1);
                    differs('icatype', 'runica', 'runica');
                    differs('rndreset', 'no', '''no'' (reproducible)');
                    if isfield(nv, 'pca') && ~isempty(nv.pca), notes{end+1} = sprintf('pca = %s: the ica step does not reduce the dimension (EEGLAB limits it to the data rank)', valueCode(nv.pca)); end
                    if isfield(nv, 'chanind') && ~isempty(nv.chanind) && numel(nv.chanind) < numel(labs)
                        notes{end+1} = sprintf('ICA on %d of %d channels: the ica step uses all channels', numel(nv.chanind), numel(labs));
                    end
                    chk({'icatype','extended','interrupt','rndreset','chanind','pca'});
                case 'icremove'
                    T = pos{1};
                    cats = {'Brain','Muscle','Eye','Heart','Line Noise','Channel Noise','Other'};
                    rows = find(all(isfinite(T), 2))';
                    assert(~isempty(rows), 'PipeCompare:Native', 'No ICLabel class was flagged.');
                    assert(~ismember(1, rows), 'PipeCompare:Native', 'Flagging Brain components is not an artifact-removal step.');
                    vals.classes = cats(rows);
                    th = T(rows, 1);
                    vals.threshold = min(th);
                    if any(th ~= th(1)) || any(T(rows, 2) ~= 1)
                        notes{end+1} = 'different thresholds per class (or an upper limit < 1): the step uses one threshold';
                    end
                otherwise
                    error('PipeCompare:Native', 'No EEGLAB dialog values for %s.', type);
            end
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
            if nargin < 2, EEG = pipecompare.live.Session.current(); end
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset is loaded in EEGLAB.');
            com = '';
            switch type
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    assert(EEG.trials > 1, 'PipeCompare:Native', 'Epoch rejection needs epoched (preview) data.');
                    field = struct('reject_threshold', 'rejthresh', 'reject_jointprob', 'rejjp', 'reject_kurtosis', 'rejkurt');
                    c1 = pipecompare.run.Native.captureCall(EEG, pipecompare.run.Native.menuCall(type));
                    if isempty(c1), return; end
                    c1 = strtrim(regexprep(c1, '^\s*\w+\s*=\s*pop_eegthresh\([^;]*\);\s*(?=EEG\s*=)', ''));  % 'Indexes = ...' prefix, if any
                    e = pipecompare.live.History.classify(c1);
                    com = c1;
                    if ~strcmp(e.step, 'reject_epochs')            % marked only: remove the marked epochs
                        com = sprintf('%s\nEEG = pop_rejepoch(EEG, EEG.reject.%s, 0);', c1, field.(type));
                    end
                case 'icremove'
                    assert(~isempty(EEG.icaweights), 'PipeCompare:Native', ['The dataset has no ICA decomposition, so the ', ...
                        'ICLabel dialogs cannot run. For ICA inside the plan use the icremove step and its settings.']);
                    [c1, E1] = pipecompare.run.Native.captureCall(EEG, '[EEG, LASTCOM] = pop_iclabel(EEG);');
                    if isempty(c1), return; end
                    c2 = pipecompare.run.Native.captureCall(E1, '[EEG, LASTCOM] = pop_icflag(EEG);');
                    if isempty(c2), return; end
                    com = sprintf('%s\n%s\nEEG = pop_subcomp(EEG, [], 0);', c1, c2);
                otherwise
                    error('PipeCompare:Native', 'No EEGLAB workflow for %s', type);
            end
            pipecompare.utils.log('Captured workflow:\n%s', com);
        end

        function type = typeOfCommand(command)
            % The dialog(s) that produce a captured command ('' if none).
            st = pipecompare.run.Native.statements(command);
            e = pipecompare.live.History.classify(st{1});
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
            [tryStr, catchStr] = pipecompare.run.Native.eeglabStrings(type);
            pipecompare.utils.log('EEGLAB on the current dataset: %s', call);
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
                pipecompare.utils.log(['EEGLAB did not add "%s" to EEG.history (it repeats the previous ', ...
                    'session command); PipeCompare added it.'], com);
            end
        end

        function com = capture(type, EEG)
            % Run the dialog on a copy and return the command it produced.
            if nargin < 2, EEG = pipecompare.live.Session.current(); end
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset is loaded in EEGLAB.');
            slow = {'resample','highpass','lowpass','linenoise','filter','asr','badchannels','ica'};
            if any(strcmp(type, slow))
                if EEG.trials == 1
                    EEG = pipecompare.utils.selectPoints(EEG, 'time', [0 min(30, (EEG.pnts - 1) / EEG.srate)]);
                else
                    EEG = pop_select(EEG, 'trial', 1:min(20, EEG.trials));
                end
                pipecompare.utils.log('Dialog runs on a shortened copy (only its parameters are kept).');
            end
            com = pipecompare.run.Native.captureCall(EEG, pipecompare.run.Native.menuCall(type));
            if isempty(com) && strcmp(type, 'badchannels')
                % EEGLAB's pop_rejchan returns no command when it flags no
                % channel, so its settings cannot be told from a cancel
                pipecompare.utils.log(['pop_rejchan returned no command: either the dialog was cancelled or it flagged ', ...
                    'no channel on this copy (EEGLAB then returns nothing). Set measure/threshold in the settings ', ...
                    'column, or retry on data with a bad channel.']);
            end
        end

        function [com, EEGout] = captureCall(EEG, call)
            % Run an EEGLAB call on a copy; return the command it produced
            % (and the processed copy, which the caller may inspect).
            [LASTCOM, EEGout] = runCall(EEG, call);
            com = strtrim(char(LASTCOM));
            if isempty(com)
                pipecompare.utils.log('Dialog cancelled; nothing captured.');
            else
                pipecompare.utils.log('Captured: %s', com);
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
            assert(~isempty(tok), 'PipeCompare:Native', 'Not a %s(EEG, ...) command: %s', fn, cmd);
            if strcmp(tok{2}, ')'), args = {}; return; end
            body = regexprep(cmd, pat, 'NQC_ARGS__ = argList(');
            args = evalArgs(body);
        end

        function [tryStr, catchStr] = eeglabStrings(type)
            % The exact strings EEGLAB passed to plugins at startup, when
            % available; otherwise the same behaviour spelled out.
            s = getappdata(0, 'pipecompare_eeglab_strings');
            store = any(strcmp(type, {'ica','iclabel','icflag','reject_jointprob','reject_kurtosis'}));
            if ~isempty(s)
                tryStr = s.try_strings.check_data;
                if store, catchStr = s.catch_strings.store_and_hist; else, catchStr = s.catch_strings.new_and_hist; end
            else
                tryStr = 'try, ';
                catchStr = ' catch, eeglab_error; LASTCOM = ''''; end; eeglab_new;';
                if ~exist('eeglab_new', 'file')   % EEGLAB before 2023.0: its own strings, spelled out
                    catchStr = ' catch, eeglab_error; LASTCOM = ''''; end; EEG = eegh(LASTCOM, EEG); if ~isempty(LASTCOM) && ~isempty(EEG), ';
                    if store
                        catchStr = [catchStr '[ALLEEG, EEG] = eeg_store(ALLEEG, EEG, CURRENTSET); ', ...
                            'eegh(''[ALLEEG EEG] = eeg_store(ALLEEG, EEG, CURRENTSET);''); end; eeglab(''redraw'');'];
                    else
                        catchStr = [catchStr '[ALLEEG, EEG, CURRENTSET, LASTCOM] = pop_newset(ALLEEG, EEG, CURRENTSET, ''study'', ~isempty(STUDY)+0); ', ...
                            'eegh(LASTCOM); end; eeglab(''redraw'');'];
                    end
                end
            end
        end
    end
end

function [LASTCOM, EEG] = runCall(EEG, call)
LASTCOM = '';
eval(call);
end

function [nv, pos] = nameValues(a)
% split evaluated arguments into leading positional ones and trailing
% name-value pairs
kv = numel(a) + 1;
for i = numel(a)-1:-2:1
    if ischar(a{i}) && isrow(a{i}) && ~isempty(regexp(a{i}, '^[A-Za-z]\w*$', 'once')), kv = i; else, break; end
end
pos = a(1:kv-1); nv = struct();
for i = kv:2:numel(a), nv.(a{i}) = a{i+1}; end
end

function L = asLabels(x, labs)
if isnumeric(x), L = labs(x); else, L = cellstr(x); end
L = L(:)';
end

function t = valueCode(v)
% MATLAB code for a value, at full precision.
if ischar(v)
    t = ['''' strrep(v, '''', '''''') ''''];
elseif isstring(v) && isscalar(v)
    t = valueCode(char(v));
elseif islogical(v) || isnumeric(v)
    if isempty(v), t = '[]';
    else
        % the shortest text that gives back exactly the same value
        for prec = 4:17
            t = mat2str(double(v), prec);
            if isequal(eval(t), double(v)), break; end
        end
        if islogical(v), t = mat2str(v); end
    end
elseif iscell(v)
    inner = cellfun(@valueCode, v, 'UniformOutput', false);
    t = ['{' strjoin(inner, ',') '}'];
    if ~isrow(v) && ~isempty(v), t = ['{' strjoin(inner, ';') '}']; end
else
    error('PipeCompare:Native', 'Cannot write a %s argument back into an EEGLAB command.', class(v));
end
end

function NQC_ARGS__ = evalArgs(NQC_BODY__)
NQC_ARGS__ = {};
eval(NQC_BODY__);
end

function c = argList(varargin)
c = varargin;
end
