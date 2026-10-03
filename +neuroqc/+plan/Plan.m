classdef Plan
    %PLAN The processing you want to run from the current dataset onward.
    %
    %   p = neuroqc.plan.Plan();
    %   p = p.add('highpass');                        % cutoff unfixed -> searched
    %   p = p.add('lowpass', 'cutoff', 30);           % fixed
    %   p = p.add('badchannels', 'threshold', {3 5}); % searched over 3 and 5
    %   p = p.add('reref', 'mode', 'average');        % defines the measure
    %   p = p.add('ica');  p = p.add('icremove');
    %   p = p.add('epoch'); p = p.add('baseline');
    %   p = p.add('reject_threshold', 'uv', {75 100 150});
    %   p = p.addNative('EEG = pop_eegfiltnew(EEG, ''locutoff'',48,''hicutoff'',52,''revfilt'',1);');
    %   p = p.addChoice('reject', {'reject_threshold','uv',100}, {'reject_jointprob'}, 'none');
    %
    %   Rules
    %   - The order you add steps is the order they run (OrderMode 'fixed').
    %     With OrderMode 'search' every legal order is tried, except that
    %     pinned steps keep their position and before(a,b) pairs are kept.
    %   - A parameter given as a single value is fixed. A cell {a b c} is
    %     searched. A parameter you do not mention is searched over the
    %     catalog's suggestions when it has any, otherwise it takes the
    %     catalog default. (For list-valued parameters such as 'classes' a
    %     cell of cells is searched.)
    %   - Parameters that define the measured quantity (the reference) can
    %     be searched, but candidates that differ in them are ranked in
    %     separate strata, never against each other. Epoch and baseline
    %     windows come from the analysis contract.
    %   - Everything already done to the dataset (EEG.history + data
    %     state) is the starting point; the plan only covers what follows.

    properties
        Slots = struct('id', {}, 'alternatives', {}, 'pinned', {})
        OrderMode = 'fixed'          % 'fixed' | 'search'
        Precedence = cell(0, 2)      % {before, after} slot ids
    end

    methods
        function obj = add(obj, type, varargin)
            type = char(type);
            neuroqc.plan.Catalog.get(type); % validates the type
            params = nvStruct(varargin);
            obj = obj.addSlot(type, {struct('type', type, 'params', params)});
        end

        function obj = addNative(obj, command, id)
            if nargin < 3, id = 'native'; end
            obj = obj.addSlot(id, {neuroqc.plan.Plan.nativeAlt(command)});
        end

        function obj = addEeglab(obj, command, id, varargin)
            % A step configured in an EEGLAB dialog whose arguments can be
            % searched one by one:
            %   p = p.addEeglab('EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''hicutoff'',30);', 'filter', ...
            %                   'hicutoff', {20, 30, 40});
            % Every argument of the command is kept; named ones (or
            % 'arg2', 'arg3', ... for positional ones) take a search list.
            alt = neuroqc.run.Native.eeglabAlt(command);
            assert(~isempty(alt), 'NeuroQC:Native', 'Not a single EEG = pop_x(EEG, ...) command: %s', command);
            if nargin < 3 || isempty(id), id = regexprep(alt.params.fn, '^pop_', ''); end
            for k = 1:2:numel(varargin)
                i = find(strcmp({alt.params.args.name}, varargin{k}), 1);
                assert(~isempty(i), 'NeuroQC:Plan', '%s has no argument %s (has: %s)', alt.params.fn, varargin{k}, ...
                    strjoin({alt.params.args.name}, ', '));
                v = varargin{k+1}; if ~iscell(v), v = {v}; end
                alt.params.args(i).values = v(:)';
            end
            obj = obj.addSlot(id, {alt});
        end

        function obj = addAlternative(obj, id, alt)
            % One more alternative for a slot (e.g. another configuration
            % captured from an EEGLAB dialog); the search tries each.
            k = obj.slotIndex(id);
            if ischar(alt) && strcmp(alt, 'none'), alt = struct('type', 'none', 'params', struct()); end
            obj.Slots(k).alternatives{end+1} = alt;
        end

        function obj = setSkippable(obj, id, tf)
            % Whether skipping the step is one of the searched options.
            k = obj.slotIndex(id);
            isNone = cellfun(@(a) strcmp(a.type, 'none'), obj.Slots(k).alternatives);
            if tf && ~any(isNone), obj.Slots(k).alternatives{end+1} = struct('type', 'none', 'params', struct()); end
            if ~tf, obj.Slots(k).alternatives(isNone) = []; end
            assert(~isempty(obj.Slots(k).alternatives), 'NeuroQC:Plan', 'A step needs at least one alternative.');
        end

        function obj = addChoice(obj, id, varargin)
            % Alternatives for one position. Each alternative is a cell
            % {type, name, value, ...} or the char 'none' (skip the step).
            alts = {};
            for k = 1:numel(varargin)
                a = varargin{k};
                if ischar(a) && strcmp(a, 'none')
                    alts{end+1} = struct('type', 'none', 'params', struct()); %#ok<AGROW>
                else
                    assert(iscell(a) && ~isempty(a), 'NeuroQC:Plan', 'Each alternative is {type, name, value, ...} or ''none''');
                    neuroqc.plan.Catalog.get(a{1});
                    alts{end+1} = struct('type', char(a{1}), 'params', nvStruct(a(2:end))); %#ok<AGROW>
                end
            end
            obj = obj.addSlot(id, alts);
        end

        function obj = pin(obj, id)
            obj.Slots(obj.slotIndex(id)).pinned = true;
        end

        function obj = before(obj, a, b)
            obj.slotIndex(a); obj.slotIndex(b);
            obj.Precedence(end+1, :) = {a, b};
        end

        function obj = remove(obj, id)
            k = obj.slotIndex(id);
            obj.Slots(k) = [];
            keep = ~any(strcmp(obj.Precedence, id), 2);
            obj.Precedence = obj.Precedence(keep, :);
        end

        function obj = move(obj, id, delta)
            k = obj.slotIndex(id); j = k + delta;
            if j < 1 || j > numel(obj.Slots), return; end
            obj.Slots([k j]) = obj.Slots([j k]);
        end

        function obj = setParams(obj, id, varargin)
            % Replace the parameters of a single-alternative slot.
            k = obj.slotIndex(id);
            assert(numel(obj.Slots(k).alternatives) == 1, 'NeuroQC:Plan', 'setParams applies to single-step slots');
            obj.Slots(k).alternatives{1}.params = nvStruct(varargin);
        end

        function k = slotIndex(obj, id)
            k = find(strcmp({obj.Slots.id}, id), 1);
            assert(~isempty(k), 'NeuroQC:Plan', 'No step "%s" in the plan', id);
        end

        function [leaves, tree, report] = enumerate(obj, state, contract, opts)
            % Every legal pipeline the plan allows, as a prefix tree.
            %   leaves  struct array: path (cell of instances), key, order,
            %           stratum (values of measure-defining parameters)
            %   tree    node array for prefix-sharing execution
            %   report  counts, excluded combinations with reasons,
            %           searched parameters, search mode
            %
            %   opts.searchMode 'exhaustive' (default): every legal pipeline;
            %       refuses (does not truncate) above opts.maxLeaves.
            %       Orders and values are explored together depth first and
            %       an illegal prefix is cut immediately, so step orders are
            %       never listed in advance (8 free steps = 40320 orders is
            %       fine when most are illegal). opts.maxVisits bounds the
            %       work (refused, never truncated, above it).
            %   opts.searchMode 'sample': opts.sampleSize distinct legal
            %       pipelines drawn uniformly over (order, parameter values)
            %       with opts.sampleSeed (orders are drawn exactly uniformly
            %       among those the pins and before() allow, by counting
            %       them, not listing them). The result is then explicitly
            %       an approximate search and is never reported as an optimum.
            if nargin < 4, opts = struct(); end
            opts = withDefaults(opts, struct('maxLeaves', 500, 'maxVisits', 2e6, ...
                'searchMode', 'exhaustive', 'sampleSize', 100, 'sampleSeed', 1));
            assert(~isempty(obj.Slots), 'NeuroQC:Plan', 'The plan is empty: add at least one step.');
            n = numel(obj.Slots);
            obj = obj.resolveAuto(state);
            inst = cell(1, n);
            for k = 1:n
                inst{k} = obj.expandSlot(k, contract);
            end
            [nextOf, nOrders, completions] = obj.orderSpace();
            counts = cellfun(@numel, inst);
            upper = nOrders * prod(counts);
            st0 = rootState(state);
            leaves = struct('path', {}, 'key', {}, 'order', {}, 'stratum', {});
            seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            reasons = containers.Map('KeyType', 'char', 'ValueType', 'double');
            report = struct('searchMode', opts.searchMode, 'upperBound', upper);
            switch opts.searchMode
                case 'exhaustive'
                    visits = 0;
                    walk(0, [], {}, st0);
                    explainIfEmpty();
                case 'sample'
                    assert(nOrders > 0, 'NeuroQC:NoLegalPipeline', 'The pins and before() constraints allow no step order.');
                    rs = RandStream('mt19937ar', 'Seed', opts.sampleSeed);
                    attempts = 0; maxAttempts = 50 * opts.sampleSize; legal = 0;
                    while numel(leaves) < opts.sampleSize && attempts < maxAttempts
                        attempts = attempts + 1;
                        order = drawOrder(rs);
                        pick = arrayfun(@(k) randi(rs, counts(k)), 1:n);
                        if drawPath(order, pick), legal = legal + 1; end
                    end
                    explainIfEmpty();
                    report.attempts = attempts;
                    report.legalFraction = legal / attempts;
                    report.estimatedLegalPipelines = round(report.legalFraction * upper);
                    report.sampleSize = numel(leaves);
                otherwise
                    error('NeuroQC:Plan', 'searchMode must be exhaustive or sample');
            end
            tree = buildTree(leaves);
            report.nLeaves = numel(leaves);
            report.nOrders = nOrders;
            report.nNodes = numel(tree) - 1;
            report.nStepsUnshared = sum(arrayfun(@(l) numel(l.path), leaves));
            report.rejected = mapToStruct(reasons);
            report.searched = searchedParams(inst, obj.Slots);

            function walk(mask, order, path, st)
                pos = numel(order) + 1;
                if pos > n
                    addLeaf(order, path);
                    return;
                end
                for s = nextOf(mask, pos)
                    cands = inst{s};
                    for c = 1:numel(cands)
                        visits = visits + 1;
                        assert(visits <= opts.maxVisits, 'NeuroQC:SearchTooLarge', ...
                            ['More than %d partial pipelines explored (%d orders x %s values per step). Nothing ', ...
                             'was run or truncated. Fix more parameters, pin steps or add before() constraints, ', ...
                             'or use searchMode ''sample''.'], opts.maxVisits, nOrders, mat2str(counts));
                        in = cands{c};
                        if strcmp(in.type, 'none')
                            walk(bitset(mask, s), [order s], path, st);
                            continue;
                        end
                        [why, st2] = neuroqc.plan.Catalog.apply(in.type, in.params, st);
                        if ~isempty(why)
                            note(pos, in, why);
                            continue;
                        end
                        walk(bitset(mask, s), [order s], [path {in}], st2);
                    end
                end
            end

            function order = drawOrder(rs)
                % uniform over the allowed orders: each next slot with
                % probability proportional to the completions it leaves
                mask = 0; order = zeros(1, n);
                for pos = 1:n
                    nx = nextOf(mask, pos);
                    w = arrayfun(@(t) completions(bitset(mask, t)), nx);
                    t = nx(find(rand(rs) * sum(w) < cumsum(w), 1));
                    order(pos) = t; mask = bitset(mask, t);
                end
            end

            function ok = drawPath(order, pick)
                st = st0; path = {}; ok = false;
                for pos = 1:numel(order)
                    in = inst{order(pos)}{pick(order(pos))};
                    if strcmp(in.type, 'none'), continue; end
                    [why, st] = neuroqc.plan.Catalog.apply(in.type, in.params, st);
                    if ~isempty(why), note(pos, in, why); return; end
                    path{end+1} = in; %#ok<AGROW>
                end
                ok = true;
                addLeaf(order, path);
            end

            function addLeaf(order, path)
                key = strjoin(cellfun(@(i) i.key, path, 'UniformOutput', false), ' > ');
                if isempty(key), key = '(no step)'; end
                if isKey(seen, key), return; end
                seen(key) = true;
                leaves(end+1) = struct('path', {path}, 'key', key, 'order', order, 'stratum', stratumOf(path));
                if strcmp(opts.searchMode, 'exhaustive')
                    assert(numel(leaves) <= opts.maxLeaves, 'NeuroQC:SearchTooLarge', ...
                        ['More than maxLeaves = %d legal pipelines. Nothing was run or truncated. Fix more ', ...
                         'parameters/order, raise opts.maxLeaves deliberately, or use searchMode ''sample'' ', ...
                         '(approximate).'], opts.maxLeaves);
                end
            end

            function note(pos, in, why)
                if strcmp(obj.OrderMode, 'fixed')
                    r = sprintf('step %d "%s" (%s): %s', pos, obj.Slots(pos).id, in.label, why);
                else
                    r = sprintf('%s: %s', in.label, why);
                end
                if isKey(reasons, r), reasons(r) = reasons(r) + 1; else, reasons(r) = 1; end
            end

            function explainIfEmpty()
                if ~isempty(leaves), return; end
                if strcmp(obj.OrderMode, 'fixed')
                    error('NeuroQC:NoLegalPipeline', ['The steps cannot run in the order you fixed; nothing was ', ...
                        'rearranged. Conflicts: %s'], describe(reasons));
                end
                error('NeuroQC:NoLegalPipeline', 'No legal pipeline: %s', describe(reasons));
            end
        end

        function obj = resolveAuto(obj, state)
            % Values that come from the data: linenoise freq 'auto' (or
            % unset) -> the mains frequency detected in this dataset.
            lf = []; if isfield(state, 'lineFreq'), lf = state.lineFreq; end
            for k = 1:numel(obj.Slots)
                for a = 1:numel(obj.Slots(k).alternatives)
                    alt = obj.Slots(k).alternatives{a};
                    if ~strcmp(alt.type, 'linenoise'), continue; end
                    if ~isfield(alt.params, 'freq') || (ischar(alt.params.freq) && strcmpi(alt.params.freq, 'auto'))
                        if isempty(lf), alt.params.freq = 'auto';
                        else
                            alt.params.freq = lf;
                            neuroqc.utils.log('%s: line frequency %g Hz detected in the dataset.', obj.Slots(k).id, lf);
                        end
                        obj.Slots(k).alternatives{a} = alt;
                    end
                end
            end
        end

        function list = expandSlot(obj, k, contract)
            slot = obj.Slots(k);
            list = {};
            for a = 1:numel(slot.alternatives)
                alt = slot.alternatives{a};
                if strcmp(alt.type, 'none')
                    list{end+1} = struct('slot', slot.id, 'type', 'none', 'params', struct(), ...
                        'key', 'none', 'label', 'none', 'searched', {{}}, 'defining', ''); %#ok<AGROW>
                    continue;
                end
                if strcmp(alt.type, 'eeglab')
                    list = [list eeglabInstances(slot.id, alt.params)]; %#ok<AGROW>
                    continue;
                end
                [grid, searched, defining] = paramGrid(alt.type, alt.params, contract);
                if strcmp(alt.type, 'native')
                    list{end+1} = struct('slot', slot.id, 'type', 'native', 'params', grid{1}, ...
                        'key', instKey('native', grid{1}), 'label', instLabel('native', grid{1}), ...
                        'searched', {searched}, 'defining', referenceOf(grid{1}.command)); %#ok<AGROW>
                    continue;
                end
                for g = 1:numel(grid)
                    p = grid{g};
                    dtxt = '';
                    if ~isempty(defining)
                        dtxt = strjoin(cellfun(@(f) sprintf('%s.%s=%s', alt.type, f, valText(p.(f))), defining, ...
                            'UniformOutput', false), ',');
                    end
                    list{end+1} = struct('slot', slot.id, 'type', alt.type, 'params', p, ...
                        'key', instKey(alt.type, p), 'label', instLabel(alt.type, p), ...
                        'searched', {searched}, 'defining', dtxt); %#ok<AGROW>
                end
            end
        end

        function [nextOf, nOrders, completions] = orderSpace(obj)
            % The allowed step orders without listing them.
            %   nextOf(mask, pos)  slots that may come at position pos when
            %                      the slots in bitmask mask are placed
            %   completions(mask)  number of allowed ways to finish
            %   nOrders            number of allowed orders
            n = numel(obj.Slots);
            if strcmp(obj.OrderMode, 'fixed')
                nextOf = @(mask, pos) pos; nOrders = 1; completions = @(mask) 1;
                return;
            end
            assert(strcmp(obj.OrderMode, 'search'), 'NeuroQC:Plan', 'OrderMode must be fixed or search');
            assert(n <= 20, 'NeuroQC:SearchTooLarge', 'Order search over %d steps: pin steps or fix the order (at most 20 free steps).', n);
            ids = {obj.Slots.id};
            pinned = [obj.Slots.pinned];
            pred = zeros(1, n);                    % bitmask of slots that must come before each slot
            for r = 1:size(obj.Precedence, 1)
                a = find(strcmp(ids, obj.Precedence{r, 1})); b = find(strcmp(ids, obj.Precedence{r, 2}));
                pred(b) = bitset(pred(b), a);
            end
            memo = containers.Map('KeyType', 'double', 'ValueType', 'double');
            nextOf = @nextSlots;
            completions = @count;
            nOrders = count(0);
            function s = nextSlots(mask, pos)
                if pinned(pos) && ~bitget(mask, pos)
                    cand = pos;                    % a pinned slot keeps its position
                else
                    cand = find(~pinned & ~bitget(mask, 1:n));
                end
                s = cand(arrayfun(@(t) bitand(pred(t), mask) == pred(t), cand));
            end
            function c = count(mask)
                pos = sum(bitget(mask, 1:n)) + 1;
                if pos > n, c = 1; return; end
                if isKey(memo, mask), c = memo(mask); return; end
                c = 0;
                for t = nextSlots(mask, pos), c = c + count(bitset(mask, t)); end
                memo(mask) = c;
            end
        end

        function orders = orders(obj, maxOrders)
            n = numel(obj.Slots);
            if strcmp(obj.OrderMode, 'fixed')
                orders = {1:n};
                return;
            end
            assert(strcmp(obj.OrderMode, 'search'), 'NeuroQC:Plan', 'OrderMode must be fixed or search');
            ids = {obj.Slots.id};
            pinned = [obj.Slots.pinned];
            mustBefore = false(n);
            for r = 1:size(obj.Precedence, 1)
                mustBefore(strcmp(ids, obj.Precedence{r, 1}), strcmp(ids, obj.Precedence{r, 2})) = true;
            end
            orders = {};
            rec([]);
            function rec(prefix)
                pos = numel(prefix) + 1;
                if pos > n
                    assert(numel(orders) < maxOrders, 'NeuroQC:SearchTooLarge', ...
                        'More than %d step orders; pin steps or add before() constraints.', maxOrders);
                    orders{end+1} = prefix; return;
                end
                if pinned(pos) && ~ismember(pos, prefix)
                    if any(mustBefore(setdiff(1:n, [prefix pos]), pos)), return; end
                    rec([prefix pos]); return;
                end
                for s = setdiff(1:n, prefix)
                    if pinned(s), continue; end
                    if any(mustBefore(setdiff(1:n, [prefix s]), s)), continue; end
                    rec([prefix s]);
                end
            end
        end

        function print(obj)
            neuroqc.utils.log('Plan (order %s):', obj.OrderMode);
            for k = 1:numel(obj.Slots)
                s = obj.Slots(k);
                alts = cellfun(@(a) altText(a), s.alternatives, 'UniformOutput', false);
                pin = ''; if s.pinned, pin = ' [pinned]'; end
                fprintf('   %d. %-14s %s%s\n', k, s.id, strjoin(alts, ' | '), pin);
            end
            for r = 1:size(obj.Precedence, 1)
                fprintf('      constraint: %s before %s\n', obj.Precedence{r, 1}, obj.Precedence{r, 2});
            end
        end
    end

    methods (Static)
        function alt = nativeAlt(command)
            % A native alternative: one or more EEGLAB pop_* statements
            % (one per line), as returned by an EEGLAB dialog or workflow.
            command = char(command);
            st = neuroqc.run.Native.statements(command);
            assert(~isempty(st), 'NeuroQC:Native', 'Empty native command.');
            for k = 1:numel(st)
                e = neuroqc.live.History.classify(st{k});
                assert(~isempty(e.fn) && startsWith(e.fn, 'pop_'), 'NeuroQC:Native', ...
                    'Each line of a native step must be one EEGLAB pop_* command, e.g. EEG = pop_reref(EEG, []); (got: %s)', st{k});
            end
            alt = struct('type', 'native', 'params', struct('command', command));
        end
    end

    methods (Access = private)
        function obj = addSlot(obj, id, alternatives)
            base = id; k = 1;
            while any(strcmp({obj.Slots.id}, id))
                k = k + 1; id = sprintf('%s_%d', base, k);
            end
            obj.Slots(end+1) = struct('id', id, 'alternatives', {alternatives}, 'pinned', false);
        end
    end
