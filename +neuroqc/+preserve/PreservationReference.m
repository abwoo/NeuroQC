classdef PreservationReference
    % PreservationReference - Ground truth / minimal baseline for feature fidelity
    % referenceSource: 'synthetic_truth' | 'minimal' | 'not_available'
    properties
        referenceSource   % char
        contract          % AnalysisContract or []
        conditionNames    % cellstr
        componentNames    % cellstr
        roi               % cellstr channel labels
        epochWindow       % [s]
        baselineWindow    % [s]
        notes             % char
        truth             % optional injection truth struct
        sourceEEG
        truthWaves        % optional struct of reference waves
    end

    methods
        function obj = PreservationReference(source, contract, notes)
            if nargin < 1, source = 'not_available'; end
            if nargin < 2, contract = []; end
            if nargin < 3, notes = ''; end
            obj.referenceSource = char(source);
            obj.contract = contract;
            obj.notes = char(notes);
            obj.truth = struct(); obj.sourceEEG=[];
            obj.truthWaves = struct();
            obj.conditionNames = {};
            obj.componentNames = {};
            obj.roi = {};
            obj.epochWindow = [-0.2 1.0];
            obj.baselineWindow = [-0.2 0];
            if ~isempty(contract)
                obj.conditionNames = contract.conditionNames;
                obj.componentNames = contract.componentNames;
                if ~isempty(contract.targetChannels)
                    obj.roi = contract.targetChannels;
                end
                obj.epochWindow = [contract.epoch.start contract.epoch.end];
                obj.baselineWindow = [contract.baseline.start contract.baseline.end];
            end
        end

        function tf = usable(obj)
            tf = any(strcmp(obj.referenceSource, {'synthetic_truth','minimal'}));
        end

        function s = toStruct(obj)
            s = struct('referenceSource', obj.referenceSource, ...
                'conditionNames', {obj.conditionNames}, ...
                'componentNames', {obj.componentNames}, ...
                'roi', {obj.roi}, ...
                'epochWindow', obj.epochWindow, ...
                'baselineWindow', obj.baselineWindow, ...
                'notes', obj.notes);
        end
    end

    methods (Static)
        function ref = fromTruth(truth, contract)
            % truth from SyntheticEEG.generate (or SyntheticInjection)
            ref = neuroqc.preserve.PreservationReference('synthetic_truth', contract, ...
                'Synthetic injection ground truth');
            ref.truth=truth;
            if isstruct(truth) && isfield(truth,'sourceEEG'), ref.sourceEEG=truth.sourceEEG; end
            if isstruct(truth)
                if isfield(truth, 'conditionNames')
                    ref.conditionNames = truth.conditionNames;
                end
                if isfield(truth, 'p300LatencyMs')
                    ref.notes = sprintf('%s; p300LatencyMs=%g', ref.notes, truth.p300LatencyMs);
                end
            end
        end

        function ref = minimal(contract)
            ref = neuroqc.preserve.PreservationReference('minimal', contract, ...
                'Minimal processing baseline (not physiological ground truth)');
        end

        function ref = unavailable(reason)
            ref = neuroqc.preserve.PreservationReference('not_available', [], reason);
        end
    end
end
