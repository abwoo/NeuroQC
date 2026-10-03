classdef Session
    %SESSION Live access to the dataset that is current in EEGLAB.
    %
    %   [EEG, info] = neuroqc.live.Session.current()
    %
    %   NeuroQC has no "load data" step. It always works on the dataset
    %   EEGLAB itself would act on: the base-workspace variable EEG (the
    %   one EEGLAB menus read and write). info reports CURRENTSET and
    %   whether base EEG still equals ALLEEG(CURRENTSET) (it differs when
    %   EEG was changed on the command line and not stored).

    methods (Static)
        function [EEG, info] = current()
            info = struct('currentSet', [], 'stored', true, 'source', 'base EEG', 'fingerprint', '');
            EEG = [];
            if evalin('base', 'exist(''EEG'',''var'')')
                EEG = evalin('base', 'EEG');
            end
            if isempty(EEG) || ~isstruct(EEG) || ~isfield(EEG, 'data') || isempty(EEG.data)
                EEG = [];
                return;
            end
            if numel(EEG) > 1
                error('NeuroQC:MultipleDatasets', ...
                    'Several datasets are selected in EEGLAB; select a single dataset.');
            end
            if evalin('base', 'exist(''CURRENTSET'',''var'')')
                info.currentSet = evalin('base', 'CURRENTSET');
            end
            info.fingerprint = neuroqc.live.Session.fingerprint(EEG);
            if isscalar(info.currentSet) && info.currentSet >= 1 && ...
                    evalin('base', 'exist(''ALLEEG'',''var'')')
                n = evalin('base', 'numel(ALLEEG)');
                if info.currentSet <= n
                    stored = evalin('base', sprintf('ALLEEG(%d)', info.currentSet));
                    info.stored = strcmp(neuroqc.live.Session.fingerprint(stored), info.fingerprint);
                end
            end
        end

        function fp = fingerprint(EEG)
            % Cheap change detector (no full-data hash): dimensions, rate,
            % every event's type, latency and urevent, channel labels, ICA
            % size and flags, history text and a sparse data sample. An edit
            % to one event that keeps the event count is detected even when
            % it is not recorded in EEG.history.
            if isempty(EEG) || ~isstruct(EEG) || ~isfield(EEG, 'data') || isempty(EEG.data)
                fp = ''; return;
            end
            h = '';
            if isfield(EEG, 'history'), h = char(EEG.history); h = h(:)'; end
            nIca = 0; if isfield(EEG, 'icaweights'), nIca = size(EEG.icaweights, 1); end
            nFlag = 0;
            if isfield(EEG, 'reject') && isfield(EEG.reject, 'gcompreject'), nFlag = sum(EEG.reject.gcompreject); end
            nd = numel(EEG.data);
            idx = unique(round(linspace(1, nd, min(nd, 257))));
            sample = double(EEG.data(idx));
            labs = '';
            if isfield(EEG, 'chanlocs') && ~isempty(EEG.chanlocs) && isfield(EEG.chanlocs, 'labels')
                labs = strjoin(cellfun(@(x) char(string(x)), {EEG.chanlocs.labels}, 'UniformOutput', false), ',');
            end
            fp = sprintf('%s|%d|%d|%d|%g|%d|%d|%d|%d|%s|%.10g|%s|%s', fieldStr(EEG, 'setname'), ...
                EEG.nbchan, EEG.pnts, EEG.trials, EEG.srate, numel(EEG.event), nIca, nFlag, ...
                numel(h), textHash(h), sum(sample .* (1:numel(sample))), eventHash(EEG), textHash(labs));
        end
    end
end

function t = textHash(h)
h = double(h(:)');
t = sprintf('%s.%s', dec2hex(mod(sum(h .* (1:numel(h))), 2^48)), dec2hex(mod(sum(h .* mod((1:numel(h)) * 7919, 104729)), 2^48)));
end

function t = eventHash(EEG)
% Position-weighted digest of every event's type, latency and urevent.
t = '0';
if ~isfield(EEG, 'event') || isempty(EEG.event), return; end
ev = EEG.event;
ty = arrayfun(@(e) toText(e.type), ev, 'UniformOutput', false);
lat = zeros(1, numel(ev)); ure = zeros(1, numel(ev));
if isfield(ev, 'latency'), lat = arrayfun(@(e) numOr(e.latency), ev); end
if isfield(ev, 'urevent'), ure = arrayfun(@(e) numOr(e.urevent), ev); end
w = 1:numel(ev);
t = sprintf('%s|%.12g|%.12g', textHash(strjoin(ty, char(1))), sum(lat .* w), sum(ure .* w));
end

function t = toText(x)
if isempty(x), t = ''; else, t = char(string(x)); end
end

function v = numOr(x)
if isnumeric(x) && isscalar(x), v = double(x); else, v = 0; end
end

function s = fieldStr(EEG, f)
s = '';
if isfield(EEG, f) && ~isempty(EEG.(f)), s = char(string(EEG.(f))); end
end
