classdef ResumeOptimizer
    % ResumeOptimizer - Recommend remaining discrete recipes from a declared
    % EEGLAB handoff. Does NOT execute EEG processing (advice path only).
    % Declare completedStages (steps you already did in EEGLAB); NeuroQC
    % collapses those dimensions and recommends only remaining combinations.
    % Pure algorithm + discrete combinatorics — no AI/LLM.

    methods (Static)
        function out = run(source, contract, space, opts)
            required = {'outputDir'};
            for k = 1:numel(required)
                assert(isfield(opts, required{k}), ...
                    'NeuroQC:Config', 'Missing option %s', required{k});
            end
            opts=neuroqc.pipeline.StageModel.resolveScope(opts);
            out = neuroqc.advice.RecommendPath.run(source, contract, space, opts);
        end
    end
end
