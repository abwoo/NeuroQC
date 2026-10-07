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
    %   Steps: which steps are compared (stepNames: bad channels, ICA,
    %   high-pass, low-pass, epoch rejection; any of them, always run in
    %   that order, with epoching and baseline in every pipeline), each
    %   searched over the catalog's default lists (pipecompare.plan.Catalog).
    %   The recipes are two sets of them: 'standard' all, 'filters' the
    %   two filters. Steps the data or the installation cannot support are
    %   left out, each with the reason.
    %   'standard' fits ICA once: bad channels (fixed) and ICA come before
    %   the searched filters, so every filter choice shares one
    %   decomposition (fitted on a 1 Hz high-passed copy; filtering and
    %   unmixing are both linear, so their order does not change the data).
    %   ASR is compared from the panel or a script (it multiplies the
    %   search beyond the simple mode's limit). For band power, 'standard'
    %   uses one high-pass and one low-pass edge, the catalog values
    %   nearest the band outside it: outside the band a filter does not
    %   change its power (only what epoch rejection sees), and 9 pipelines
    %   are compared instead of 108 (so for any steps with ICA or epoch
    %   rejection); 'filters' compares the filters.
    %
    %   Reference: kept as recorded, or the average reference as a fixed
    %   step in every pipeline, after the bad channels are interpolated (a
    %   bad channel would otherwise spread into every channel) and before
    %   ICA, in either recipe. Data already average-referenced are averaged
    %   again after the interpolation. EEG channels removed before
    %   PipeCompare are interpolated back before the average (when they
    %   have locations). It is not searched: the reference
    %   changes the measured quantity, so it is chosen for the analysis,
    %   not by noise.
    %
    %   Filters the data already have: a stricter edge is compared with
    %   keeping the data's own filter (no further filter).

    properties (Constant)
        EpochInterpMax = 3   % epochinterp: at most this many channels interpolated in an epoch (else it is rejected)
        IcaMinBrain = 2      % ICA check: fewer components with Brain >= 0.5 than this = almost nothing recognised
        IcaMaxOther = 0.8    % ICA check: a median Other probability above this = almost nothing recognised
    end

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

        function names = stepNames()
            % the steps the simple mode can compare, in the order they run
            % (epoch and baseline are always done; the reference is a
            % separate choice, after the bad channels and before ICA);
            % epochinterp is an option of the epoch rejection: within an
            % epoch, up to 3 channels over its limit are interpolated and
            % the epoch kept
            names = {'badchannels', 'ica', 'highpass', 'lowpass', 'reject', 'epochinterp'};
        end

        function t = stepLabel(name)
            switch name
                case 'badchannels', t = 'Bad channels: detect and interpolate';
                case 'ica', t = 'ICA: remove artifact components (ICLabel thresholds compared)';
                case 'highpass', t = 'High-pass filter (cutoffs compared)';
                case 'lowpass', t = 'Low-pass filter (cutoffs compared)';
                case 'reject', t = 'Reject epochs over an amplitude limit (limits compared)';
                case 'epochinterp', t = sprintf('  instead, repair epochs with up to %d channels over the limit', ...
                        pipecompare.simple.Presets.EpochInterpMax);
                otherwise, error('PipeCompare:Simple', 'Unknown step %s (steps: %s).', name, ...
                        strjoin(pipecompare.simple.Presets.stepNames(), ', '));
            end
        end

        function steps = recipeSteps(name)
            % The steps of a recipe, or the steps given (validated, in the
            % order they run).
            P = pipecompare.simple.Presets;
            if iscell(name) || isstring(name)
                steps = cellstr(name);
                bad = setdiff(steps, P.stepNames());
                assert(isempty(bad), 'PipeCompare:Simple', 'Unknown step %s (steps: %s).', strjoin(bad, ', '), ...
                    strjoin(P.stepNames(), ', '));
                steps = P.stepNames(); steps = steps(ismember(steps, cellstr(name)));
                return;
            end
            switch name
                case 'standard', steps = {'badchannels', 'ica', 'highpass', 'lowpass', 'reject'};
                case 'filters', steps = {'highpass', 'lowpass'};
                otherwise, error('PipeCompare:Simple', 'Unknown recipe %s (filters, standard).', name);
            end
        end

        function name = recipeOf(steps)
            % the recipe these steps make up ('' when none does)
            name = '';
            P = pipecompare.simple.Presets;
            steps = P.recipeSteps(cellstr(steps));
            for r = P.recipeNames()
                if isequal(P.recipeSteps(r{1}), steps), name = r{1}; return; end
            end
        end

        function [why, info] = stepAvailability(state)
            % For each step (pipecompare.simple.Presets.stepNames), why it
            % cannot be compared on these data ('' when it can), and what
            % to know about it (e.g. a filter the data already have).
            why = struct('badchannels', '', 'ica', '', 'highpass', '', 'lowpass', '', 'reject', '', 'epochinterp', '');
            info = why;
            info.epochinterp = 'interpolated from the other channels, in that epoch only';
            steps = {state.process.step};
            if state.nLocated == 0
                why.badchannels = 'needs channel locations (Edit > Channel locations)';
                why.ica = 'ICLabel needs channel locations (Edit > Channel locations)';
                why.epochinterp = why.badchannels;
            elseif exist('pop_iclabel', 'file') ~= 2
                why.ica = 'ICLabel is not installed';
            end
            icaAt = find(strcmp(steps, 'ica'), 1, 'last');
            if ~isempty(icaAt) && any(strcmp(steps(icaAt+1:end), 'icremove'))
                why.ica = 'already done to these data (ICA components removed)';
            elseif state.ica.present && isempty(why.ica)
                info.ica = 'the ICA in the data is fitted again';
            end
            if any(ismember(steps, {'badchannels', 'interpolate'})) && isempty(why.badchannels)
                info.badchannels = 'already done to these data; detected again';
            end
            if state.isEpoched
                why.highpass = 'the data are already epoched (filters run before epoching)';
                why.lowpass = why.highpass;
            else
                if ~isempty(state.filters.highpass)
                    info.highpass = sprintf('the data are already high-passed at %g Hz: stricter cutoffs and keeping it are compared', ...
                        max(state.filters.highpass));
                end
                if ~isempty(state.filters.lowpass)
                    info.lowpass = sprintf('the data are already low-passed at %g Hz: stricter cutoffs and keeping it are compared', ...
                        min(state.filters.lowpass));
                end
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
            % (labels; for 'band' all EEG channels when empty). channels
            % also replace the electrodes of a preset: an ERP component's
            % ERP CORE site(s) (not N2pc and LRP, scored on their pair) or
            % a band's all EEG channels; several are averaged.
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
                    roi = P.channels(labels, custom.channels);
                    if isempty(roi), roi = P.eegChannels(EEG); end
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
                if ~isempty(custom.channels)
                    assert(isempty(p.contra), 'PipeCompare:Simple', ['%s is scored on the pair %s (contralateral minus ', ...
                        'ipsilateral); its electrodes cannot be changed here (Advanced... can).'], p.name, strjoin(p.sites, '/'));
                    p.sites = P.channels(labels, custom.channels);   % your electrodes instead of ERP CORE's
                end
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
            % non-EEG channels (EOG, ECG, ...) and ear/mastoid reference
            % sites (A1, A2, M1, M2): not tested for bad channels or epoch
            % rejection, and left out of an average reference
            labels = setdiff({EEG.chanlocs.labels}, pipecompare.simple.Presets.eegChannels(EEG), 'stable');
        end

        function roi = eegChannels(EEG)
            % all channels except non-EEG ones (EOG, ECG, EMG, ...)
            labels = {EEG.chanlocs.labels};
            roi = labels;
            keep = ~pipecompare.simple.Presets.isNonEeg(EEG.chanlocs);
            if any(keep), roi = labels(keep); end
        end

        function tf = isNonEeg(chanlocs)
            % non-EEG channels (EOG, ECG, EMG, ...), by type or, when the
            % type is not set, by name (VEOG, HEOG, ECG1, EYEL; with the
            % POL prefix of some EDF exports: POL EYEL); and ear/mastoid
            % reference sites (isRefSite)
            labels = {chanlocs.labels};
            tf = ~cellfun(@isempty, regexpi(labels, '^(POL\s+)?([VH]?EOG|ECG|EKG|EMG|EYE)', 'once'));
            if isfield(chanlocs, 'type')
                ty = arrayfun(@(c) upper(strtrim(char(string(c.type)))), chanlocs(:)', 'UniformOutput', false);
                tf = tf | ismember(ty, {'EOG', 'HEOG', 'VEOG', 'ECG', 'EKG', 'EMG', 'MISC', 'TRIG', 'STIM'});
            end
            tf = tf | pipecompare.simple.Presets.isRefSite(chanlocs);
        end

        function tf = isRefSite(chanlocs)
            % Ear and mastoid electrodes (10-20 names A1, A2 for the
            % earlobes, M1, M2 for the mastoids; optional POL prefix of
            % EDF exports; any case), or channels typed REF. They are
            % reference sites, not scalp: the scalp cannot predict them
            % (no interpolation), and a linked-ears reference leaves them
            % flat or mirrored, which a bad-channel test would flag.
            % Not when numbered caps use the letter for scalp channels
            % (BioSemi A1-A32: there is an A3, ...), and not a channel
            % typed EEG while other channels have other types (to keep A1,
            % A2 as scalp channels, set their type to EEG in Edit > Channel
            % locations); a type EEG on every channel is an importer's
            % default, not a choice.
            labels = cellfun(@(l) strtrim(char(string(l))), {chanlocs.labels}, 'UniformOutput', false);
            tok = regexpi(labels, '^(?:POL\s+)?([AM])(\d+)$', 'tokens', 'once');
            num = ~cellfun(@isempty, tok);
            letter = repmat({''}, size(labels)); n = zeros(size(labels));
            letter(num) = cellfun(@(t) upper(t{1}), tok(num), 'UniformOutput', false);
            n(num) = cellfun(@(t) str2double(t{2}), tok(num));
            numbered = unique(letter(num & n > 2));   % A3, M3, ...: a numbered cap
            tf = num & ismember(n, [1 2]) & ~ismember(letter, numbered);
            if isfield(chanlocs, 'type')
                ty = arrayfun(@(c) upper(strtrim(char(string(c.type)))), chanlocs(:)', 'UniformOutput', false);
                eeg = strcmp(ty, 'EEG');
                if ~all(eeg), tf = tf & ~eeg; end
                tf = tf | strcmp(ty, 'REF');
            end
        end

        function lines = dataAdvice(state)
            % What to know about the data before comparing, in words: where
            % PipeCompare starts (the raw continuous data), the steps done
            % before it (not compared), an ICA in the data that Standard
            % fits again, and the inconsistencies found between the data
            % and their history.
            lines = {};
            steps = {state.process.step};
            words = {'highpass', 'filtered'; 'lowpass', 'filtered'; 'bandpass', 'filtered'; 'filter_other', 'filtered';
                'clean_rawdata', 'cleaned with clean_rawdata'; 'badchannels', 'bad channels handled';
                'interpolate', 'bad channels handled'; 'reref', 're-referenced'; 'ica', 'ICA';
                'icremove', 'ICA components removed'; 'epoch', 'epoched'};
            done = unique(words(ismember(words(:, 1), steps), 2), 'stable');
            if state.isEpoched && ~ismember('epoched', done), done{end+1} = 'epoched'; end
            if isempty(done)
                lines{end+1} = ['Start from the raw continuous data (channel locations added): each pipeline ', ...
                    'filters, references, runs ICA and epochs it.'];
            else
                lines{end+1} = sprintf(['Already done to these data: %s. Those steps are not compared; to compare ', ...
                    'them, start from the raw continuous data (channel locations added).'], strjoin(done, ', '));
            end
            icaAt = find(strcmp(steps, 'ica'), 1, 'last');
            removed = ~isempty(icaAt) && any(strcmp(steps(icaAt+1:end), 'icremove'));
            if state.ica.present && ~removed
                t = 'Standard fits ICA again (after the bad channels), so the ICA in these data is not used';
                if ~isempty(state.ica.flagged)
                    t = sprintf('%s, nor the %d component(s) marked in it', t, numel(state.ica.flagged));
                end
                if isempty(icaAt)
                    t = [t '. The history does not show where it came from: if components were already ', ...
                        'removed, choose Filters only'];
                end
                lines{end+1} = [t '.'];
            end
            ear = pipecompare.utils.fieldOr(state, 'refSites', {});
            if ~isempty(ear)
                lines{end+1} = sprintf(['Ear/mastoid channels left out: %s. They stay in the data but are not ', ...
                    'tested as bad channels, interpolated, counted in epoch rejection or part of an average ', ...
                    'reference (to treat them as scalp channels, set their type to EEG).'], strjoin(ear, ', '));
            end
            % PipeCompare handles these itself on its copy
            w = state.warnings(~contains(state.warnings, {'urevent', 'EEG.srate'}));
            lines = [lines w(:)'];
        end

        function t = nextStep(result, how)
            % What to try when no pipeline passed because most lost too many
            % epochs to rejection: the channels that were most often over the
            % limit (likely bad channels the detection missed), and the
            % average reference when the data keep a recorded reference
            % ('' when neither applies). how: how to choose the average
            % reference (default: in the dialog or pop_pipecompare).
            if nargin < 2, how = 'Reference: average reference; pop_pipecompare(..., ''reference'', ''average'')'; end
            t = '';
            why = [result.ranking.whyList{:}];
            if ~isempty(result.ranking.byStratum) || isempty(why) || mean(startsWith(why, 'retention')) < 0.5, return; end
            if isfield(result, 'cands') && isfield(result.cands, 'overLimit')
                labels = {}; counts = [];
                for c = result.cands(:)'
                    labels = [labels; c.overLimit.labels(:)]; counts = [counts; c.overLimit.counts(:)]; %#ok<AGROW>
                end
                if ~isempty(counts)
                    [labels, ~, j] = unique(labels);
                    share = accumarray(j(:), counts)' / sum(counts);
                    [share, order] = sort(share, 'descend');
                    top = order(share >= 0.1); top = top(1:min(5, numel(top)));
                    if ~isempty(top)
                        t = sprintf(['The channels most often over the rejection limit were %s (share of all ', ...
                            'over-limit marks). If they are bad channels, remove them (Edit > Select data) or ', ...
                            'interpolate them (Tools > Interpolate electrodes) and run again.'], ...
                            strjoin(arrayfun(@(k, f) sprintf('%s (%.0f%%)', labels{k}, 100 * f), top, share(1:numel(top)), ...
                            'UniformOutput', false), ', '));
                    end
                end
            end
            reref = any(cellfun(@(e) strcmp(e.type, 'reref'), result.leaves(1).path));
            if reref || any(strcmpi(result.state.reference, {'average', 'averef'})), return; end   % (pop_averef writes averef)
            t = strtrim([t ' Most pipelines lost too many epochs to the rejection thresholds, and the data keep their ', ...
                'recorded reference, which often makes amplitudes large. Try the average reference (', how, ').']);
        end

        function lines = stepsText(result, k)
            % What pipeline k did, step by step in order, in words: each
            % step's settings and its decisions on these data (channels
            % interpolated, components and epochs removed), then the trials
            % kept per condition. A summary of the pipeline's EEG.history
            % (the history itself is unchanged). {} when the pipeline did
            % not run to the end.
            lines = {};
            if isempty(k) || k > numel(result.cands) || ~isfield(result.cands(k), 'steps'), return; end
            c = result.cands(k); con = result.contract;
            for q = 1:numel(c.steps)
                f = c.steps{q}; p = f.params;
                switch f.type
                    case 'highpass', t = sprintf('High-pass filter %g Hz', p.cutoff);
                    case 'lowpass', t = sprintf('Low-pass filter %g Hz', p.cutoff);
                    case 'badchannels'
                        how = strrep(strrep(strrep(p.measure, 'kurt', 'kurtosis'), 'prob', 'joint probability'), '+', ' or ');
                        t = sprintf('Bad channels (%s over %g SD', how, p.threshold);
                        if pipecompare.utils.fieldOr(p, 'detectHighpass', 0) > 0
                            t = sprintf('%s, found on a %g Hz high-passed copy', t, p.detectHighpass);
                        end
                        t = [t '): ' listText(pipecompare.utils.ternary(isempty(f.removed), f.interpolated, f.removed), ...
                            pipecompare.utils.ternary(isempty(f.removed), 'interpolated', 'removed'), 'none found')];
                        t = [t notTested(p)];
                    case 'channels'
                        t = sprintf('Named channels %s: %s', pipecompare.utils.ternary(strcmp(p.action, 'remove'), ...
                            'removed', 'interpolated'), strjoin(cellstr(p.labels), ', '));
                    case 'restore'   % (labels in lower case: in the data's spelling)
                        pool = [pipecompare.utils.fieldOr(pipecompare.utils.fieldOr(result, 'state', struct()), 'removedChannels', {}), ...
                            pipecompare.utils.fieldOr(pipecompare.utils.fieldOr(result, 'state', struct()), 'labels', {})];
                        [ok, at] = ismember(f.interpolated, lower(pool));
                        names = f.interpolated; names(ok) = pool(at(ok));
                        t = ['Channels removed before PipeCompare: ' listText(names, 'interpolated back', 'none')];
                    case 'reref'
                        again = any(cellfun(@(e) strcmp(e.type, 'reref'), c.steps(1:q-1)));
                        if strcmp(p.mode, 'average') && again, t = 'Average reference again (after the epochs repaired by interpolation)';
                        elseif strcmp(p.mode, 'average'), t = 'Average reference';
                        else, t = ['Re-referenced to ' strjoin(cellstr(p.channels), ', ')]; end
                        if isfield(p, 'exclude') && ~isempty(p.exclude)
                            t = sprintf('%s (left out: %s)', t, strjoin(cellstr(p.exclude), ', '));
                        end
                    case 'ica'
                        t = 'ICA (extended runica)';
                        if pipecompare.utils.fieldOr(p, 'fitHighpass', 0) > 0
                            t = sprintf('%s, fitted on a %g Hz high-passed copy and applied to the data', t, p.fitHighpass);
                        end
                    case 'icremove'
                        t = sprintf('ICLabel: %s of %s components removed (%s with probability %g or more)', ...
                            numText(f.icsRemoved), numText(f.icsTotal), strjoin(cellstr(p.classes), ', '), p.threshold);
                        b = pipecompare.utils.fieldOr(f, 'icsBrain', NaN); o = pipecompare.utils.fieldOr(f, 'icsOther', NaN);
                        if isfinite(b) && isfinite(o)
                            t = sprintf('%s; %d look like brain activity, %d were labelled Other', t, b, o);
                        end
                    case 'epoch'
                        if con.isSegmented(), t = sprintf('Cut into %g s segments', con.segment);
                        else
                            t = sprintf('Epochs %g to %g ms around event type(s) %s', 1000 * con.epoch, ...
                                strjoin(cellfun(@(e) char(string(e)), con.allEvents(), 'UniformOutput', false), ', '));
                        end
                    case 'baseline', t = sprintf('Baseline %g to %g ms removed', 1000 * con.baseline);
                    case 'reject_threshold'
                        t = sprintf('Epochs beyond +/-%g uV on any channel rejected: %s', p.uv, ofText(f));
                        t = [t repairText(p, f) notTested(p)];
                    case {'reject_jointprob', 'reject_kurtosis'}
                        t = sprintf('Epochs rejected by %s (%g SD): %s', pipecompare.utils.ternary(strcmp(f.type, ...
                            'reject_kurtosis'), 'kurtosis', 'joint probability'), p.sd, ofText(f));
                        t = [t repairText(p, f) notTested(p)];
                    case 'asr', t = sprintf('ASR burst correction (%g SD)', p.cutoff);
                    case 'native'
                        cmd = strtrim(char(p.command));
                        if numel(cmd) > 100, cmd = [cmd(1:97) '...']; end
                        t = ['EEGLAB command: ' cmd];
                    otherwise
                        d = pipecompare.plan.Catalog.get(f.type); t = d.label;
                end
                lines{end+1} = sprintf('%d. %s', q, t); %#ok<AGROW>
            end
            if ~isempty(c.m) && isfield(c.m, 'kept') && isfield(result, 'ref') && ~isempty(result.ref)
                kept = arrayfun(@(i) sprintf('%s: %d of %d', result.ref.names{i}, c.m.kept(i), result.ref.n(i)), ...
                    1:numel(c.m.kept), 'UniformOutput', false);
                lines{end+1} = sprintf('Trials kept per condition: %s', strjoin(kept, '; '));
            end
        end

        function t = detectableText(result)
            % How large a difference this recording can show, in words,
            % from the recommended pipeline's own measurement error (SME,
            % not gain-corrected: the error the data have for a test run on
            % them). Two conditions with independent trials and standard
            % errors a and b: the difference has standard error
            % sqrt(a^2 + b^2), and a two-sided test at alpha = .05 finds a
            % true difference of (1.96 + 0.84) * that with 80% probability;
            % with several conditions, the pair with the largest error; one
            % condition, its value against 0. When the differences seen
            % here are smaller than that (a comparison in the measure's
            % own units, so it holds for uV, ms and log power alike), more
            % trials would help more than other preprocessing. '' when no
            % pipeline is recommended.
            t = '';
            z = 1.96 + 0.84;
            if isempty(result.ranking.byStratum), return; end
            recs = [result.ranking.byStratum.recommended];
            for k = recs(:)'
                m = result.cands(k).m;
                if isempty(m) || ~isfield(m, 'objectives'), continue; end
                for o = m.objectives(:)'
                    sme = o.sme; est = o.estimate; nC = numel(sme);
                    name = strtok(o.name, '.');   % P3.mean: P3; alpha.logpower: alpha
                    if nC == 1
                        d = z * sme; seen = abs(est);
                        what = sprintf('%s must differ from 0 by about %s', name, unitText(d, o.unit));
                    else
                        [i, j] = find(triu(true(nC), 1));
                        se = sqrt(sme(i) .^ 2 + sme(j) .^ 2);
                        d = z * max(se); seen = max(abs(est(i) - est(j)));
                        what = sprintf('two conditions must differ in %s by about %s', name, unitText(d, o.unit));
                    end
                    if ~isfinite(d), continue; end
                    who = ''; if numel(recs) > 1, who = sprintf('Pipeline %d: ', k); end
                    t = sprintf('%s%sWith this many trials and this noise, %s to be told apart; smaller differences need more trials.', ...
                        pipecompare.utils.ternary(isempty(t), '', [t ' ']), who, what);
                    if isfinite(seen) && seen < d
                        t = sprintf(['%s The %s seen here (%s) is smaller than that, so more trials (more events, ', ...
                            'or several recordings) would help more than other preprocessing.'], t, ...
                            pipecompare.utils.ternary(nC == 1, 'value', 'largest difference'), unitText(seen, o.unit));
                    end
                end
            end
        end

        function t = icaText(result)
            % A warning when ICA did nothing useful ('' otherwise): ICLabel
            % recognised almost none of the components (fewer than
            % IcaMinBrain with Brain >= 0.5, or a median Other probability
            % above IcaMaxOther), or no pipeline removed a component. Read
            % from the recommended pipeline when it ran ICA, else from the
            % first pipeline that did. Almost nothing recognised usually
            % means the channel labels do not match the electrode
            % positions (ICLabel reads the components' scalp maps), or too
            % little clean recording for ICA.
            t = '';
            P = pipecompare.simple.Presets;
            if ~isfield(result, 'cands') || isempty(result.cands) || ~isfield(result.cands, 'steps'), return; end
            rows = zeros(0, 5);   % pipeline, removed, total, brain, other (median Other probability below)
            med = [];
            for c = result.cands(:)'
                for q = 1:numel(c.steps)
                    f = c.steps{q};
                    if ~strcmp(f.type, 'icremove') || ~isfinite(f.icsTotal), continue; end
                    rows(end+1, :) = [c.id f.icsRemoved f.icsTotal pipecompare.utils.fieldOr(f, 'icsBrain', NaN) ...
                        pipecompare.utils.fieldOr(f, 'icsOther', NaN)]; %#ok<AGROW>
                    med(end+1) = pipecompare.utils.fieldOr(f, 'otherMedian', NaN); %#ok<AGROW>
                end
            end
            if isempty(rows), return; end
            r = [];
            if isfield(result, 'ranking') && isfield(result.ranking, 'recommended'), r = find(rows(:, 1) == result.ranking.recommended, 1); end
            if isempty(r), r = 1; end
            poor = rows(r, 4) < P.IcaMinBrain || med(r) > P.IcaMaxOther;   % (NaN: not known, not poor)
            none = all(rows(:, 2) == 0);
            if ~poor && ~none, return; end
            if poor
                t = sprintf(['ICLabel recognised almost none of the %d ICA components: %d look like brain activity ', ...
                    '(Brain 50%% or more) and %d were labelled Other'], rows(r, 3), rows(r, 4), rows(r, 5));
                if none, t = [t sprintf(', and ICA removed nothing%s', pipecompare.utils.ternary(numel(unique(rows(:, 1))) > 1, ' in any pipeline', ''))]; end
                t = [t pipecompare.utils.ternary(none, '. So the ICA step changed nothing here', ...
                    '. So ICA may have missed the artifacts it should remove') '. Check that the channel labels ', ...
                    'match the electrode positions (see the montage check of the data; ask whoever recorded it): ', ...
                    'ICLabel reads the components'' scalp maps, so a wrong montage hides eye and muscle components ', ...
                    'from it. Too little clean recording for ICA can do the same.'];
            else
                t = sprintf('ICA removed nothing%s: ICLabel found no artifact component above the threshold', ...
                    pipecompare.utils.ternary(numel(unique(rows(:, 1))) > 1, ' in any pipeline', ''));
                if isfinite(rows(r, 4)), t = sprintf('%s (%d of %d components look like brain activity)', t, rows(r, 4), rows(r, 3)); end
                t = [t '. On clean data this is expected.'];
            end
        end

        function t = priorFilterText(result)
            % A warning when the filters the data had before PipeCompare
            % (result.priorFilters, pipecompare.eval.Injection.priorFilters)
            % already change the known signal beyond the limit a pipeline
            % must meet ('' otherwise): the comparison cannot undo them.
            t = '';
            if ~isfield(result, 'priorFilters') || isempty(result.priorFilters), return; end
            p = result.priorFilters; sg = p.signal;
            lim = pipecompare.utils.withDefaults(result.options, pipecompare.eval.Rank.defaults());
            what = {};
            if sg.amplitudeError > lim.maxAmplitudeError
                what{end+1} = sprintf('change the size of the known signal by %.0f%% (a pipeline may change it by at most %.0f%%)', ...
                    100 * sg.amplitudeError, 100 * lim.maxAmplitudeError);
            end
            if ~ismember('latencyShiftMs', sg.notApplicable) && sg.latencyShiftMs > lim.maxLatencyShiftMs
                what{end+1} = sprintf('move its peak by %.0f ms (at most %g ms)', sg.latencyShiftMs, lim.maxLatencyShiftMs);
            end
            if isempty(what), return; end
            edges = {};
            if ~isempty(p.highpass), edges{end+1} = sprintf('high-pass %g Hz', p.highpass); end
            if ~isempty(p.lowpass), edges{end+1} = sprintf('low-pass %g Hz', p.lowpass); end
            t = sprintf(['The filters applied before PipeCompare (%s) already %s. The comparison cannot undo ', ...
                'that: to compare filters without it, start from the unfiltered data.'], strjoin(edges, ', '), ...
                strjoin(what, ' and '));
        end

        function [plan, notes] = recipe(name, state, contract, reference, exclude)
            % The plan of a recipe (or of the steps given, a cell of
            % pipecompare.simple.Presets.stepNames; they always run in that
            % order) for these data, and why a step was left out.
            % reference: 'asis' (default) or 'average'; exclude: the
            % non-EEG channels (e.g. EOG, ECG) and ear/mastoid sites, not
            % tested for bad channels or epoch rejection and left out of
            % the average.
            if nargin < 4 || isempty(reference), reference = 'asis'; end
            if nargin < 5, exclude = {}; end
            assert(any(strcmp(reference, {'asis', 'average'})), 'PipeCompare:Simple', ...
                'reference must be asis or average.');
            steps = pipecompare.simple.Presets.recipeSteps(name);   % validates the name or steps
            has = @(s) any(strcmp(steps, s));
            notes = {};
            plan = pipecompare.plan.Plan();
            continuous = ~state.isEpoched;
            ica = false;
            exclusion = {};
            if ~isempty(exclude), exclusion = {'exclude', cellstr(exclude)}; end
            % An average reference (chosen, or already in the data) comes
            % after the bad channels are interpolated, in either recipe: a
            % bad channel in the average spreads into every channel. Data
            % already average-referenced are averaged again after the
            % interpolation, which removes the bad channels' share.
            averaged = any(strcmpi(pipecompare.utils.fieldOr(state, 'reference', ''), {'average', 'averef'}));
            if averaged && state.nLocated > 0, reference = 'average'; end
            if (has('badchannels') || has('ica') || strcmp(reference, 'average')) && state.nLocated == 0
                what = {};
                if has('badchannels'), what{end+1} = 'bad-channel interpolation'; end
                if has('ica'), what{end+1} = 'ICA and ICLabel'; end
                if ~isempty(what), notes{end+1} = ['no channel locations: ' strjoin(what, ' and ') ' left out']; end
                if strcmp(reference, 'average')
                    notes{end+1} = ['no channel locations: bad channels cannot be interpolated before the average ', ...
                        'reference, so a bad channel spreads into every channel'];
                end
            elseif has('badchannels') || has('ica') || strcmp(reference, 'average')
                % channels removed before PipeCompare (EEG data channels with
                % a location) are interpolated back before an average: an
                % average over fewer channels is a different reference
                if strcmp(reference, 'average') && ~isempty(pipecompare.utils.fieldOr(state, 'restorableChannels', []))
                    plan = plan.add('restore');
                end
                % fixed: a searched step before ICA would multiply the
                % decompositions; kurtosis flags spiky channels, joint
                % probability noisy ones (e.g. poor contact), so either
                % marks a channel bad; on continuous data detected on a
                % 1 Hz high-passed copy (slow drifts distort both), as
                % ICA is fitted; always before an average reference
                if has('badchannels') || strcmp(reference, 'average')
                    plan = plan.add('badchannels', 'measure', 'kurt+prob', 'threshold', 5, ...
                        'detectHighpass', double(continuous), exclusion{:});
                end
                plan = addReference(plan, reference, exclude);
                if has('ica')
                    done = {state.process.step};
                    icaAt = find(strcmp(done, 'ica'), 1, 'last');
                    if ~isempty(icaAt) && any(strcmp(done(icaAt+1:end), 'icremove'))
                        notes{end+1} = 'ICA was already run and components removed (history), so they are not compared again';
                    elseif exist('pop_iclabel', 'file') ~= 2
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
                % band power with other steps compared: one edge each
                fix = strcmp(contract.analysis, 'bandpower') && (has('ica') || has('reject'));
                if has('highpass')
                    [plan, notes] = addFilter(plan, notes, 'highpass', state.filters.highpass, @(v, done) v > done, @max, ...
                        @(v) v <= lo, lo, fix);
                end
                if has('lowpass')
                    [plan, notes] = addFilter(plan, notes, 'lowpass', state.filters.lowpass, @(v, done) v < done, @min, ...
                        @(v) v >= hi, hi, fix);
                end
            elseif has('highpass') || has('lowpass')
                notes{end+1} = 'the data are already epoched, so filters are not compared (they must run before epoching)';
            end
            if ica, plan = plan.add('icremove'); end
            if continuous, plan = plan.add('epoch'); end
            if ~isempty(contract.baseline), plan = plan.add('baseline'); end
            if has('reject')
                % epochinterp: an epoch with at most EpochInterpMax channels
                % over the limit keeps them, interpolated within the epoch;
                % with an average reference the data are averaged again
                % after it (an interpolated channel's old values are still
                % in that epoch's average)
                repair = has('epochinterp') && state.nLocated > 0;
                if repair
                    plan = plan.add('reject_threshold', exclusion{:}, 'interpolate', pipecompare.simple.Presets.EpochInterpMax);
                    plan = addReference(plan, reference, exclude);
                else
                    plan = plan.add('reject_threshold', exclusion{:});
                end
            end
            if has('epochinterp') && ~has('reject')
                notes{end+1} = 'repairing epochs needs epoch rejection (it uses its limit)';
            elseif has('epochinterp') && state.nLocated == 0
                notes{end+1} = 'no channel locations: repairing epochs by interpolation left out';
            end
        end
    end
end

function t = listText(labels, done, none)
% channels and what was done to them, or none
if isempty(labels), t = none; else, t = sprintf('%s %s', strjoin(cellstr(labels), ', '), done); end
end

function t = repairText(p, f)
% the epochs a rejection step kept by interpolating channels in them
t = '';
n = pipecompare.utils.fieldOr(p, 'interpolate', 0);
if n <= 0, return; end
k = pipecompare.utils.fieldOr(f, 'epochsInterpolated', NaN);
t = sprintf('; %s kept by interpolating up to %d channel(s) within the epoch', ...
    pipecompare.utils.ternary(isfinite(k), sprintf('%d epoch(s)', k), '? epochs'), n);
end

function t = notTested(p)
% the channels a step left out
t = '';
if isfield(p, 'exclude') && ~isempty(p.exclude), t = sprintf(' (not tested: %s)', strjoin(cellstr(p.exclude), ', ')); end
end

function t = numText(v)
if isfinite(v), t = sprintf('%d', v); else, t = '?'; end
end

function t = ofText(f)
% epochs removed of those there were
if ~isfinite(f.rejected), t = '?';
elseif isfinite(f.epochsBefore), t = sprintf('%d of %d', f.rejected, f.epochsBefore);
else, t = sprintf('%d', f.rejected); end
end

function t = unitText(v, unit)
% a value with its unit: whole numbers from 10, else 2 significant digits
if abs(v) >= 10, t = sprintf('%.0f %s', v, unit); else, t = sprintf('%.2g %s', v, unit); end
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
% that stay outside the bands; with an edge in the history, also no
% further filter. fix: one value only, the edge nearest the band (band
% power, Standard).
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
        'one %s is used, %g Hz; tick only the filters to compare them)'], name, list(setdiff(vals, v)), name, v);
    vals = v;
end
if ~isempty(vals), plan = plan.add(type, 'cutoff', num2cell(vals)); end
% the data's own filter is one of the choices (no further filter)
if ~isempty(vals) && ~isempty(earlier) && ~fix, plan = plan.setSkippable(type, true); end
end