end

% ---------------------------------------------------------------------
function s = nvStruct(c)
assert(mod(numel(c), 2) == 0, 'NeuroQC:Plan', 'Parameters must be name, value pairs');
s = struct();
for k = 1:2:numel(c)
    s.(char(c{k})) = c{k+1};
end
end

function o = withDefaults(o, d)
for f = fieldnames(d)'
    if ~isfield(o, f{1}), o.(f{1}) = d.(f{1}); end
end
end

function [grid, searched, defining] = paramGrid(type, given, contract)
d = neuroqc.plan.Catalog.get(type);
names = {d.params.name};
unknown = setdiff(fieldnames(given), names);
assert(isempty(unknown), 'NeuroQC:Plan', 'Step %s has no parameter(s): %s (known: %s)', ...
    type, strjoin(unknown, ', '), strjoin(names, ', '));
values = cell(1, numel(names));
searched = {}; defining = {};
for k = 1:numel(d.params)
    p = d.params(k);
    listValued = iscell(p.default);
    if isfield(given, p.name)
        v = given.(p.name);
        if listValued
            if iscell(v) && ~isempty(v) && all(cellfun(@iscell, v)), vals = v(:)'; else, vals = {v}; end
        elseif iscell(v)
            vals = v(:)';
            assert(~isempty(vals), 'NeuroQC:Plan', '%s.%s: empty search list', type, p.name);
        else
            vals = {v};
        end
    elseif strcmp(type, 'native')
        error('NeuroQC:Plan', 'A native step needs its command.');
    elseif ~isempty(p.suggest)
        vals = p.suggest;
    else
        vals = {p.default};
    end
    % Parameters that change the measured quantity (the reference) may be
    % searched, but candidates that differ in them are ranked separately
    % (strata) because their data-quality scores are not comparable.
    if p.defines && ~strcmp(type, 'native'), defining{end+1} = p.name; end %#ok<AGROW>
    if numel(vals) > 1, searched{end+1} = p.name; end %#ok<AGROW>
    values{k} = vals;
