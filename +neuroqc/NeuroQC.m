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
                ternary(live.stored, '', ' (base EEG modified, not stored in ALLEEG)'));
            neuroqc.live.DataState.print(s);
            neuroqc.live.History.print(s.history);
        end

        function result = optimize(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            result = neuroqc.run.Executor.run(plan, contract, opts);
        end

        function adopt(result, idx)
            if nargin < 2, idx = []; end
            neuroqc.run.Executor.adopt(result, idx);
        end

        function txt = script(result, idx)
            if nargin < 2 || isempty(idx), idx = result.ranking.recommended; end
            txt = strjoin(result.cands(idx).coms, newline);
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

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
