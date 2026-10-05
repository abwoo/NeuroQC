classdef Presets
    %PRESETS What the simple mode offers: measures and recipes.
    %
    %   ERP components: the time-locking, epoch, baseline, electrode sites
    %   and mean-amplitude window recommended by ERP CORE (Kappenman,
    %   Farrens, Zhang, Stewart & Luck, 2021, NeuroImage 225, 117465;
    %   Tables 1 and 2). N2pc and LRP are scored as ERP CORE measures them,
    %   contralateral minus ipsilateral (PO7/PO8 to the target side, C3/C4
    %   to the response hand), with the event types of each side; the
    %   others score each condition's waveform at their sites. (For MMN,
    %   deviant minus standard, scoring each condition ranks the
    %   pipelines as the difference wave does: the SME of a difference of
    %   independent means is sqrt(SME1^2 + SME2^2), and the search ranks
    %   by the RMS of the conditions' SMEs.) Epoched data keep their own
    %   epochs when these hold the measurement window.
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
    %   search beyond the simple mode's limit). For band power, 'standard'
    %   uses one high-pass and one low-pass edge, the catalog values
    %   nearest the band outside it: outside the band a filter does not
    %   change its power (only what epoch rejection sees), and 9 pipelines
    %   are compared instead of 108; 'filters' compares the filters.
    %
    %   Reference: kept as recorded, or the average reference as a fixed
    %   step in every pipeline, after the bad channels are interpolated (a
    %   bad channel would otherwise spread into every channel) and before
    %   ICA. It is not searched: the reference changes the measured
    %   quantity, so it is chosen for the analysis, not by noise.

    methods (Static)
        function names = componentNames()
            names = {'N170', 'MMN', 'N2pc', 'N400', 'P3', 'LRP', 'ERN'};
        end

        function p = component(name)
            % ERP CORE Table 1 (epoch, baseline, sites, time-locking) and
            % Table 2 (measurement window); times in s. contra: the site
            % contralateral to the left and to the right side (target side,
            % response hand), for contralateral minus ipsilateral.
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
                'sites', {T{k, 5}}, 'window', T{k, 6}, 'polarity', T{k, 7}, 'contra', {{}}, 'side', '');
            switch p.name
                case 'N2pc', p.contra = {'PO8', 'PO7'}; p.side = 'target';
                case 'LRP', p.contra = {'C4', 'C3'}; p.side = 'hand';
            end
        end

        function tf = isLateral(measure)
            % scored contralateral minus ipsilateral (events of each side)
            tf = any(strcmpi(measure, {'N2pc', 'LRP'}));
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
            % true) - ignored for a band; N2pc and LRP: struct with left
            % and right, the event types of each side (target side,
            % response hand), one condition per side. custom: struct with window ([t1
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
                    'baseline', [-0.2 0], 'sites', {roi}, 'window', w, 'polarity', 'positive', 'contra', {{}}, 'side', '');
            else
                p = P.component(measure);
            end
            if EEG.trials > 1, p = fitEpochs(p, EEG); end
            [ok, at] = ismember(lower(p.sites), lower(labels));
            assert(all(ok), 'PipeCompare:Simple', ['%s is measured at %s (ERP CORE); the dataset has no %s. ', ...
                'Choose "your own window and electrodes" instead.'], p.name, strjoin(p.sites, '/'), strjoin(p.sites(~ok), ', '));
            if ~isempty(p.contra)
                c = lateralContract(p, events, labels(at)); return;
            end
            events = cellstr(events);
            assert(~isempty(events), 'PipeCompare:Simple', 'Choose the %s-locked event type(s) for %s.', p.lockedTo, p.name);
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

        function labels = nonEegChannels(EEG)
            % non-EEG channels (EOG, ECG, ...): not tested for bad channels
            % or epoch rejection, and left out of an average reference
            labels = setdiff({EEG.chanlocs.labels}, pipecompare.simple.Presets.eegChannels(EEG), 'stable');
        end

        function roi = eegChannels(EEG)
            % all channels except non-EEG ones (EOG, ECG, EMG, ...), by
            % type or, when the type is not set, by name (VEOG, HEOG, ECG1)
            labels = {EEG.chanlocs.labels};
            roi = labels;
            keep = cellfun(@isempty, regexpi(labels, '^([VH]?EOG|ECG|EKG|EMG)', 'once'));
            if isfield(EEG.chanlocs, 'type')
                ty = arrayfun(@(c) upper(strtrim(char(string(c.type)))), EEG.chanlocs, 'UniformOutput', false);
                keep = keep & ~ismember(ty, {'EOG', 'HEOG', 'VEOG', 'ECG', 'EKG', 'EMG', 'MISC', 'TRIG', 'STIM'});
            end
            if any(keep), roi = labels(keep); end
        end

        function [plan, notes] = recipe(name, state, contract, reference, exclude)
            % The plan of a recipe for these data, and why a step was left
            % out. reference: 'asis' (default) or 'average'; exclude: the
            % non-EEG channels (e.g. EOG, ECG), not tested for bad channels
            % or epoch rejection and left out of the average.
            if nargin < 4 || isempty(reference), reference = 'asis'; end
            if nargin < 5, exclude = {}; end
            assert(any(strcmp(reference, {'asis', 'average'})), 'PipeCompare:Simple', ...
                'reference must be asis or average.');
            pipecompare.simple.Presets.recipeLabel(name);           % validates the name
            notes = {};
            plan = pipecompare.plan.Plan();
            continuous = ~state.isEpoched;
            standard = strcmp(name, 'standard');
            ica = false;
            exclusion = {};
            if ~isempty(exclude), exclusion = {'exclude', cellstr(exclude)}; end
            if standard
                if state.nLocated == 0
                    notes{end+1} = 'no channel locations: bad-channel interpolation and ICLabel are left out';
                else
                    % the catalog defaults, fixed: a searched step before
                    % ICA would multiply the decompositions; on continuous
                    % data detected on a 1 Hz high-passed copy (slow drifts
                    % distort the kurtosis), as ICA is fitted
                    plan = plan.add('badchannels', 'measure', 'kurt', 'threshold', 5, ...
                        'detectHighpass', double(continuous), exclusion{:});
                    plan = addReference(plan, reference, exclude);
                    if exist('pop_iclabel', 'file') ~= 2
                        notes{end+1} = 'ICLabel is not installed: ICA and IC removal left out';
                    else
                        plan = plan.add('ica'); ica = true;
                    end
                end
            end
            if ~any(strcmp({plan.Slots.id}, 'reref')), plan = addReference(plan, reference, exclude); end
            if continuous
                % filter edges the data already have are not alternatives:
                % they leave the data unchanged but filter the known
                % signal, which would bias the comparison; for band power,
                % neither are edges inside a band (they cut what is measured)
                lo = []; hi = [];
                if strcmp(contract.analysis, 'bandpower')
                    f = vertcat(contract.bands.freq); lo = min(f(:, 1)); hi = max(f(:, 2));
                end
                fix = standard && strcmp(contract.analysis, 'bandpower');
                [plan, notes] = addFilter(plan, notes, 'highpass', state.filters.highpass, @(v, done) v > done, @max, ...
                    @(v) v <= lo, lo, fix);
                [plan, notes] = addFilter(plan, notes, 'lowpass', state.filters.lowpass, @(v, done) v < done, @min, ...
                    @(v) v >= hi, hi, fix);
            else
                notes{end+1} = 'the data are already epoched, so filters are not compared (they must run before epoching)';
            end
            if ica, plan = plan.add('icremove'); end
            if continuous, plan = plan.add('epoch'); end
            if ~isempty(contract.baseline), plan = plan.add('baseline'); end
            if standard, plan = plan.add('reject_threshold', exclusion{:}); end
        end
    end
end

function c = lateralContract(p, events, sites)
% Contralateral minus ipsilateral: one condition per side (the event
% types with the target on the left / responses of the left hand, and
% the right), each with the site contralateral to it, in the dataset's
% spelling.
assert(isstruct(events) && isfield(events, 'left') && isfield(events, 'right'), 'PipeCompare:Simple', ...
    ['%s is contralateral minus ipsilateral: give the event types of each side (%s on the left, on the right), ', ...
    'e.g. pop_pipecompare(EEG, ''measure'', ''%s'', ''left'', {...}, ''right'', {...}).'], p.name, p.side, p.name);
conds = cell(0, 2); contra = {};
sides = {'left', 'right'};
for k = 1:2
    ev = events.(sides{k});
    if isnumeric(ev), ev = arrayfun(@(x) sprintf('%g', x), ev, 'UniformOutput', false); end
    ev = cellstr(ev);
    if isempty(ev), continue; end
    conds(end+1, :) = {sprintf('%s %s', sides{k}, p.side), ev(:)'}; %#ok<AGROW>
    contra{end+1} = sites{strcmpi(p.sites, p.contra{k})}; %#ok<AGROW>
end
assert(~isempty(conds), 'PipeCompare:Simple', 'Choose the %s-locked event types of %s (left, right, or both).', ...
    p.lockedTo, p.name);
c = pipecompare.eval.Contract('conditions', conds, 'epoch', p.epoch, 'baseline', p.baseline, ...
    'components', {p.name, p.window, sites, {'mean', p.polarity}, contra});
end

function p = fitEpochs(p, EEG)
% Epoched data keep their own epochs: the preset epoch is for epoching
% continuous data, and data epoched otherwise (e.g. -100 to 600 ms) are
% fine as long as they hold the measurement window. The baseline is the
% preset's, from the epoch start when the epochs start later; a window
% edge within 1.5 samples of the epoch edge is moved onto it (pop_epoch
% leaves out the last sample: [-0.2 0.6] ends at 0.596 s at 250 Hz).
ep = [EEG.xmin EEG.xmax]; tol = 1.5 / EEG.srate; ms = @(t) sprintf('%g to %g ms', round(1000 * t));
w = p.window;
assert(w(1) >= ep(1) - tol && w(2) <= ep(2) + tol, 'PipeCompare:Simple', ...
    '%s is measured from %s, but the epochs run from %s.', p.name, ms(w), ms(ep));
p.window = [max(w(1), ep(1)) min(w(2), ep(2))];
b = [max(p.baseline(1), ep(1)) p.baseline(2)];
assert(b(2) - b(1) >= tol, 'PipeCompare:Simple', ['The %s baseline (%s) lies before the epochs (from %s); ', ...
    'epoch the data with a longer pre-event part.'], p.name, ms(p.baseline), ms(ep));
p.epoch = ep; p.baseline = b;
end

function plan = addReference(plan, reference, exclude)
if ~strcmp(reference, 'average'), return; end
args = {'mode', 'average'};
if ~isempty(exclude), args = [args {'exclude', cellstr(exclude)}]; end
plan = plan.add('reref', args{:});
end

function [plan, notes] = addFilter(plan, notes, type, earlier, keep, edge, outside, bandEdge, fix)
% Add a filter step searched over the catalog's values that still change
% the data, given the edges in the dataset's history, and (band power)
% that stay outside the bands. fix: one value only, the edge nearest the
% band (band power, Standard).
d = pipecompare.plan.Catalog.get(type);
vals = [d.params.suggest{:}];
name = strrep(type, 'pass', '-pass');
list = @(v) strjoin(arrayfun(@(x) sprintf('%g', x), v, 'UniformOutput', false), ', ');
if ~isempty(earlier)
    done = edge(earlier); drop = vals(~keep(vals, done)); vals = vals(keep(vals, done));
    if ~isempty(drop)
        notes{end+1} = sprintf('%s %s Hz (the data are already %s-filtered at %g Hz)', name, list(drop), name, done);
    end
end
if ~isempty(bandEdge)
    drop = vals(~outside(vals)); vals = vals(outside(vals));
    if ~isempty(drop)
        where = pipecompare.utils.ternary(strcmp(type, 'highpass'), 'starts', 'ends');
        notes{end+1} = sprintf('%s %s Hz (it would cut into the band, which %s at %g Hz)', name, list(drop), where, bandEdge);
    end
end
if fix && numel(vals) > 1
    v = edge(vals);
    notes{end+1} = sprintf(['%s %s Hz (band power: a filter outside the band does not change its power, so ', ...
        'one %s is used, %g Hz; "Filters only" compares them)'], name, list(setdiff(vals, v)), name, v);
    vals = v;
end
if ~isempty(vals), plan = plan.add(type, 'cutoff', num2cell(vals)); end
end
