classdef Contract
    %CONTRACT What will be measured: the analysis definition.
    %
    %   c = neuroqc.eval.Contract( ...
    %       'conditions', {'target', {'11','21'}; 'standard', {'31'}}, ...
    %       'epoch', [-0.2 1.0], 'baseline', [-0.2 0], ...
    %       'components', {'P3', [0.30 0.60], {'Pz','CPz','POz'}});
    %
    %   conditions  N x 2 cell: name, event types
    %   epoch       [start end] in s (used by the 'epoch' step and the
    %               evaluation view)
    %   baseline    [start end] in s (used by 'baseline' and the
    %               evaluation view)
    %   components  M x 3 cell: name, [start end] s, ROI channel labels.
    %               The score of a trial is its mean amplitude over the
    %               ROI channels and the window, after baseline removal.
    %
    %   These choices define the measured quantity, so they are fixed
    %   inputs and are never searched.

    properties
        conditions = struct('name', {}, 'events', {})
        epoch = []
        baseline = []
        components = struct('name', {}, 'window', {}, 'roi', {})
    end

    methods
        function obj = Contract(varargin)
            for k = 1:2:numel(varargin)
                name = varargin{k}; v = varargin{k+1};
                switch name
                    case 'conditions'
                        if iscell(v)
                            for r = 1:size(v, 1)
                                obj.conditions(end+1) = struct('name', char(v{r, 1}), 'events', {eventList(v{r, 2})});
                            end
                        else
                            obj.conditions = v;
                        end
                    case 'components'
                        if iscell(v)
                            for r = 1:size(v, 1)
                                obj.components(end+1) = struct('name', char(v{r, 1}), 'window', double(v{r, 2}), ...
                                    'roi', {cellstr(v{r, 3})});
                            end
                        else
                            obj.components = v;
                        end
                    case {'epoch','baseline'}
                        obj.(name) = double(v(:)');
                    otherwise
                        error('NeuroQC:Contract', 'Unknown contract field %s', name);
                end
            end
        end

        function ev = allEvents(obj)
            ev = unique([obj.conditions.events], 'stable');
        end

        function validate(obj, state)
            % Fail early, with the reason, before anything is run.
            assert(~isempty(obj.conditions), 'NeuroQC:Contract', 'Define at least one condition (name + event types).');
            assert(~isempty(obj.components), 'NeuroQC:Contract', 'Define at least one component (name, window, ROI).');
            assert(numel(obj.epoch) == 2 && obj.epoch(1) < 0 && obj.epoch(2) > 0, 'NeuroQC:Contract', ...
                'epoch must be [start end] in seconds around the event (start < 0 < end).');
            assert(numel(obj.baseline) == 2 && obj.baseline(1) < obj.baseline(2) && ...
                obj.baseline(1) >= obj.epoch(1) && obj.baseline(2) <= obj.epoch(2), 'NeuroQC:Contract', ...
                'baseline must lie inside the epoch.');
            names = {obj.conditions.name};
            assert(numel(unique(names)) == numel(names), 'NeuroQC:Contract', 'Condition names must be unique.');
            ev = [obj.conditions.events];
            assert(numel(unique(ev)) == numel(ev), 'NeuroQC:Contract', 'An event type belongs to two conditions.');
            for k = 1:numel(obj.components)
                w = obj.components(k).window;
                assert(numel(w) == 2 && w(1) < w(2) && w(1) >= obj.epoch(1) && w(2) <= obj.epoch(2), ...
                    'NeuroQC:Contract', 'Component %s window must lie inside the epoch.', obj.components(k).name);
                assert(~isempty(obj.components(k).roi), 'NeuroQC:Contract', 'Component %s needs ROI channels.', obj.components(k).name);
            end
            if nargin < 2 || isempty(state), return; end
            missing = setdiff(lower(ev), lower(state.eventTypes));
            assert(isempty(missing), 'NeuroQC:Contract', 'Event type(s) not in the dataset: %s (present: %s)', ...
                strjoin(missing, ', '), strjoin(state.eventTypes, ', '));
            roi = unique([obj.components.roi]);
            absent = setdiff(lower(roi), lower(state.labels));
            assert(isempty(absent), 'NeuroQC:Contract', 'ROI channel(s) not in the dataset: %s', strjoin(absent, ', '));
            if state.isEpoched
                assert(state.xmin <= obj.epoch(1) + 1.5/state.srate && state.xmax >= obj.epoch(2) - 1.5/state.srate, ...
                    'NeuroQC:Contract', 'The dataset epochs [%g %g] s do not cover the contract epoch.', state.xmin, state.xmax);
            end
        end

        function s = toStruct(obj)
            s = struct('conditions', {obj.conditions}, 'epoch', obj.epoch, ...
                'baseline', obj.baseline, 'components', {obj.components});
        end
    end
end

function ev = eventList(v)
if isnumeric(v), ev = arrayfun(@(x) sprintf('%g', x), v(:)', 'UniformOutput', false);
else, ev = cellfun(@(x) strtrim(char(string(x))), cellstr(v), 'UniformOutput', false); ev = ev(:)'; end
end
