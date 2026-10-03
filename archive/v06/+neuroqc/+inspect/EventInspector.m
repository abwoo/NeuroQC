classdef EventInspector
    % EventInspector - Mark/event statistics, anomaly detection, timeline, preview
    
    methods (Static)
        function r = inspect(EEG, opts)
            if nargin < 2, opts = struct(); end
            if ~isfield(opts, 'minIntervalMs'), opts.minIntervalMs = 50; end
            if ~isfield(opts, 'expectedIntervalMs'), opts.expectedIntervalMs = []; end
            if ~isfield(opts, 'intervalTolerance'), opts.intervalTolerance = 0.5; end
            
            events = EEG.event;
            r = struct();
            r.status = 'PASS';
            r.warnings = {};
            
            if isempty(events)
                r.status = 'FAIL';
                r.warnings = {'No events present'};
                r.types = {};
                r.counts = [];
                r.timeline = table();
                return;
            end
            
            % Normalize type codes to char
            n = numel(events);
            types = cell(n, 1);
            latencies = nan(n, 1);
            for i = 1:n
                t = events(i).type;
                if isnumeric(t)
                    types{i} = num2str(t);
                elseif ischar(t)
                    types{i} = t;
                elseif isstring(t)
                    types{i} = char(t);
                else
                    types{i} = char(string(t));
                end
                if isfield(events, 'latency') && ~isempty(events(i).latency)
                    latencies(i) = events(i).latency;
                end
            end
            
            [utypes, ~, ic] = unique(types);
            counts = accumarray(ic, 1);
            [counts, order] = sort(counts, 'descend');
            utypes = utypes(order);
            
            r.types = utypes;
            r.counts = counts;
            r.latencies = latencies;
            r.typeOfEvent = types;
            
            % Boundary count
            r.boundaryCount = sum(strcmp(types, 'boundary'));
            if r.boundaryCount > 0
                r.status = 'WARNING';
                r.warnings{end+1} = sprintf('%d boundary events present', r.boundaryCount);
            end
            
            % Unknown / suspicious codes
            % EEGLAB stores numeric event codes as 's123'/'S123' strings —
            % those are a normal encoding, not a suspicious style. Only flag
            % s/S-prefixed codes that are not purely numeric after the prefix.
            isSPrefixed = startsWith(string(utypes), "S") | startsWith(string(utypes), "s");
            numericStyle = ~cellfun(@isempty, regexp(utypes, '^[sS][0-9]+$', 'once'));
            unknown = utypes(isSPrefixed & ~numericStyle);
            r.unknownStyle = unknown;
            
            % Duplicate latencies (same type)
            dupCount = 0;
            for i = 1:numel(utypes)
                lat = latencies(strcmp(types, utypes{i}));
                lat = lat(isfinite(lat));
                dupCount = dupCount + sum(diff(sort(lat)) == 0);
            end
            r.duplicateLatencies = dupCount;
            if dupCount > 0
                if strcmp(r.status, 'PASS'), r.status = 'REVIEW'; end
                r.warnings{end+1} = sprintf('%d duplicate event latencies', dupCount);
            end
            
            % Interval checks (all non-boundary, sorted)
            keep = ~strcmp(types, 'boundary') & isfinite(latencies);
            lat = sort(latencies(keep));
            intervalsSamp = diff(lat);
            intervalsMs = intervalsSamp / EEG.srate * 1000;
            r.intervalMs = intervalsMs;
            r.minIntervalMs = min(intervalsMs);
            r.medianIntervalMs = median(intervalsMs);
            
            tooClose = intervalsMs < opts.minIntervalMs;
            r.tooCloseCount = sum(tooClose);
            if r.tooCloseCount > 0
                r.status = 'REVIEW';
                r.warnings{end+1} = sprintf('%d intervals < %g ms', r.tooCloseCount, opts.minIntervalMs);
            end
            
            % Monotonicity
            r.nonMonotonic = sum(diff(latencies(~isnan(latencies))) < 0);
            if r.nonMonotonic > 0
                r.status = 'REVIEW';
                r.warnings{end+1} = sprintf('%d non-monotonic latencies', r.nonMonotonic);
            end
            
            % Timeline table for display
            [~, idx] = sort(latencies);
            types_sorted = types(idx);
            lat_sorted = latencies(idx);
            keepT = ~strcmp(types_sorted, 'boundary');
            % Subsample long recordings for readability
            maxPoints = 500;
            show = find(keepT);
            if numel(show) > maxPoints
                show = show(round(linspace(1, numel(show), maxPoints)));
            end
            r.timeline = table(lat_sorted(show), types_sorted(show), ...
                'VariableNames', {'latency', 'type'});
            
            r.conditionCounts = containers.Map();
            r.totalEvents = n;
        end
        
        function preview = eventPreview(EEG, eventType, preMs, postMs)
            % Extract data around first (or nth) occurrence of eventType
            if nargin < 3, preMs = 1000; end
            if nargin < 4, postMs = 1500; end
            
            events = EEG.event;
            lat = [];
            for i = 1:numel(events)
                t = events(i).type;
                if isnumeric(t), t = num2str(t); end
                if strcmp(char(t), eventType)
                    lat = events(i).latency;
                    break;
                end
            end
            if isempty(lat)
                error('Event type "%s" not found', eventType);
            end
            
            preSamp = round(preMs / 1000 * EEG.srate);
            postSamp = round(postMs / 1000 * EEG.srate);
            i0 = max(1, round(lat) - preSamp);
            i1 = min(size(EEG.data,2), round(lat) + postSamp);
            
            data = double(EEG.data(:, i0:i1));
            t = ((i0:i1) - round(lat)) / EEG.srate;
            
            preview = struct();
            preview.eventType = eventType;
            preview.latency = lat;
            preview.t = t;
            preview.data = data;
            preview.preMs = preMs;
            preview.postMs = postMs;
            preview.labels = {EEG.chanlocs.labels};
        end
        
        function plotTimeline(r, opts)
            if nargin < 2, opts = struct(); end
            if ~isfield(opts, 'maxLabels'), opts.maxLabels = 12; end
            
            tl = r.timeline;
            if isempty(tl), return; end
            
            utypes = unique(tl.type, 'stable');
            showTypes = utypes(1:min(numel(utypes), opts.maxLabels));
            
            figure('Name', 'Event Timeline');
            hold on;
            for i = 1:numel(showTypes)
                m = strcmp(tl.type, showTypes{i});
                y = i * ones(sum(m), 1);
                plot(tl.latency(m), y, '|', 'MarkerSize', 10, 'LineWidth', 1.2);
            end
            set(gca, 'YTick', 1:numel(showTypes), 'YTickLabel', showTypes);
            xlabel('Latency (samples)');
            title('Event timeline');
            grid on;
            hold off;
        end
        
        function summary(r)
            fprintf('=== Event Inspector ===\n');
            fprintf('Status: %s\n', r.status);
            fprintf('Types (%d):\n', numel(r.types));
            for i = 1:numel(r.types)
                fprintf('  %-20s %d\n', r.types{i}, r.counts(i));
            end
            fprintf('Boundaries: %d\n', r.boundaryCount);
            fprintf('Duplicate latencies: %d\n', r.duplicateLatencies);
            fprintf('Too-close intervals: %d\n', r.tooCloseCount);
            for i = 1:numel(r.warnings)
                fprintf('  WARN: %s\n', r.warnings{i});
            end
        end
    end
end