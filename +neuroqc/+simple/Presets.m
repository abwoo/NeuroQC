classdef Presets
    %PRESETS What the simple mode offers: measures and recipes.
    %
    %   ERP components: the time-locking, epoch, baseline, electrode sites
    %   and mean-amplitude window recommended by ERP CORE (Kappenman,
    %   Farrens, Zhang, Stewart & Luck, 2021, NeuroImage 225, 117465;
    %   Tables 1 and 2). NeuroQC scores each condition's waveform at these
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
    %   default lists (neuroqc.plan.Catalog). Steps the data or the
    %   installation cannot support are left out, each with the reason.

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
            assert(~isempty(k), 'NeuroQC:Simple', 'Unknown component %s (known: %s).', name, ...
                strjoin(T(:, 1)', ', '));
            p = struct('name', T{k, 1}, 'lockedTo', T{k, 2}, 'epoch', T{k, 3}, 'baseline', T{k, 4}, ...
                'sites', {T{k, 5}}, 'window', T{k, 6}, 'polarity', T{k, 7});
        end

        function names = bandNames()
            names = {'delta', 'theta', 'alpha', 'beta'};
        end

        function f = band(name)
            B = struct('delta', [1 4], 'theta', [4 8], 'alpha', [8 13], 'beta', [13 30]);
            assert(isfield(B, lower(name)), 'NeuroQC:Simple', 'Unknown band %s (known: delta, theta, alpha, beta).', name);
            f = B.(lower(name));
        end

        function names = recipeNames()
            names = {'filters', 'standard', 'full'};
        end

        function t = recipeLabel(name)
            switch name
                case 'filters', t = 'Filters only (high-pass, low-pass)';
                case 'standard', t = 'Standard (filters, bad channels, ICA/ICLabel threshold, epoch rejection)';
                case 'full', t = 'Full (standard + ASR)';
                otherwise, error('NeuroQC:Simple', 'Unknown recipe %s (filters, standard, full).', name);
            end
        end

        function c = contract(EEG, measure, events, segment)
            % The analysis contract of a simple-mode choice. measure: an ERP
            % component or a band name; events: the event types (ERP: one
            % condition per type) - ignored for a band.
            if nargin < 4 || isempty(segment), segment = 2; end
            labels = {EEG.chanlocs.labels};
            if any(strcmpi(measure, neuroqc.simple.Presets.bandNames()))
                roi = neuroqc.simple.Presets.eegChannels(EEG);
                c = neuroqc.eval.Contract('analysis', 'bandpower', 'segment', segment, ...
                    'bands', {lower(measure), neuroqc.simple.Presets.band(measure), roi});
                return;
            end
            p = neuroqc.simple.Presets.component(measure);
            events = cellstr(events);
            assert(~isempty(events), 'NeuroQC:Simple', 'Choose the %s-locked event type(s) for %s.', p.lockedTo, p.name);
            [ok, at] = ismember(lower(p.sites), lower(labels));
            assert(all(ok), 'NeuroQC:Simple', ['%s is measured at %s (ERP CORE); the dataset has no %s. ', ...
                'Use Advanced... to choose other channels.'], p.name, strjoin(p.sites, '/'), strjoin(p.sites(~ok), ', '));
            conds = [events(:) cellfun(@(e) {e}, events(:), 'UniformOutput', false)];
            c = neuroqc.eval.Contract('conditions', conds, 'epoch', p.epoch, 'baseline', p.baseline, ...
                'components', {p.name, p.window, labels(at), {'mean', p.polarity}});
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
            neuroqc.simple.Presets.recipeLabel(name);           % validates the name
            notes = {};
            plan = neuroqc.plan.Plan();
            continuous = ~state.isEpoched;
            if continuous
                plan = plan.add('highpass'); plan = plan.add('lowpass');
            else
                notes{end+1} = 'the data are already epoched, so filters are not compared (they must run before epoching)';
            end
            if any(strcmp(name, {'standard', 'full'}))
                if state.nLocated == 0
                    notes{end+1} = 'no channel locations: bad-channel interpolation and ICLabel are left out';
                else
                    plan = plan.add('badchannels');
                end
                if strcmp(name, 'full')
                    if ~continuous
                        notes{end+1} = 'ASR needs continuous data: left out';
                    elseif exist('pop_clean_rawdata', 'file') ~= 2
                        notes{end+1} = 'clean_rawdata is not installed: ASR left out';
                    else
                        plan = plan.add('asr');
                    end
                end
                if exist('pop_iclabel', 'file') ~= 2
                    notes{end+1} = 'ICLabel is not installed: ICA and IC removal left out';
                elseif state.nLocated > 0
                    plan = plan.add('ica'); plan = plan.add('icremove');
                end
            end
            if continuous, plan = plan.add('epoch'); end
            if ~isempty(contract.baseline), plan = plan.add('baseline'); end
            if any(strcmp(name, {'standard', 'full'})), plan = plan.add('reject_threshold'); end
        end
    end
end
