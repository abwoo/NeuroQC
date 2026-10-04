function c = nqc_contract(varargin)
%NQC_CONTRACT Small ERP contract for tests (one condition, P3 at Pz).
c = pipecompare.eval.Contract('conditions', {'a', {'11'}}, 'epoch', [-0.2 1], 'baseline', [-0.2 0], ...
    'components', {'P3', [0.3 0.6], {'Pz'}}, varargin{:});
end
