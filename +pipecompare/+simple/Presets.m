classdef Presets
    %PRESETS What the simple mode offers: measures and recipes.
    %
    %   ERP components: the time-locking, epoch, baseline, electrode sites
    %   and mean-amplitude window recommended by ERP CORE (Kappenman,
    %   Farrens, Zhang, Stewart & Luck, 2021, NeuroImage 225, 117465;
    %   Tables 1 and 2). PipeCompare scores each condition's waveform at these
    %   sites; difference waves (deviant - standard, contralateral -
    %   ipsilateral) are formed later in your own analysis.
    %
    %   Frequency bands: delta 1-4, theta 4-8, alpha 8-13, beta 13-30 Hz,
    %   the conventional clinical bands (cf. the IFCN glossary, Kane et al.,
    %   2017, Clinical Neurophysiology Practice 2, 170-185) with contiguous
    %   edges, delta from 1 Hz so that 2 s segments hold two cycles; 2 s
    %   segments.
    %
    %   Recipes: which steps are compared, each searched over the catalog's
    %   default lists (pipecompare.plan.Catalog). Steps the data or the
    %   installation cannot support are left out, each with the reason.
    %   'standard' fits ICA once: bad channels (fixed) and ICA come before
    %   the searched filters, so every filter choice shares one
    %   decomposition (fitted on a 1 Hz high-passed copy; filtering and
    %   unmixing are both linear, so their order does not change the data).
    %   ASR is compared from the panel or a script (it multiplies the
    %   search beyond the simple mode's limit).

    methods (Static)
        function names = componentNames()
            names = {'N170', 'MMN', 'N2pc', 'N400', 'P3', 'LRP', 'ERN'};
        end

        function p = component(name)
            % ERP CORE Table 1 (epoch, baseline, sites, time-locking) and
            % Table 2 (measurement window); times in s.
            T = {
                'N170', 'stimulus', [-0.2 0.8], [-0.2 0],    {'PO8'},        [0.110 0.150], 'negative'
                'MMN',  'stimulus', [-0.2 0.8], [-0.2 0],    {'FCz'},        [0.125 0.225], 'negative'
                'N2pc', 'stimulus', [-0.2 0.8], [-0.2 0],    {'PO7', 'PO8'}, [0.200 0.275], 'negative'
                'N400', 'stimulus', [-0.2 0.8], [-0.2 0],    {'CPz'},        [0.300 0.500], 'negative'
                'P3',   'stimulus', [-0.2 0.8], [-0.2 0],    {'Pz'},         [0.300 0.600], 'positive'
                'LRP',  'response', [-0.8 0.2], [-0.8 -0.6], {'C3', 'C4'},   [-0.100 0],    'negative'
                'ERN',  'response', [-0.6 0.4], [-0.4 -0.2], {'FCz'},        [0 0.100],     'negative'};
            k = find(strcmpi(T(:, 1), name), 1);
            assert(~isempty(k), 'PipeCompare:Simple', 'Unknown component %s (known: %s).', name, ...
                strjoin(T(:, 1)', ', '));
            p = struct('name', T{k, 1}, 'lockedTo', T{k, 2}, 'epoch', T{k, 3}, 'baseline', T{k, 4}, ...
                'sites', {T{k, 5}}, 'window', T{k, 6}, 'polarity', T{k, 7});
        end

        function names = bandNames()
            names = {'delta', 'theta', 'alpha', 'beta'};
        end

        function f = band(name)
            B = struct('delta', [1 4], 'theta', [4 8], 'alpha', [8 13], 'beta', [13 30]);
            assert(isfield(B, lower(name)), 'PipeCompare:Simple', 'Unknown band %s (known: delta, theta, alpha, beta).', name);
            f = B.(lower(name));
        end

        function names = recipeNames()
            names = {'filters', 'standard'};
        end

        function t = recipeLabel(name)
            switch name
                case 'filters', t = 'Filters only (high-pass, low-pass)';
                case 'standard', t = 'Standard (filters, ICLabel threshold, epoch rejection; one ICA)';
                otherwise, error('PipeCompare:Simple', 'Unknown recipe %s (filters, standard).', name);
            end
        end

        function tf = isBand(measure)
            % true for a frequency band (a preset name, or 'band': your own)
            tf = any(strcmpi(measure, [pipecompare.simple.Presets.bandNames() {'band'}]));
        end

        function c = contract(EEG, measure, events, segment, pool, custom)
            % The analysis contract of a simple-mode choice. measure: an ERP
            % component, a band name, 'custom' (your own ERP window) or
            % 'band' (your own band); events: the event types (ERP: one
            % condition per type, or one condition for all when pool is
            % true) - ignored for a band. custom: struct with window ([t1
            % t2] s, 'custom'), band ([f1 f2] Hz, 'band') and channels
            % (labels; for 'band' all EEG channels when empty).
            if nargin < 4 || isempty(segment), segment = 2; end
            if nargin < 5, pool = false; end
            if nargin < 6, custom = struct('window', [], 'band', [], 'channels', {{}}); end
            P = pipecompare.simple.Presets;
            labels = {EEG.chanlocs.labels};
            if P.isBand(measure)
                if strcmpi(measure, 'band')
                    f = double(custom.band(:)');
                    assert(numel(f) == 2 && f(1) > 0 && f(2) > f(1), 'PipeCompare:Simple', ...
                        'Your own band needs two frequencies in Hz, low then high (e.g. 8 12).');
                    assert(f(2) < EEG.srate / 2, 'PipeCompare:Simple', ...
                        'The band must end below half the sampling rate (%g Hz).', EEG.srate / 2);
                    name = 'band';
                    roi = P.channels(labels, custom.channels);
                    if isempty(roi), roi = P.eegChannels(EEG); end
                    segment = max(segment, ceil(2 / f(1)));   % two cycles of the lowest frequency
                else
                    f = P.band(measure); name = lower(measure);
                    roi = P.eegChannels(EEG);
                end
                c = pipecompare.eval.Contract('analysis', 'bandpower', 'segment', segment, 'bands', {name, f, roi});
                return;
            end
            if strcmpi(measure, 'custom')
                w = double(custom.window(:)');
                assert(numel(w) == 2 && w(1) >= 0 && w(2) > w(1), 'PipeCompare:Simple', ['Your own window needs two ', ...
                    'times after the event, start then end (e.g. 300 600 ms); windows before the event: Advanced...']);
                roi = P.channels(labels, custom.channels);
                assert(~isempty(roi), 'PipeCompare:Simple', 'Choose the electrodes of your own window.');
                p = struct('name', 'ERP', 'lockedTo', 'stimulus', 'epoch', [-0.2 max(0.8, w(2) + 0.2)], ...
                    'baseline', [-0.2 0], 'sites', {roi}, 'window', w, 'polarity', 'positive');
            else
                p = P.component(measure);
            end
            events = cellstr(events);
            assert(~isempty(events), 'PipeCompare:Simple', 'Choose the %s-locked event type(s) for %s.', p.lockedTo, p.name);
            [ok, at] = ismember(lower(p.sites), lower(labels));
            assert(all(ok), 'PipeCompare:Simple', ['%s is measured at %s (ERP CORE); the dataset has no %s. ', ...
                'Choose "your own window and electrodes" instead.'], p.name, strjoin(p.sites, '/'), strjoin(p.sites(~ok), ', '));
            conds = [events(:) cellfun(@(e) {e}, events(:), 'UniformOutput', false)];
            if pool, conds = {strjoin(events, '+'), events(:)'}; end
            c = pipecompare.eval.Contract('conditions', conds, 'epoch', p.epoch, 'baseline', p.baseline, ...
                'components', {p.name, p.window, labels(at), {'mean', p.polarity}});
        end

        function roi = channels(labels, chosen)
            % the chosen electrodes as the dataset spells them
            roi = {};
            if isempty(chosen), return; end
            chosen = cellstr(chosen);
            [ok, at] = ismember(lower(chosen), lower(labels));
            assert(all(ok), 'PipeCompare:Simple', 'The dataset has no channel %s.', strjoin(chosen(~ok), ', '));
            roi = labels(at);
        end

        function roi = eegChannels(EEG)
            % all channels except those typed as non-EEG (EOG, ECG, EMG, ...)
            labels = {EEG.chanlocs.labels};
            roi = labels;
            if isfield(EEG.chanlocs, 'type')
                ty = arrayfun(@(c) upper(strtrim(char(string(c.type)))), EEG.chanlocs, 'UniformOutput', false);
                keep = ~ismember(ty, {'EOG', 'HEOG', 'VEOG', 'ECG', 'EKG', 'EMG', 'MISC', 'TRIG', 'STIM'});
                if any(keep), roi = labels(keep); end
            end
        end

        function [plan, notes] = recipe(name, state, contract)
            % The plan of a recipe for these data, and why a step was left out.
            pipecompare.simple.Presets.recipeLabel(name);           % validates the name
            notes = {};
            plan = pipecompare.plan.Plan();
            continuous = ~state.isEpoched;
            standard = strcmp(name, 'standard');
            ica = false;
            if standard
                if state.nLocated == 0
                    notes{end+1} = 'no channel locations: bad-channel interpolation and ICLabel are left out';
                else
                    % the catalog defaults, fixed: a searched step before
                    % ICA would multiply the decompositions
                    plan = plan.add('badchannels', 'measure', 'kurt', 'threshold', 5);
                    if exist('pop_iclabel', 'file') ~= 2
                        notes{end+1} = 'ICLabel is not installed: ICA and IC removal left out';
                    else
                        plan = plan.add('ica'); ica = true;
                    end
                end
            end
            if continuous
                % filter edges the data already have are not alternatives:
                % they leave the data unchanged but filter the known
                % signal, which would bias the comparison
                [plan, notes] = addFilter(plan, notes, 'highpass', state.filters.highpass, @(v, done) v > done, @max);
                [plan, notes] = addFilter(plan, notes, 'lowpass', state.filters.lowpass, @(v, done) v < done, @min);
            else
                notes{end+1} = 'the data are already epoched, so filters are not compared (they must run before epoching)';
            end
            if ica, plan = plan.add('icremove'); end
            if continuous, plan = plan.add('epoch'); end
            if ~isempty(contract.baseline), plan = plan.add('baseline'); end
            if standard, plan = plan.add('reject_threshold'); end
        end
    end
end

function [plan, notes] = addFilter(plan, notes, type, earlier, keep, edge)
% Add a filter step searched over the catalog's values that still change
% the data, given the edges in the dataset's history.
d = pipecompare.plan.Catalog.get(type);
vals = [d.params.suggest{:}];
if ~isempty(earlier)
    done = edge(earlier); drop = vals(~keep(vals, done)); vals = vals(keep(vals, done));
    if ~isempty(drop)
        name = strrep(type, 'pass', '-pass');
        notes{end+1} = sprintf('%s %s Hz (the data are already %s-filtered at %g Hz)', name, ...
            strjoin(arrayfun(@(v) sprintf('%g', v), drop, 'UniformOutput', false), ', '), name, done);
    end
end
if ~isempty(vals), plan = plan.add(type, 'cutoff', num2cell(vals)); end
end
