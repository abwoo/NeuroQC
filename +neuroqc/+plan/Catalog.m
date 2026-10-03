classdef Catalog
    %CATALOG The processing steps NeuroQC can place in a plan.
    %
    %   Each step is executed by native EEGLAB functions (see
    %   neuroqc.run.Steps). For every parameter the catalog defines:
    %
    %     default  value used when you do not mention the parameter and it
    %              has no search list
    %     suggest  candidate values searched when you do NOT fix the
    %              parameter (empty = not searched by default)
    %     defines  true for parameters that change what is measured
    %              (reference). They may be searched, but candidates that
    %              differ in them are ranked in separate strata: a
    %              data-quality score cannot fairly compare different
    %              measured quantities.
    %
    %   'native' wraps any EEGLAB command you configured in its own dialog;
    %   it is always fixed and is replayed verbatim.

    methods (Static)
        function names = types()
            names = {'resample','linenoise','highpass','lowpass','asr','badchannels','channels', ...
                'restore','reref','ica','icremove','epoch','baseline', ...
                'reject_threshold','reject_jointprob','reject_kurtosis','native'};
        end

        function d = get(type)
            P = @(name, default, suggest, defines, doc) struct('name', name, 'default', {default}, ...
                'suggest', {suggest}, 'defines', defines, 'doc', doc);
            none = P('', [], {}, false, ''); none(1) = [];
            d = struct('type', type, 'label', '', 'params', none, 'dialog', '', 'probe', false, 'doc', '');
            switch type
                case 'resample'
                    d.label = 'Resample'; d.dialog = 'pop_resample';
                    d.params = P('fs', [], {}, false, 'new sampling rate (Hz), downsampling only; required (no default)');
                    d.probe = true;
                case 'linenoise'
                    d.label = 'Line-noise notch (FIR band-stop)'; d.dialog = 'pop_eegfiltnew';
                    d.params = [P('freq', 'auto', {}, false, 'line frequency (Hz); ''auto'' = 50 or 60 Hz detected from the dataset''s spectrum'), ...
                        P('halfwidth', 2, {}, false, 'stop band = freq +/- halfwidth (Hz)')];
                    d.probe = true;
                case 'highpass'
                    d.label = 'High-pass filter'; d.dialog = 'pop_eegfiltnew';
                    d.params = P('cutoff', 0.1, {0.1, 0.3, 0.5, 1}, false, 'pass-band edge (Hz)');
                    d.probe = true;
                case 'lowpass'
                    d.label = 'Low-pass filter'; d.dialog = 'pop_eegfiltnew';
                    d.params = P('cutoff', 30, {20, 30, 40}, false, 'pass-band edge (Hz)');
                    d.probe = true;
                case 'asr'
                    d.label = 'ASR burst correction (clean_rawdata)'; d.dialog = 'pop_clean_rawdata';
                    d.params = P('cutoff', 20, {10, 20, 30}, false, 'burst criterion (SD)');
                case 'badchannels'
                    d.label = 'Bad-channel detection'; d.dialog = 'pop_rejchan';
                    d.params = [P('measure', 'kurt', {'kurt','prob'}, false, 'pop_rejchan measure'), ...
                        P('threshold', 5, {3, 5}, false, 'z threshold'), ...
                        P('exclude', {}, {}, false, 'channels not tested (e.g. EOG, reference electrodes)'), ...
                        P('action', 'interpolate', {}, false, '''interpolate'' in place or ''remove'' (restore later)')];
                case 'channels'
                    d.label = 'Named channels: remove or interpolate'; d.dialog = 'pop_select';
                    d.params = [P('labels', {}, {}, false, 'channel labels you name (e.g. known-bad O1, O2)'), ...
                        P('action', 'interpolate', {}, false, '''remove'' or ''interpolate''')];
                case 'restore'
                    d.label = 'Restore removed channels (spherical interpolation): the starting montage plus channels removed before NeuroQC (chaninfo.removedchans, with locations)'; d.dialog = 'pop_interp';
                case 'reref'
                    d.label = 'Re-reference'; d.dialog = 'pop_reref';
                    d.params = [P('mode', 'average', {}, true, '''average'' or ''channels'''), ...
                        P('channels', {}, {}, true, 'reference channel labels (mode = channels)'), ...
                        P('exclude', {}, {}, true, 'channels neither re-referenced nor part of the average (e.g. EOG, ECG)')];
                case 'ica'
                    d.label = 'ICA (runica, extended)'; d.dialog = 'pop_runica';
                    d.params = [P('fitHighpass', 1, {}, false, 'fit ICA on a copy high-passed at this edge (Hz); 0 = fit on the data as is'), ...
                        P('extended', 1, {}, false, 'runica extended mode')];
                case 'icremove'
                    d.label = 'Remove artifact ICs (ICLabel)'; d.dialog = 'pop_icflag';
                    d.params = [P('threshold', 0.9, {0.7, 0.8, 0.9}, false, 'minimum ICLabel probability of an artifact class'), ...
                        P('classes', {'Muscle','Eye','Heart','Line Noise','Channel Noise'}, {}, false, 'ICLabel classes treated as artifact')];
                case 'epoch'
                    d.label = 'Extract epochs (from the analysis contract)'; d.dialog = 'pop_epoch';
                case 'baseline'
                    d.label = 'Baseline removal (from the analysis contract)'; d.dialog = 'pop_rmbase';
                case 'reject_threshold'
                    d.label = 'Reject epochs: amplitude threshold'; d.dialog = 'pop_eegthresh';
                    d.params = [P('uv', 100, {75, 100, 150}, false, 'absolute threshold (uV)'), P('exclude', {}, {}, false, 'channel labels ignored by the test (e.g. EOG channels)')];
                case 'reject_jointprob'
                    d.label = 'Reject epochs: joint probability'; d.dialog = 'pop_jointprob';
                    d.params = [P('sd', 5, {3, 4, 5}, false, 'local and global limit (SD)'), P('exclude', {}, {}, false, 'channel labels ignored by the test (e.g. EOG channels)')];
                case 'reject_kurtosis'
                    d.label = 'Reject epochs: kurtosis'; d.dialog = 'pop_rejkurt';
                    d.params = [P('sd', 5, {3, 4, 5}, false, 'local and global limit (SD)'), P('exclude', {}, {}, false, 'channel labels ignored by the test (e.g. EOG channels)')];
                case 'native'
                    d.label = 'Native EEGLAB command (fixed)';
                    d.params = P('command', '', {}, true, 'command returned by an EEGLAB dialog');
                otherwise
                    error('NeuroQC:UnknownStep', 'Unknown step "%s". Known steps: %s', ...
                        type, strjoin(neuroqc.plan.Catalog.types(), ', '));
            end
        end

        function [reason, st] = apply(type, p, st)
            % Check that a step is legal in abstract data state st and
            % return the state after it. reason is '' when legal.
            reason = '';
            reason = invalidValue(type, p);   % explicit values are checked, never replaced by defaults
            if ~isempty(reason), return; end
            switch type
                case 'resample'
                    if ~(p.fs < st.srate), reason = sprintf('resample to %g Hz is not a downsampling of %g Hz', p.fs, st.srate); return; end
                    st.srate = p.fs;
                case {'highpass','lowpass','linenoise','asr'}
                    if st.epoched, reason = sprintf('%s must run on continuous data (before epoching)', type); return; end
                    if any(strcmp(type, {'highpass','lowpass'})) && p.cutoff >= st.srate/2
                        reason = sprintf('%s %g Hz is at/above Nyquist (%g Hz)', type, p.cutoff, st.srate/2); return;
                    end
                    if strcmp(type, 'linenoise') && p.freq + p.halfwidth >= st.srate/2
                        reason = 'notch band reaches Nyquist'; return;
                    end
                    if strcmp(type, 'highpass'), st.highpass = max(st.highpass, p.cutoff); end
                case 'badchannels'
                    if strcmp(p.action, 'remove')
                        if st.hasICA && ~st.icRemoved
                            reason = 'removing channels after ICA invalidates the decomposition'; return;
                        end
                        st.removed = true;
                    elseif ~strcmp(p.action, 'interpolate')
                        reason = 'badchannels action must be interpolate or remove'; return;
                    end
                case 'channels'
                    if isempty(p.labels), reason = 'channels step needs labels'; return; end
                    if strcmp(p.action, 'remove')
                        if st.hasICA && ~st.icRemoved
                            reason = 'removing channels after ICA invalidates the decomposition'; return;
                        end
                        st.removed = true;
                    elseif ~strcmp(p.action, 'interpolate')
                        reason = 'channels action must be remove or interpolate'; return;
                    end
                case 'restore'
                    if ~st.removed, reason = 'restore needs channels removed earlier in the plan or before NeuroQC (EEG.chaninfo.removedchans)'; return; end
                    st.removed = false;
                case 'reref'
                    if ~any(strcmp(p.mode, {'average','channels'})), reason = 'reref mode must be average or channels'; return; end
                case 'ica'
                    st.hasICA = true; st.icRemoved = false;
                case 'icremove'
                    if ~st.hasICA, reason = 'IC removal needs ICA earlier in the plan or in the dataset'; return; end
                    if st.icRemoved, reason = 'ICs of this decomposition were already removed'; return; end
                    st.icRemoved = true;
                case 'epoch'
                    if st.epoched, reason = 'data are already epoched'; return; end
                    st.epoched = true;
                case {'baseline','reject_threshold','reject_jointprob','reject_kurtosis'}
                    if ~st.epoched, reason = sprintf('%s needs epoched data', type); return; end
                case 'native'
                    % Infer the effect from the EEGLAB functions the
                    % statements call (a captured workflow has several).
                    for stmt = neuroqc.run.Native.statements(p.command)
                        e = neuroqc.live.History.classify(stmt{1});
                        switch e.step
                            case 'epoch'
                                if st.epoched, reason = 'native pop_epoch on epoched data'; return; end
                                st.epoched = true;
                            case 'resample'
                                if isfield(e.params, 'fs') && isfinite(e.params.fs), st.srate = e.params.fs; end
                            case 'ica', st.hasICA = true; st.icRemoved = false;
                            case {'ic_flags','icremove'}
                                if ~st.hasICA, reason = sprintf('native %s needs ICA earlier in the plan or in the dataset', e.fn); return; end
                                if strcmp(e.step, 'icremove'), st.icRemoved = true; end
                            case {'highpass','lowpass','bandpass','linenoise'}
                                if st.epoched, reason = 'native filter on epoched data'; return; end
                                if isfield(e.params, 'locutoff') && isfinite(e.params.locutoff) && ~e.params.revfilt
                                    st.highpass = max(st.highpass, e.params.locutoff);
                                end
                            case {'baseline','reject_epochs','epoch_flags'}
                                if ~st.epoched, reason = 'native epoch-level command on continuous data'; return; end
                        end
                    end
            end
        end
    end
end

function reason = invalidValue(type, p)
% Values outside the valid domain make the pipeline illegal (with the
% reason), rather than failing inside EEGLAB or being silently defaulted.
reason = '';
pos = @(f) isfield(p, f) && ~(isnumeric(p.(f)) && isscalar(p.(f)) && isfinite(p.(f)) && p.(f) > 0);
switch type
    case 'resample'
        if ~isfield(p, 'fs') || isempty(p.fs), reason = 'resample needs the new rate fs (no default; set it, e.g. from the EEGLAB dialog)';
        elseif pos('fs'), reason = 'resample fs must be a positive number'; end
    case {'highpass','lowpass'}, if pos('cutoff'), reason = sprintf('%s cutoff must be a positive number (Hz)', type); end
    case 'linenoise'
        if isfield(p, 'freq') && ischar(p.freq), reason = 'no clear 50/60 Hz line noise in this dataset; set linenoise freq';
        elseif pos('freq') || pos('halfwidth'), reason = 'linenoise freq and halfwidth must be positive numbers (Hz)'; end
    case 'asr', if pos('cutoff'), reason = 'asr cutoff must be a positive number (SD)'; end
    case 'badchannels', if pos('threshold'), reason = 'badchannels threshold must be a positive number'; end
    case 'reject_threshold', if pos('uv'), reason = 'reject_threshold uv must be a positive number'; end
    case {'reject_jointprob','reject_kurtosis'}, if pos('sd'), reason = sprintf('%s sd must be a positive number', type); end
    case 'icremove'
        if pos('threshold') || p.threshold > 1, reason = 'icremove threshold must be a probability in (0, 1]'; end
    case 'ica', if isfield(p, 'fitHighpass') && ~(isnumeric(p.fitHighpass) && isscalar(p.fitHighpass) && p.fitHighpass >= 0)
            reason = 'ica fitHighpass must be >= 0 (0 = fit on the data as is)'; end
end
end

