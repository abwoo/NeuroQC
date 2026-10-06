classdef Contract
    %CONTRACT What will be measured: the analysis definition.
    %
    %   ERP analysis
    %   c = pipecompare.eval.Contract( ...
    %       'conditions', {'target', {'rare1','rare2'}; 'standard', {'frequent'}}, ...
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
    %   A fifth column scores contralateral minus ipsilateral (N2pc, LRP):
    %   two ROI electrodes, one per hemisphere, and for each condition the
    %   one contralateral to it, e.g. conditions {'left target', ...;
    %   'right target', ...} with {'N2pc', [0.2 0.275], {'PO7','PO8'},
    %   'mean', {'PO8','PO7'}}. Each trial's score is then the
    %   contralateral electrode minus the other.
    %
    %   Band power (e.g. resting state)
    %   c = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', 2, ...
    %       'bands', {'alpha', [8 12], {'O1','Oz','O2'}});
    %       continuous data are cut into consecutive 2 s segments (EEGLAB's
    %       eeg_regepochs on PipeCompare's copy, events 'pipecompare_seg' with their
    %       urevents, so a segment is the same segment in every candidate);
    %       score = log10 of the band power per segment (ROI mean, Hann
    %       taper), precision = SD / sqrt(number of segments).
    %   With 'conditions' and 'epoch' instead of 'segment', the band power
    %   of each epoch is scored (event-related band power).
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
        analysis = 'erp'          % 'erp' | 'bandpower'
        bands = struct('name', {}, 'freq', {}, 'roi', {})
        segment = []              % s; band power of continuous data
        conditions = struct('name', {}, 'events', {})
        epoch = []
        baseline = []
        components = struct('name', {}, 'window', {}, 'roi', {}, 'measure', {}, 'polarity', {})
        trials = struct('mode', 'all')
    end

    properties (Constant)
        SegmentEvent = 'pipecompare_seg'  % event type of the segments PipeCompare marks on its copy
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
                            % (the field contra only when used: contracts without
                            % it keep their earlier identity)
                            lateral = size(v, 2) >= 5 && any(~cellfun(@isempty, v(:, 5)));
                            comps = [];
                            for r = 1:size(v, 1)
                                meas = 'mean'; pol = 'positive';
                                if size(v, 2) >= 4 && ~isempty(v{r, 4})
                                    m = v{r, 4};
                                    if iscell(m), meas = char(m{1}); if numel(m) > 1, pol = lower(char(m{2})); end
                                    else, meas = char(m); end
                                end
                                c = struct('name', char(v{r, 1}), 'window', double(v{r, 2}), ...
                                    'roi', {cellstr(v{r, 3})}, 'measure', meas, 'polarity', pol);
                                if lateral
                                    c.contra = {};
                                    if ~isempty(v{r, 5}), c.contra = reshape(cellstr(v{r, 5}), 1, []); end
                                end
                                comps = [comps c]; %#ok<AGROW>
                            end
                            if ~isempty(comps), obj.components = comps; end
                        else
                            obj.components = v;
                        end
                    case {'epoch','baseline'}
                        obj.(name) = double(v(:)');
                    case 'analysis'
                        obj.analysis = lower(char(v));
                        assert(any(strcmp(obj.analysis, {'erp','bandpower'})), 'PipeCompare:Contract', ...
                            'analysis must be erp or bandpower');
                    case 'bands'
                        for r = 1:size(v, 1)
                            obj.bands(end+1) = struct('name', char(v{r, 1}), 'freq', double(v{r, 2}), 'roi', {cellstr(v{r, 3})});
                        end
                    case 'segment'
                        obj.segment = double(v);
                    case 'trials'
                        assert(isstruct(v) && isfield(v, 'mode'), 'PipeCompare:Contract', 'trials must be a struct with a mode field');
                        obj.trials = v;
                    otherwise
                        error('PipeCompare:Contract', 'Unknown contract field %s', name);
                end
            end
            if obj.isSegmented()
                given = intersect(cellfun(@char, varargin(1:2:end), 'UniformOutput', false), {'conditions', 'epoch', 'baseline'});
                assert(isempty(given), 'PipeCompare:Contract', ['Band power takes either segment (continuous data) or ', ...
                    'conditions and epoch (event-related), not both; %s would be ignored.'], strjoin(given, ', '));
                % the segments are the trials: one condition, time-locked to
                % the segment events, window = the segment
                obj.conditions = struct('name', 'segments', 'events', {{pipecompare.eval.Contract.SegmentEvent}});
                obj.epoch = [0 obj.segment];
                obj.baseline = [];
            end
        end

        function tf = isSegmented(obj)
            % band power of consecutive segments of continuous data
            tf = strcmp(obj.analysis, 'bandpower') && ~isempty(obj.segment);
        end

        function tf = isLateral(obj, k)
            % component k is scored contralateral minus ipsilateral
            tf = isfield(obj.components, 'contra') && ~isempty(obj.components(k).contra);
        end

        function ev = allEvents(obj)
            ev = unique([obj.conditions.events], 'stable');
        end

        function units = objectiveUnits(obj)
            units = {};
            if strcmp(obj.analysis, 'bandpower')
                units = repmat({'log10(uV^2)'}, 1, numel(obj.bands)); return;
            end
            for k = 1:numel(obj.components)
                if strcmp(obj.components(k).measure, 'peakLatency'), units{end+1} = 'ms'; %#ok<AGROW>
                else, units{end+1} = 'uV'; end %#ok<AGROW>
            end
        end

        function names = objectiveNames(obj)
            if strcmp(obj.analysis, 'bandpower')
                names = arrayfun(@(b) sprintf('%s.logpower', b.name), obj.bands, 'UniformOutput', false); return;
            end
            names = arrayfun(@(c) sprintf('%s.%s', c.name, c.measure), obj.components, 'UniformOutput', false);
        end

        function validate(obj, state)
            % Fail early, with the reason, before anything is run.
            if strcmp(obj.analysis, 'bandpower')
                obj.validateBands(nargin > 1 && ~isempty(state), state);
                return;
            end
            assert(~isempty(obj.components), 'PipeCompare:Contract', 'Define at least one component (name, window, ROI).');
            assert(~isempty(obj.conditions), 'PipeCompare:Contract', 'Define at least one condition (name + event types).');
            assert(numel(obj.epoch) == 2 && obj.epoch(1) < obj.epoch(2), 'PipeCompare:Contract', ...
                'epoch must be [start end] in seconds around the event.');
            names = {obj.conditions.name};
            assert(numel(unique(names)) == numel(names), 'PipeCompare:Contract', 'Condition names must be unique.');
            ev = [obj.conditions.events];
            assert(numel(unique(ev)) == numel(ev), 'PipeCompare:Contract', 'An event type belongs to two conditions.');
            assert(obj.epoch(1) < 0 && obj.epoch(2) > 0, 'PipeCompare:Contract', 'ERP epochs must include time 0 (start < 0 < end).');
            assert(numel(obj.baseline) == 2 && obj.baseline(1) < obj.baseline(2) && ...
                obj.baseline(1) >= obj.epoch(1) && obj.baseline(2) <= obj.epoch(2), 'PipeCompare:Contract', ...
                'baseline must lie inside the epoch.');
            for k = 1:numel(obj.components)
                w = obj.components(k).window; cname = obj.components(k).name;
                assert(numel(w) == 2 && w(1) < w(2) && w(1) >= obj.epoch(1) && w(2) <= obj.epoch(2), ...
                    'PipeCompare:Contract', 'Component %s window must lie inside the epoch.', cname);
                assert(~isempty(obj.components(k).roi), 'PipeCompare:Contract', 'Component %s needs ROI channels.', cname);
                assert(any(strcmp(obj.components(k).measure, {'mean','peakAmplitude','peakLatency'})), 'PipeCompare:Contract', ...
                    'Component %s: measure must be mean, peakAmplitude or peakLatency.', cname);
                assert(any(strcmp(obj.components(k).polarity, {'positive','negative'})), 'PipeCompare:Contract', ...
                    'Component %s: polarity must be positive or negative.', cname);
                if obj.isLateral(k)
                    comp = obj.components(k);
                    assert(numel(comp.roi) == 2 && numel(comp.contra) == numel(obj.conditions) && ...
                        all(ismember(lower(comp.contra), lower(comp.roi))), 'PipeCompare:Contract', ...
                        ['Component %s (contralateral minus ipsilateral) needs two ROI electrodes and, ', ...
                        'for each condition, the one contralateral to it.'], cname);
                end
            end
            obj.validateTrialRule();
            if nargin < 2 || isempty(state), return; end
            % event types are matched exactly, as pop_epoch and the scoring match
            % them ('S 1' and 's 1' are different types)
            missing = setdiff([obj.conditions.events], state.eventTypes);
            if ~isempty(missing)
                hint = '';
                [near, at] = ismember(lower(missing), lower(state.eventTypes));
                if any(near)
                    hint = sprintf(' Event types are case-sensitive: did you mean %s?', ...
                        strjoin(strcat('''', state.eventTypes(at(near)), ''''), ', '));
                end
                error('PipeCompare:Contract', 'Event type(s) not in the dataset: %s (present: %s).%s', ...
                    strjoin(missing, ', '), strjoin(state.eventTypes, ', '), hint);
            end
            roi = obj.allRoi();
            absent = setdiff(lower(roi), lower(state.labels));
            restorable = {};
            if isfield(state, 'restorableChannels') && ~isempty(state.restorableChannels)
                restorable = lower(state.removedChannels(state.restorableChannels));
            end
            % a removed channel that a restore step can bring back is a valid ROI
            % channel; pipelines without the restore fail with that reason
            assert(all(ismember(absent, restorable)), 'PipeCompare:Contract', 'ROI channel(s) not in the dataset: %s', ...
                strjoin(setdiff(absent, restorable), ', '));
            if state.isEpoched
                w = obj.epoch;
                assert(state.xmin <= w(1) + 1.5/state.srate && state.xmax >= w(2) - 1.5/state.srate, ...
                    'PipeCompare:Contract', 'The dataset epochs [%g %g] s do not cover the contract epoch.', state.xmin, state.xmax);
            end
        end

        function validateBands(obj, haveState, state)
            assert(~isempty(obj.bands), 'PipeCompare:Contract', 'Define at least one band (name, [f1 f2] Hz, ROI).');
            for k = 1:numel(obj.bands)
                f = obj.bands(k).freq;
                assert(numel(f) == 2 && f(1) > 0 && f(1) < f(2), 'PipeCompare:Contract', ...
                    'Band %s: [f1 f2] Hz with 0 < f1 < f2.', obj.bands(k).name);
                assert(~isempty(obj.bands(k).roi), 'PipeCompare:Contract', 'Band %s needs ROI channels.', obj.bands(k).name);
            end
            if obj.isSegmented()
                assert(isscalar(obj.segment) && obj.segment > 0, 'PipeCompare:Contract', 'segment must be a length in s.');
                % a segment of T s resolves 1/T Hz; two cycles of the lowest band
                % edge must fit in it for a stable estimate there
                fmin = min(arrayfun(@(b) b.freq(1), obj.bands));
                assert(obj.segment >= 2 / fmin, 'PipeCompare:Contract', ['Segments of %g s hold fewer than two cycles ', ...
                    'of %g Hz; use segment >= %g s.'], obj.segment, fmin, 2 / fmin);
            else
                assert(~isempty(obj.conditions) && numel(obj.epoch) == 2 && obj.epoch(1) < obj.epoch(2), ...
                    'PipeCompare:Contract', 'Band power needs either segment (continuous data) or conditions and epoch.');
                bl = obj.baseline;   % optional here; when given, as for ERPs
                assert(isempty(bl) || (numel(bl) == 2 && bl(1) < bl(2) && bl(1) >= obj.epoch(1) && bl(2) <= obj.epoch(2)), ...
                    'PipeCompare:Contract', 'baseline must lie inside the epoch.');
            end
            obj.validateTrialRule();
            if ~haveState, return; end
            fmax = max(arrayfun(@(b) b.freq(2), obj.bands));
            assert(fmax < state.srate / 2, 'PipeCompare:Contract', 'Band edge %g Hz is at or above Nyquist (%g Hz).', fmax, state.srate / 2);
            if obj.isSegmented()
                assert(~state.isEpoched, 'PipeCompare:Contract', ['Segments are cut from continuous data; this dataset is ', ...
                    'epoched (use conditions and epoch for event-related band power).']);
            else
                missing = setdiff([obj.conditions.events], state.eventTypes);
                assert(isempty(missing), 'PipeCompare:Contract', 'Event type(s) not in the dataset: %s', strjoin(missing, ', '));
            end
            absent = setdiff(lower(obj.allRoi()), lower(state.labels));
            assert(isempty(absent), 'PipeCompare:Contract', 'ROI channel(s) not in the dataset: %s', strjoin(absent, ', '));
        end

        function roi = allRoi(obj)
            roi = unique([obj.components.roi obj.bands.roi]);
        end

        function validateTrialRule(obj)
            r = obj.trials;
            switch r.mode
                case 'all'
                case 'time_ranges'
                    assert(isfield(r, 'ranges') && isnumeric(r.ranges) && size(r.ranges, 2) == 2 && ...
                        all(r.ranges(:, 2) > r.ranges(:, 1)), 'PipeCompare:Contract', 'time_ranges needs ranges = [start end; ...] in s');
                case 'marker_ranges'
                    assert(isfield(r, 'startCode') && isfield(r, 'endCode'), 'PipeCompare:Contract', 'marker_ranges needs startCode and endCode');
                case 'urevents'
                    assert(isfield(r, 'ids') && isnumeric(r.ids), 'PipeCompare:Contract', 'urevents needs ids');
                otherwise
                    error('PipeCompare:Contract', 'Unknown trial rule mode %s', r.mode);
            end
        end

        function s = toStruct(obj)
            s = struct('conditions', {obj.conditions}, 'epoch', obj.epoch, ...
                'baseline', obj.baseline, 'components', {obj.components}, 'trials', obj.trials);
            if strcmp(obj.analysis, 'bandpower')   % (ERP contracts keep their earlier identity)
                s.analysis = obj.analysis; s.bands = obj.bands; s.segment = obj.segment;
            end
        end
    end
end

function ev = eventList(v)
if isnumeric(v), ev = arrayfun(@(x) sprintf('%g', x), v(:)', 'UniformOutput', false);
else, ev = cellfun(@(x) strtrim(char(string(x))), cellstr(v), 'UniformOutput', false); ev = ev(:)'; end
end
