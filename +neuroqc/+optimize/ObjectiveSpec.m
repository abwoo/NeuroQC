classdef ObjectiveSpec
    % ObjectiveSpec - Declared scalarization objective (Layer-3 input)
    % Whitelists qualityVector metric keys; never accepts experimental effects.

    properties
        name        % char label
        metricKey   % field in qualityVector (or quality struct)
        sense       % 'max' | 'min'
        weight      % nonnegative double
        enabled     % logical
        normalize   % 'minmax' | 'none'
    end

    methods
        function obj = ObjectiveSpec(name, metricKey, sense, weight, varargin)
            if nargin < 4, weight = 1; end
            obj.name = char(name);
            obj.metricKey = char(metricKey);
            obj.sense = lower(char(sense));
            obj.weight = double(weight);
            obj.enabled = true;
            obj.normalize = 'minmax';
            if ~isempty(varargin)
                for k = 1:2:numel(varargin)
                    obj.(varargin{k}) = varargin{k+1};
                end
            end
            obj.validate();
        end

        function validate(obj)
            allowed = {'reliability','retention','topoStability','waveformDistortion', ...
                'interpRatio','badRatio','rank','baselineSd','minConditionRetention', ...
                'conditionRetentionSpread','eventLoss','topoFidelity','latencyShiftMs', ...
                'amplitudeError','bandEnergyError'};
            forbidden = {'snr','pvalue','p_value','effectSize','effect_size','tstat', ...
                'fstat','significant','accuracy','auc','glm','anova'};
            key = lower(obj.metricKey);
            if any(strcmp(key, forbidden)) || contains(key,'pvalue') || ...
                    contains(key,'effect') || contains(key,'significan')
                error('NeuroQC:ObjectiveForbidden', ...
                    'Metric key "%s" is a forbidden ranking objective (experimental effect / SNR).', ...
                    obj.metricKey);
            end
            allowedL = lower(allowed);
            if ~any(strcmp(key, allowedL))
                error('NeuroQC:ObjectiveUnknown', ...
                    'Metric key "%s" is not in the qualityVector whitelist.', obj.metricKey);
            end
            if ~any(strcmp(obj.sense, {'max','min'}))
                error('NeuroQC:ObjectiveSense', 'sense must be max or min');
            end
            if ~isscalar(obj.weight) || ~isfinite(obj.weight) || obj.weight < 0
                error('NeuroQC:ObjectiveWeight', 'weight must be a finite nonnegative scalar');
            end
            if ~any(strcmp(obj.normalize, {'minmax','none'}))
                error('NeuroQC:ObjectiveNormalize', 'normalize must be minmax or none');
            end
        end

        function v = rawValue(obj, quality)
            if ~isstruct(quality) || ~isfield(quality, obj.metricKey)
                v = NaN;
                return;
            end
            v = quality.(obj.metricKey);
            if ~(isnumeric(v) || islogical(v)) || ~isscalar(v)
                v = NaN;
                return;
            end
            v = double(v);
        end

        function c = cost(obj, quality)
            % cost = lower is better for ranking
            v = obj.rawValue(quality);
            if ~isfinite(v)
                c = NaN;
            elseif strcmp(obj.sense, 'max')
                c = -v;
            else
                c = v;
            end
        end

        function s = toStruct(obj)
            s = struct('name', obj.name, 'metricKey', obj.metricKey, ...
                'sense', obj.sense, 'weight', obj.weight, ...
                'enabled', obj.enabled, 'normalize', obj.normalize);
        end
    end

    methods (Static)
        function obj = fromStruct(s)
            obj = neuroqc.optimize.ObjectiveSpec(s.name, s.metricKey, s.sense, s.weight);
            if isfield(s,'enabled'), obj.enabled = logical(s.enabled); end
            if isfield(s,'normalize'), obj.normalize = s.normalize; end
            obj.validate();
        end
    end
end