end
if any(strcmp(type, {'epoch','baseline'}))
    assert(~isempty(contract), 'NeuroQC:Contract', 'Step %s needs the analysis contract (epoch/baseline windows).', type);
end
% Cartesian product
grid = {struct()};
for k = 1:numel(names)
    next = {};
    for g = 1:numel(grid)
        for v = 1:numel(values{k})
            s = grid{g}; s.(names{k}) = values{k}{v};
            next{end+1} = s; %#ok<AGROW>
        end
    end
    grid = next;
end
if isempty(names), grid = {struct()}; end
end

function list = eeglabInstances(slotId, P)
% One native instance per combination of the searched argument values.
% The instance runs the full EEGLAB command; the argument values are kept
% in its params for labels and for the per-parameter summary.
args = P.args;
searched = {args(cellfun(@numel, {args.values}) > 1).name};
idx = {[]};
for i = 1:numel(args)
    next = {};
    for g = 1:numel(idx)
        for v = 1:numel(args(i).values), next{end+1} = [idx{g} v]; end %#ok<AGROW>
    end
    idx = next;
end
list = cell(1, numel(idx));
for g = 1:numel(idx)
    vals = arrayfun(@(i) args(i).values{idx{g}(i)}, 1:numel(args), 'UniformOutput', false);
    com = neuroqc.run.Native.eeglabCommand(P.fn, args, vals);
    p = struct('command', com);
    shown = {};
    for i = 1:numel(args)
        if any(strcmp(args(i).name, searched))
            p.(matlab.lang.makeValidName(args(i).name)) = vals{i};
            shown{end+1} = sprintf('%s=%s', args(i).name, valText(vals{i})); %#ok<AGROW>
        end
    end
    if isempty(shown), key = sprintf('%s: %s', P.fn, com); else, key = sprintf('%s(%s)', P.fn, strjoin(shown, ',')); end
    list{g} = struct('slot', slotId, 'type', 'native', 'params', p, 'key', key, 'label', key, ...
        'searched', {cellfun(@matlab.lang.makeValidName, searched, 'UniformOutput', false)}, 'defining', referenceOf(com));
