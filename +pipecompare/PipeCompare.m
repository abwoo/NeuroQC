classdef PipeCompare
    %PIPECOMPARE Optimization layer around EEGLAB.
    %
    %   pipecompare.PipeCompare.state()                 current EEGLAB dataset, parsed
    %                                           EEG.history and derived state
    %   r = pipecompare.PipeCompare.optimize(plan, contract, opts)
    %                                           run every legal pipeline of the
    %                                           plan from the current dataset
    %   pipecompare.PipeCompare.adopt(r)                store the recommended candidate
    %   pipecompare.PipeCompare.adopt(r, id)            (or candidate id) as a new
    %                                           EEGLAB dataset, full history
    %   pipecompare.PipeCompare.script(r, id)           EEGLAB commands of a candidate
    %   pipecompare.PipeCompare.writeScript(r, id, f)   ... as a function file that runs
    %                                           the same steps on any dataset
    %   EEG = pipecompare.PipeCompare.apply(EEG, steps, contract)
    %                                           run steps (rows of type, params) on
    %                                           a dataset (what that file calls)
    %   r = pipecompare.PipeCompare.resume(folder)      continue an interrupted search
    %                                           (opts.checkpoint = folder)
    %   pipecompare.PipeCompare.app()                   panel (also EEGLAB > Tools > PipeCompare)
    %
    %   See pipecompare.plan.Plan, pipecompare.eval.Contract, pipecompare.eval.Rank.

    properties (Constant)
        Version = '0.8.0'
    end

    methods (Static)
        function s = state()
            [EEG, live] = pipecompare.live.Session.current();
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset is loaded in EEGLAB.');
            s = pipecompare.live.DataState.fromEEG(EEG);
            pipecompare.utils.log('Current set: %s%s', mat2str(live.currentSet), ...
                pipecompare.utils.ternary(live.stored, '', ' (base EEG modified, not stored in ALLEEG)'));
            pipecompare.live.DataState.print(s);
            pipecompare.live.History.print(s.history);
            P = s.provenance;
            for k = 1:numel(P)
                fprintf('  [%s] %s %s\n', P(k).category, P(k).item, P(k).detail);
            end
        end

        function result = optimize(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            result = pipecompare.run.Executor.run(plan, contract, opts);
        end

        function result = resume(checkpointDir)
            result = pipecompare.run.Executor.resume(checkpointDir);
        end

        function adopt(result, idx, force)
            if nargin < 2, idx = []; end
            if nargin < 3, force = false; end
            pipecompare.run.Executor.adopt(result, idx, force);
        end

        function writeScript(result, idx, file)
            % Write a function file that runs candidate idx's steps on any
            % dataset: bad channels, components and rejected epochs are
            % decided from that dataset's own data, as in the search (on
            % the starting dataset it rebuilds the candidate). The exact
            % EEGLAB commands of the candidate follow as comments. idx = []
            % means the recommended candidate; with several strata (no
            % single recommendation) or none feasible it is an error and
            % no file is written.
            idx = pipecompare.run.Executor.pickCandidate(result, idx);
            [~, name] = fileparts(file);
            c = result.contract;
            L = {sprintf('function EEG = %s(EEG)', name), ...
                sprintf('%% PipeCompare %s, pipeline %d: %s', pipecompare.PipeCompare.Version, idx, result.labels{idx}), ...
                '% Runs these steps on any dataset with the same channels and event codes: bad channels,', ...
                '% ICLabel components and rejected epochs are decided from that dataset''s own data, as', ...
                '% PipeCompare did. Needs PipeCompare on the MATLAB path; every EEGLAB command goes to EEG.history.'};
            args = {};
            if strcmp(c.analysis, 'erp') && ~isempty(c.epoch)
                conds = [{c.conditions.name}' {c.conditions.events}'];
                args = {'conditions', conds, 'epoch', c.epoch, 'baseline', c.baseline};
                if ~strcmp(c.trials.mode, 'all'), args = [args {'trials', c.trials}]; end
                if strcmp(c.trials.mode, 'urevents')
                    L{end+1} = sprintf('%% The trial rule lists urevent ids of %s: change it for other recordings.', result.state.setname);
                end
            end
            L{end+1} = sprintf('contract = pipecompare.eval.Contract(%s);', strjoin(cellfun(@literal, args, 'UniformOutput', false), ', '));
            L{end+1} = 'steps = {';
            path = result.leaves(idx).path;
            for k = 1:numel(path)
                L{end+1} = sprintf('    %s, %s', literal(path{k}.type), literal(path{k}.params)); %#ok<AGROW>
            end
            L = [L {'    };', 'EEG = pipecompare.PipeCompare.apply(EEG, steps, contract);', 'end', '', ...
                sprintf('%% The EEGLAB commands this pipeline ran on %s:', result.state.setname)}, ...
                regexprep(scriptLines(result, idx), '(^|\n)', '$1% ')];
            fid = fopen(file, 'w'); assert(fid > 0, 'PipeCompare:Export', 'Cannot write %s', file);
            fprintf(fid, '%s\n', L{:}); fclose(fid);
            pipecompare.utils.log('Wrote %s', file);
        end

        function EEG = apply(EEG, steps, contract)
            if nargin < 3, contract = []; end
            EEG = pipecompare.run.Executor.apply(EEG, steps, contract);
        end

        function txt = script(result, idx)
            % The EEGLAB commands that rebuild candidate idx from the starting
            % dataset, PipeCompare's preparation lines (e.g. volts -> microvolts)
            % included: the same lines writeScript writes.
            if nargin < 2, idx = []; end
            idx = pipecompare.run.Executor.pickCandidate(result, idx);
            txt = strjoin(scriptLines(result, idx), newline);
            if nargout == 0, fprintf('%s\n', txt); end
        end

        function app = app()
            app = pipecompare.gui.Panel();
        end

        function v = version()
            v = pipecompare.PipeCompare.Version;
        end
    end
end

function L = scriptLines(result, idx)
% preparation of the starting copy, then the candidate's own commands
L = [result.rootComs(:)' result.cands(idx).coms(:)'];
end

function t = literal(v)
% MATLAB source that rebuilds v (char, numbers, logicals, cells, structs)
if isstring(v), v = char(v); end
if ischar(v)
    t = ['''' strrep(strrep(v, '''', ''''''), newline, ''' newline ''') ''''];
    if contains(v, newline), t = ['[' t ']']; end
elseif isnumeric(v) || islogical(v)
    t = mat2str(v);
elseif iscell(v)
    rows = arrayfun(@(r) strjoin(cellfun(@literal, v(r, :), 'UniformOutput', false), ', '), 1:size(v, 1), ...
        'UniformOutput', false);
    t = ['{' strjoin(rows, '; ') '}'];
elseif isstruct(v)
    f = fieldnames(v);
    parts = cell(1, numel(f));
    for k = 1:numel(f)
        vals = arrayfun(@(e) literal(e.(f{k})), v, 'UniformOutput', false);
        parts{k} = sprintf('''%s'', {%s}', f{k}, strjoin(vals, ', '));
    end
    t = ['struct(' strjoin(parts, ', ') ')'];
    if isempty(f), t = 'struct()'; end
else
    error('PipeCompare:Export', 'Cannot write a %s value into a script.', class(v));
end
end
