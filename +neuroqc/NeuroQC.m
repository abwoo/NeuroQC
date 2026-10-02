classdef NeuroQC
    % NeuroQC - Goal-driven EEG Preprocessing & ERP Optimization Toolbox
    % Main entry point and namespace
    
    properties (Constant)
        Version = '0.6.0';
        % Common ERP component names offered as suggestions by the GUI
        % "New..." dialog. Any name is accepted; this list is not a filter.
        SupportedERPComponents = {'N200', 'P300', 'N400', 'P200', 'ERN'};
    end
    
    methods (Static)
        function out = recommend(source, contract, space, opts)
            % Generate-only advice: recipes for EEGLAB; never processes EEG.
            out = neuroqc.advice.RecommendPath.run(source, contract, space, opts);
        end

        function out = preprocess(source, contract, space, opts)
            % Legacy alias — now generate-only (EEGLAB executes recipes).
            out = neuroqc.advice.RecommendPath.run(source, contract, space, opts);
        end

        function ver = version()
            ver = neuroqc.NeuroQC.Version;
        end
        
        function checkEnvironment()
            % Verify MATLAB + EEGLAB availability
            if ~exist('eeglab', 'file')
                warning('NeuroQC:EEGLABNotFound', 'EEGLAB not found on path. Some functions will be unavailable.');
            end
            if ~exist('pop_loadset', 'file')
                warning('NeuroQC:EEGLABFuncsMissing', 'EEGLAB functions not available.');
            end
        end
    end
end