end
end

function d = referenceOf(command)
% A native pop_reref defines what is measured, like the reref step: its
% reference (and excluded channels) puts the candidate in a stratum.
d = '';
for stmt = neuroqc.run.Native.statements(command)
    e = neuroqc.live.History.classify(stmt{1});
    if strcmp(e.step, 'reref')
        a = neuroqc.run.Native.argsOf(stmt{1}, 'pop_reref');
        d = sprintf('pop_reref=%s', valText(a));
    end
end
end

function s = stratumOf(path)
parts = {};
for q = 1:numel(path)
    if isfield(path{q}, 'defining') && ~isempty(path{q}.defining), parts{end+1} = path{q}.defining; end %#ok<AGROW>
end
s = strjoin(parts, ';');
end

function k = instKey(type, p)
if isempty(fieldnames(p)), k = type; return; end
f = sort(fieldnames(p));
parts = cellfun(@(n) sprintf('%s=%s', n, valText(p.(n))), f, 'UniformOutput', false);
k = sprintf('%s(%s)', type, strjoin(parts, ','));
end

function t = instLabel(type, p)
if strcmp(type, 'native')
    t = ['native: ' strjoin(neuroqc.run.Native.statements(p.command), ' / ')];
    if numel(t) > 70, t = [t(1:67) '...']; end
    return;
