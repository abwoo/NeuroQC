classdef OrderSearch
    % Enumerate all topological orders within explicit workflow constraints.
    % Never silently truncate. Order pins are relative precedence, not slots.
    methods (Static)
        function orders=enumerate(types,info,completed,pinned,maxOrders,fixedPositions)
            if nargin<5, maxOrders=10000; end
            if nargin<6,fixedPositions=struct();end
            n=numel(types); edges=false(n); orders={};
            slots=zeros(1,n);
            for name=fieldnames(fixedPositions)'
                ix=find(strcmp(types,name{1}));
                pos=fixedPositions.(name{1});
                % Fail closed with the real reason instead of returning an
                % empty order list that surfaces as a generic no_legal_order.
                assert(~isempty(ix),'NeuroQC:FixedPositionOutOfScope', ...
                    'Fixed position references step "%s", which is not in the selected workflow',name{1});
                assert(isscalar(pos)&&isfinite(pos)&&pos==fix(pos)&&pos>=1&&pos<=n, ...
                    'NeuroQC:FixedPositionOutOfScope', ...
                    'Fixed position for "%s" must be an integer in 1..%d (got %g)',name{1},n,pos);
                slots(ix)=pos;
            end
            pairs=neuroqc.pipeline.StageModel.dependencyPairs(); % after,before
            for k=1:size(pairs,1)
                a=find(strcmp(types,pairs{k,2})); b=find(strcmp(types,pairs{k,1}));
                if ~isempty(a) && ~isempty(b), edges(a,b)=true; end
            end
            pinned=pinned(ismember(pinned,types));
            for k=2:numel(pinned)
                edges(strcmp(types,pinned{k-1}),strcmp(types,pinned{k}))=true;
            end
            walk([]);
            function walk(prefix)
                if numel(prefix)==n
                    assert(numel(orders)<maxOrders,'NeuroQC:OrderLimit', ...
                        'Legal order count exceeds maxOrders; fix more order constraints or explicitly raise the limit. Nothing was truncated/exported.');
                    orders{end+1}=prefix; return;
                end
                remaining=setdiff(1:n,prefix,'stable');
                for ix=remaining
                    position=numel(prefix)+1;
                    if slots(ix)>0 && slots(ix)~=position,continue;end
                    if any(slots(remaining)==position) && slots(ix)~=position,continue;end
                    if any(edges(remaining,ix)), continue; end
                    next=[prefix ix];
                    try
                        neuroqc.pipeline.StageModel.validateTransition(types(next),info,completed);
                    catch ME
                        if strcmp(ME.identifier,'NeuroQC:StepDependency'), continue; end
                        rethrow(ME);
                    end
                    walk(next);
                end
            end
        end
    end
end
