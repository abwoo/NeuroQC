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
    %   pipecompare.PipeCompare.writeScript(r, id, f)   ... as a runnable function file
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
            % Write a runnable EEGLAB function that reproduces candidate idx
            % from the starting dataset (PipeCompare preparation lines included).
            % idx = [] means the recommended candidate; with several strata
            % (no single recommendation) or none feasible it is an error and
            % no file is written.
            idx = pipecompare.run.Executor.pickCandidate(result, idx);
            [~, name] = fileparts(file);
            L = [{sprintf('function EEG = %s(EEG)', name), ...
                sprintf('%% PipeCompare %s candidate %d: %s', pipecompare.PipeCompare.Version, idx, result.labels{idx})}, ...
                scriptLines(result, idx), {'end'}];
            fid = fopen(file, 'w'); assert(fid > 0, 'PipeCompare:Export', 'Cannot write %s', file);
            fprintf(fid, '%s\n', L{:}); fclose(fid);
            pipecompare.utils.log('Wrote %s', file);
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