end
t = instKey(type, p);
end

function t = valText(v)
if ischar(v) || isstring(v), t = char(v);
elseif isnumeric(v) || islogical(v), t = mat2str(v);
elseif iscell(v), t = ['{' strjoin(cellfun(@valText, v, 'UniformOutput', false), ';') '}'];
else, t = class(v);
end
end

function t = altText(a)
if strcmp(a.type, 'none'), t = 'none'; return; end
if strcmp(a.type, 'eeglab')
    parts = arrayfun(@(x) sprintf('%s=%s', x.name, valText(x.values)), a.params.args, 'UniformOutput', false);
    parts = regexprep(parts, '=\{([^;{}]*)\}$', '=$1');   % single values without braces
    t = sprintf('%s(%s)', a.params.fn, strjoin(parts, ', '));
    return;
end
f = fieldnames(a.params);
if isempty(f), t = a.type; return; end
parts = cellfun(@(n) sprintf('%s=%s', n, valText(a.params.(n))), f, 'UniformOutput', false);
t = sprintf('%s(%s)', a.type, strjoin(parts, ', '));
end

function st = rootState(s)
steps = {s.process.step};
icaAt = find(strcmp(steps, 'ica'), 1, 'last');
pruned = ~isempty(icaAt) && any(strcmp(steps(icaAt+1:end), 'icremove'));
hp = 0; if ~isempty(s.filters.highpass), hp = max(s.filters.highpass); end
st = struct('epoched', s.isEpoched, 'srate', s.srate, 'hasICA', s.ica.present, ...
    'icRemoved', s.ica.present && pruned, 'removed', isfield(s, 'restorableChannels') && ~isempty(s.restorableChannels), ...
    'highpass', hp);   % removed: channels removed before NeuroQC can be restored by the plan
