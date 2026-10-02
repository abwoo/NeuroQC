classdef WorkflowSpec
    % Explicit workflow: off / fixed / search. Unlisted modes mean off.
    methods (Static)
        function [space,opts]=compile(space,opts)
            if ~isfield(opts,'stepModes') || isempty(opts.stepModes), return; end
            assert(isstruct(opts.stepModes) && isscalar(opts.stepModes),'NeuroQC:Workflow','stepModes must be a scalar struct');
            known=neuroqc.pipeline.StageModel.canonicalOrder();
            names=fieldnames(opts.stepModes)';
            assert(isempty(setdiff(names,known)),'NeuroQC:UnknownStage','Unknown workflow step');
            selected={};fixed={};
            for k=1:numel(names)
                mode=char(opts.stepModes.(names{k}));
                assert(any(strcmp(mode,{'off','fixed','search'})),'NeuroQC:Workflow','Use off, fixed, or search');
                if ~strcmp(mode,'off'), selected{end+1}=names{k}; end %#ok<AGROW>
                if strcmp(mode,'fixed'),fixed{end+1}=names{k};end %#ok<AGROW>
            end
            if isfield(opts,'selectedSteps') && ~isempty(opts.selectedSteps)
                assert(isempty(setxor(opts.selectedSteps,selected)),'NeuroQC:Workflow','selectedSteps and stepModes disagree');
            end
            assert(~isempty(selected),'NeuroQC:ScopeRequired','All steps are off; enable a fixed or search step');
            opts.selectedSteps=selected;
            defaults=neuroqc.pipeline.SearchSpace.defaultERP(); mapping=neuroqc.pipeline.StageModel.dimensionStages();
            for name=fieldnames(defaults)'
                f=name{1};if ~isfield(space,f),space.(f)=defaults.(f);end
                if isempty(intersect(mapping.(f),fixed)) || strcmp(f,'fullWorkflow'),continue;end
                if isfield(opts,'frozen') && isfield(opts.frozen,f),space.(f)={opts.frozen.(f)};end
                assert(numel(space.(f))==1,'NeuroQC:FixedStepHasChoices', ...
                    'Fixed step still has multiple values for %s; lock that dimension explicitly',f);
            end
        end
    end
end
