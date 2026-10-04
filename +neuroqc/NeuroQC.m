classdef NeuroQC
    %NEUROQC Optimization layer around EEGLAB.
    %
    %   neuroqc.NeuroQC.state()                 current EEGLAB dataset, parsed
    %                                           EEG.history and derived state
    %   r = neuroqc.NeuroQC.optimize(plan, contract, opts)
    %                                           run every legal pipeline of the
    %                                           plan from the current dataset
    %   neuroqc.NeuroQC.adopt(r)                store the recommended candidate
    %   neuroqc.NeuroQC.adopt(r, id)            (or candidate id) as a new
    %                                           EEGLAB dataset, full history
    %   neuroqc.NeuroQC.script(r, id)           EEGLAB commands of a candidate
    %   neuroqc.NeuroQC.writeScript(r, id, f)   ... as a runnable function file
    %   r = neuroqc.NeuroQC.resume(folder)      continue an interrupted search
    %                                           (opts.checkpoint = folder)
    %   neuroqc.NeuroQC.app()                   panel (also EEGLAB > Tools > NeuroQC)
    %
    %   See neuroqc.plan.Plan, neuroqc.eval.Contract, neuroqc.eval.Rank.

    properties (Constant)
        Version = '0.7.0'
    end

    methods (Static)
        function s = state()
            [EEG, live] = neuroqc.live.Session.current();
            assert(~isempty(EEG), 'NeuroQC:NoDataset', 'No dataset is loaded in EEGLAB.');
            s = neuroqc.live.DataState.fromEEG(EEG);
            neuroqc.utils.log('Current set: %s%s', mat2str(live.currentSet), ...
                neuroqc.utils.ternary(live.stored, '', ' (base EEG modified, not stored in ALLEEG)'));
            neuroqc.live.DataState.print(s);
            neuroqc.live.History.print(s.history);
            P = s.provenance;
            for k = 1:numel(P)
                fprintf('  [%s] %s %s\n', P(k).category, P(k).item, P(k).detail);
            end
        end

        function result = optimize(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            result = neuroqc.run.Executor.run(plan, contract, opts);
        end

        function result = resume(checkpointDir)
            result = neuroqc.run.Executor.resume(checkpointDir);
        end

        function adopt(result, idx, force)
            if nargin < 2, idx = []; end
            if nargin < 3, force = false; end
            neuroqc.run.Executor.adopt(result, idx, force);
        end

        function writeScript(result, idx, file)
            % Write a runnable EEGLAB function that reproduces candidate idx
            % from the starting dataset (NeuroQC preparation lines included).
            % idx = [] means the recommended candidate; with several strata
            % (no single recommendation) or none feasible it is an error and
            % no file is written.
            idx = neuroqc.run.Executor.pickCandidate(result, idx);
            [~, name] = fileparts(file);
            L = [{sprintf('function EEG = %s(EEG)', name), ...
                sprintf('%% NeuroQC %s candidate %d: %s', neuroqc.NeuroQC.Version, idx, result.labels{idx})}, ...
                scriptLines(result, idx), {'end'}];
            fid = fopen(file, 'w'); assert(fid > 0, 'NeuroQC:Export', 'Cannot write %s', file);
            fprintf(fid, '%s\n', L{:}); fclose(fid);
            neuroqc.utils.log('Wrote %s', file);
        end

        function txt = script(result, idx)
            % The EEGLAB commands that rebuild candidate idx from the starting
            % dataset, NeuroQC's preparation lines (e.g. volts -> microvolts)
            % included: the same lines writeScript writes.
            if nargin < 2, idx = []; end
            idx = neuroqc.run.Executor.pickCandidate(result, idx);
            txt = strjoin(scriptLines(result, idx), newline);
            if nargout == 0, fprintf('%s\n', txt); end
        end

        function app = app()
            app = neuroqc.gui.Panel();
        end

        function v = version()
            v = neuroqc.NeuroQC.Version;
        end
    end
end

function L = scriptLines(result, idx)
% preparation of the starting copy, then the candidate's own commands
L = [result.rootComs(:)' result.cands(idx).coms(:)'];
end