end

function nodes = buildTree(leaves)
nodes = struct('parent', 0, 'inst', [], 'key', '', 'children', [], 'leaves', [], 'depth', 0);
for li = 1:numel(leaves)
    cur = 1;
    path = leaves(li).path;
    for d = 1:numel(path)
        key = path{d}.key;
        kids = nodes(cur).children;
        hit = 0;
        for c = kids
            if strcmp(nodes(c).key, key), hit = c; break; end
        end
        if hit == 0
            nodes(end+1) = struct('parent', cur, 'inst', path{d}, 'key', key, ...
                'children', [], 'leaves', [], 'depth', d); %#ok<AGROW>
            hit = numel(nodes);
            nodes(cur).children(end+1) = hit;
        end
        cur = hit;
    end
    nodes(cur).leaves(end+1) = li;
end
end

function t = describe(m)
k = keys(m);
if isempty(k), t = 'the plan produced no pipeline'; return; end
parts = cellfun(@(x) sprintf('%s (x%d)', x, m(x)), k, 'UniformOutput', false);
t = strjoin(parts, '; ');
end

function s = mapToStruct(m)
k = keys(m);
s = struct('reason', k, 'count', cellfun(@(x) m(x), k, 'UniformOutput', false));
end

function s = searchedParams(inst, slots)
s = struct('slot', {}, 'param', {});
for k = 1:numel(inst)
    names = {};
    for c = 1:numel(inst{k}), names = union(names, inst{k}{c}.searched); end
    for n = 1:numel(names), s(end+1) = struct('slot', slots(k).id, 'param', names{n}); end %#ok<AGROW>
    if numel(slots(k).alternatives) > 1
        s(end+1) = struct('slot', slots(k).id, 'param', '(alternative)'); %#ok<AGROW>
    end
end
end
