classdef Contract
    %CONTRACT What will be measured: the analysis definition.
    %
    %   ERP analysis
    %   c = neuroqc.eval.Contract( ...
    %       'conditions', {'target', {'11','21'}; 'standard', {'31'}}, ...
    %       'epoch', [-0.2 1.0], 'baseline', [-0.2 0], ...
    %       'components', {'P3', [0.30 0.60], {'Pz','CPz','POz'}, 'mean'; ...
    %                      'N2', [0.20 0.30], {'Fz','FCz'}, {'peakLatency','negative'}});
    %
    %   components  rows of: name, [start end] s, ROI labels, measure.
    %       measure 'mean' (default)  mean amplitude in the window (uV)
    %               'peakAmplitude'   amplitude of the averaged peak (uV)
    %               'peakLatency'     latency of the averaged peak (ms)
    %       Give {'peakLatency','negative'} to set the peak polarity
    %       ('positive' default, 'negative').
    %
    %   trials (optional) restricts which trials count, e.g. to drop a
    %   practice block (the rule is applied once, on the starting dataset):
    %       struct('mode','time_ranges','ranges',[60 Inf])     seconds
    %       struct('mode','marker_ranges','startCode','S 1','endCode','S 2')
    %       struct('mode','urevents','ids',[...])
    %
    %   These choices define the measured quantity; they are fixed inputs
    %   and are never searched.

    properties
        conditions = struct('name', {}, 'events', {})
        epoch = []
        baseline = []
        components = struct('name', {}, 'window', {}, 'roi', {}, 'measure', {}, 'polarity', {})
        trials = struct('mode', 'all')
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
                                meas = 'mean'; pol = 'positive';
                                if size(v, 2) >= 4 && ~isempty(v{r, 4})
                                    m = v{r, 4};
                                    if iscell(m), meas = char(m{1}); if numel(m) > 1, pol = lower(char(m{2})); end
                                    else, meas = char(m); end
                                end
                                obj.components(end+1) = struct('name', char(v{r, 1}), 'window', double(v{r, 2}), ...
                                    'roi', {cellstr(v{r, 3})}, 'measure', meas, 'polarity', pol);
                            end
                        else
                            obj.components = v;
                        end
                    case {'epoch','baseline'}
                        obj.(name) = double(v(:)');
                    case 'trials'
                        assert(isstruct(v) && isfield(v, 'mode'), 'NeuroQC:Contract', 'trials must be a struct with a mode field');
                        obj.trials = v;
                    otherwise
                        error('NeuroQC:Contract', 'Unknown contract field %s', name);
                end
            end
        end

        function ev = allEvents(obj)
            ev = unique([obj.conditions.events], 'stable');
        end

        function c = effectiveConditions(obj)
            c = obj.conditions;
        end

        function w = effectiveEpoch(obj)
            w = obj.epoch;
        end

        function w = effectiveBaseline(obj)
            w = obj.baseline;
        end

        function units = objectiveUnits(obj)
            units = {};
            for k = 1:numel(obj.components)
                if strcmp(obj.components(k).measure, 'peakLatency'), units{end+1} = 'ms'; %#ok<AGROW>
                else, units{end+1} = 'uV'; end %#ok<AGROW>
            end
        end

        function names = objectiveNames(obj)
            names = arrayfun(@(c) sprintf('%s.%s', c.name, c.measure), obj.components, 'UniformOutput', false);
        end

        function validate(obj, state)
            % Fail early, with the reason, before anything is run.
            assert(~isempty(obj.components), 'NeuroQC:Contract', 'Define at least one component (name, window, ROI).');
            assert(~isempty(obj.conditions), 'NeuroQC:Contract', 'Define at least one condition (name + event types).');
            assert(numel(obj.epoch) == 2 && obj.epoch(1) < obj.epoch(2), 'NeuroQC:Contract', ...
                'epoch must be [start end] in seconds around the event.');
            names = {obj.conditions.name};
            assert(numel(unique(names)) == numel(names), 'NeuroQC:Contract', 'Condition names must be unique.');
            ev = [obj.conditions.events];
            assert(numel(unique(ev)) == numel(ev), 'NeuroQC:Contract', 'An event type belongs to two conditions.');
            assert(obj.epoch(1) < 0 && obj.epoch(2) > 0, 'NeuroQC:Contract', 'ERP epochs must include time 0 (start < 0 < end).');
            assert(numel(obj.baseline) == 2 && obj.baseline(1) < obj.baseline(2) && ...
                obj.baseline(1) >= obj.epoch(1) && obj.baseline(2) <= obj.epoch(2), 'NeuroQC:Contract', ...
                'baseline must lie inside the epoch.');
            for k = 1:numel(obj.components)
                w = obj.components(k).window; cname = obj.components(k).name;
                assert(numel(w) == 2 && w(1) < w(2) && w(1) >= obj.epoch(1) && w(2) <= obj.epoch(2), ...
                    'NeuroQC:Contract', 'Component %s window must lie inside the epoch.', cname);
                assert(~isempty(obj.components(k).roi), 'NeuroQC:Contract', 'Component %s needs ROI channels.', cname);
                assert(any(strcmp(obj.components(k).measure, {'mean','peakAmplitude','peakLatency'})), 'NeuroQC:Contract', ...
                    'Component %s: measure must be mean, peakAmplitude or peakLatency.', cname);
                assert(any(strcmp(obj.components(k).polarity, {'positive','negative'})), 'NeuroQC:Contract', ...
                    'Component %s: polarity must be positive or negative.', cname);
            end
            obj.validateTrialRule();
            if nargin < 2 || isempty(state), return; end
            missing = setdiff(lower([obj.conditions.events]), lower(state.eventTypes));
            assert(isempty(missing), 'NeuroQC:Contract', 'Event type(s) not in the dataset: %s (present: %s)', ...
                strjoin(missing, ', '), strjoin(state.eventTypes, ', '));
            roi = obj.allRoi();
            absent = setdiff(lower(roi), lower(state.labels));
            restorable = {};
            if isfield(state, 'restorableChannels') && ~isempty(state.restorableChannels)
                restorable = lower(state.removedChannels(state.restorableChannels));
            end
            % a removed channel that a restore step can bring back is a valid ROI
            % channel; pipelines without the restore fail with that reason
            assert(all(ismember(absent, restorable)), 'NeuroQC:Contract', 'ROI channel(s) not in the dataset: %s', ...
                strjoin(setdiff(absent, restorable), ', '));
            if state.isEpoched
                w = obj.effectiveEpoch();
                assert(state.xmin <= w(1) + 1.5/state.srate && state.xmax >= w(2) - 1.5/state.srate, ...
                    'NeuroQC:Contract', 'The dataset epochs [%g %g] s do not cover the contract epoch.', state.xmin, state.xmax);
            end
        end

        function roi = allRoi(obj)
            roi = unique([obj.components.roi]);
        end

        function validateTrialRule(obj)
            r = obj.trials;
            switch r.mode
                case 'all'
                case 'time_ranges'
                    assert(isfield(r, 'ranges') && isnumeric(r.ranges) && size(r.ranges, 2) == 2 && ...
                        all(r.ranges(:, 2) > r.ranges(:, 1)), 'NeuroQC:Contract', 'time_ranges needs ranges = [start end; ...] in s');
                case 'marker_ranges'
                    assert(isfield(r, 'startCode') && isfield(r, 'endCode'), 'NeuroQC:Contract', 'marker_ranges needs startCode and endCode');
                case 'urevents'
                    assert(isfield(r, 'ids') && isnumeric(r.ids), 'NeuroQC:Contract', 'urevents needs ids');
                otherwise
                    error('NeuroQC:Contract', 'Unknown trial rule mode %s', r.mode);
            end
        end

        function s = toStruct(obj)
            s = struct('conditions', {obj.conditions}, 'epoch', obj.epoch, ...
                'baseline', obj.baseline, 'components', {obj.components}, 'trials', obj.trials);
        end
    end
end

function ev = eventList(v)
if isnumeric(v), ev = arrayfun(@(x) sprintf('%g', x), v(:)', 'UniformOutput', false);
else, ev = cellfun(@(x) strtrim(char(string(x))), cellstr(v), 'UniformOutput', false); ev = ev(:)'; end
end
