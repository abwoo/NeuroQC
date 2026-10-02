classdef PreprocessingMVP
    % PreprocessingMVP - Legacy name for the generate-only recommend path.
    % NeuroQC never executes EEG processing; EEGLAB does. See advice.RecommendPath.

    methods (Static)
        function out = run(source, contract, space, opts)
            if nargin < 4, opts = struct(); end
            if ~isfield(opts, 'completedStages'), opts.completedStages = {}; end
            if ~isfield(opts, 'orderMode'), opts.orderMode = 'set'; end
            % trialSelection is never defaulted: 'all' is only legal when the
            % user has already confirmed the data is formally screened.
            out = neuroqc.advice.RecommendPath.run(source, contract, space, opts);
        end
    end
end
