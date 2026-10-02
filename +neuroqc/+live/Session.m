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
            % events, ICA size, history text and a sparse data sample.
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
            fp = sprintf('%s|%d|%d|%d|%g|%d|%d|%d|%d|%s|%.10g', fieldStr(EEG, 'setname'), ...
                EEG.nbchan, EEG.pnts, EEG.trials, EEG.srate, numel(EEG.event), nIca, nFlag, ...
                numel(h), dec2hex(mod(sum(double(h) .* (1:numel(h))), 2^48)), sum(sample .* (1:numel(sample))));
        end
    end
end

function s = fieldStr(EEG, f)
s = '';
if isfield(EEG, f) && ~isempty(EEG.(f)), s = char(string(EEG.(f))); end
end
