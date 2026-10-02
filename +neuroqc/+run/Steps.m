classdef Steps
    %STEPS Execute one plan step with native EEGLAB functions.
    %
    %   [EEG, coms, info] = neuroqc.run.Steps.run(inst, EEG, ctx)
    %
    %   coms is the list of EEGLAB commands that reproduce the step; the
    %   executor appends them to EEG.history, so every candidate (and the
    %   dataset you adopt) carries a history that re-runs exactly what was
    %   done. info carries counts used by the evaluation (interpolated
    %   channels, removed ICs, rejected epochs).

    methods (Static)
        function [EEG, coms, info] = run(inst, EEG, ctx)
            p = inst.params;
            coms = {};
            info = struct();
            switch inst.type
                case 'resample'
                    [EEG, com] = pop_resample(EEG, p.fs);
                    coms = {com};
                    if EEG.srate ~= p.fs && abs(EEG.srate - p.fs) < 1e-6
                        % pop_resample can leave e.g. 250.00000000000003 when the
                        % original rate was not exactly integer; ICLabel rejects that.
                        EEG.srate = p.fs; EEG = eeg_checkset(EEG);
                        coms{end+1} = sprintf('EEG.srate = %g; EEG = eeg_checkset(EEG); %% NeuroQC: exact rate after resampling', p.fs);
                    end
                case 'highpass'
                    [EEG, com] = pop_eegfiltnew(EEG, 'locutoff', p.cutoff, 'plotfreqz', 0);
                    coms = {com};
                case 'lowpass'
                    [EEG, com] = pop_eegfiltnew(EEG, 'hicutoff', p.cutoff, 'plotfreqz', 0);
                    coms = {com};
                case 'linenoise'
                    [EEG, com] = pop_eegfiltnew(EEG, 'locutoff', p.freq - p.halfwidth, ...
                        'hicutoff', p.freq + p.halfwidth, 'revfilt', 1, 'plotfreqz', 0);
                    coms = {com};
                case 'asr'
                    assert(exist('pop_clean_rawdata', 'file') == 2, 'NeuroQC:Dependency', 'clean_rawdata plugin not installed');
                    [EEG, com] = pop_clean_rawdata(EEG, 'FlatlineCriterion', 'off', 'ChannelCriterion', 'off', ...
                        'LineNoiseCriterion', 'off', 'Highpass', 'off', 'BurstCriterion', p.cutoff, ...
                        'WindowCriterion', 'off', 'BurstRejection', 'off', 'Distance', 'Euclidian');
                    coms = {com};
                case 'badchannels'
                    [EEG, coms, info] = neuroqc.run.Steps.badChannels(EEG, p);
                case 'restore'
                    assert(isfield(EEG, 'etc') && isfield(EEG.etc, 'neuroqc') && isfield(EEG.etc.neuroqc, 'rootChanlocs'), ...
                        'NeuroQC:Restore', 'Root channel montage not recorded');
                    target = EEG.etc.neuroqc.rootChanlocs;
                    missing = setdiff(lower({target.labels}), lower({EEG.chanlocs.labels}));
                    EEG = pop_interp(EEG, target, 'spherical');
                    coms = {'EEG = pop_interp(EEG, EEG.etc.neuroqc.rootChanlocs, ''spherical'');'};
                    info.interpolated = missing;
                case 'reref'
                    if strcmp(p.mode, 'average')
                        [EEG, com] = pop_reref(EEG, []);
                    else
                        ch = cellstr(p.channels);
                        assert(~isempty(ch), 'NeuroQC:Reref', 'reref mode channels needs channel labels');
                        [EEG, com] = pop_reref(EEG, ch);
                    end
                    coms = {com};
                case 'ica'
                    [EEG, coms] = neuroqc.run.Steps.ica(EEG, p, ctx);
                case 'icremove'
                    [EEG, coms, info] = neuroqc.run.Steps.icRemove(EEG, p);
                case 'epoch'
                    c = ctx.contract;
                    [EEG, ~, com] = pop_epoch(EEG, c.allEvents(), c.epoch, 'epochinfo', 'yes');
                    coms = {com};
                case 'baseline'
                    c = ctx.contract;
                    % clamp to the epoch limits (they can differ from the
                    % contract by less than one sample after resampling)
                    b = 1000 * c.baseline;
                    assert(b(1) >= 1000 * EEG.xmin - 1000 / EEG.srate && b(2) <= 1000 * EEG.xmax + 1000 / EEG.srate, ...
                        'NeuroQC:Baseline', 'Baseline [%g %g] ms lies outside the epochs [%g %g] ms', b, 1000 * [EEG.xmin EEG.xmax]);
                    b = [max(b(1), 1000 * EEG.xmin) min(b(2), 1000 * EEG.xmax)];
                    [EEG, com] = pop_rmbase(EEG, b, []);
                    coms = {com};
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    [EEG, coms, info] = neuroqc.run.Steps.rejectEpochs(EEG, inst.type, p);
                case 'native'
                    [EEG, coms] = neuroqc.run.Steps.native(EEG, p.command);
                otherwise
                    error('NeuroQC:UnknownStep', 'Unknown step %s', inst.type);
            end
            coms = coms(~cellfun(@isempty, coms));
        end

        function [EEG, coms, info] = badChannels(EEG, p)
            args = {'elec', 1:EEG.nbchan, 'threshold', p.threshold, 'norm', 'on', 'measure', p.measure};
            if strcmp(p.measure, 'spec'), args = [args {'freqrange', [1 min(50, EEG.srate/2 - 1)]}]; end
            [EEGrem, bad, ~, com] = pop_rejchan(EEG, args{:}); %#ok<ASGLU>
            bad = bad(:)';
            labels = {EEG.chanlocs(bad).labels};
            info.badChannels = labels;
            if strcmp(p.action, 'remove')
                EEG = EEGrem;
                coms = {com};
                info.removed = labels;
                return;
            end
            % interpolate in place: detection result + explicit interpolation
            coms = {sprintf('%% NeuroQC: pop_rejchan(measure %s, threshold %g, norm on) -> bad channels [%s] interpolated in place', ...
                p.measure, p.threshold, strjoin(labels, ' '))};
            info.interpolated = labels;
            if ~isempty(bad)
                hasXYZ = isfield(EEG.chanlocs, 'X') && all(arrayfun(@(c) ~isempty(c.X), EEG.chanlocs));
                assert(hasXYZ, 'NeuroQC:Chanlocs', 'Spherical interpolation needs channel locations (Edit > Channel locations).');
                [EEG, com2] = pop_interp(EEG, bad, 'spherical');
                coms{end+1} = com2;
            end
        end

        function [EEG, coms] = ica(EEG, p, ctx)
            opts = {'icatype', 'runica', 'extended', p.extended, 'rndreset', 'no', 'interrupt', 'off'};
            applied = 0; if isfield(ctx, 'highpass'), applied = ctx.highpass; end
            if p.fitHighpass > 0 && p.fitHighpass > applied
                % Fit on a high-passed copy (stable decomposition), apply
                % the weights to the data as they are (ERP signal kept).
                [tmp, c1] = pop_eegfiltnew(EEG, 'locutoff', p.fitHighpass, 'plotfreqz', 0); %#ok<ASGLU>
                [tmp, c2] = pop_runica(tmp, opts{:});
                EEG.icaweights = tmp.icaweights; EEG.icasphere = tmp.icasphere;
                EEG.icachansind = tmp.icachansind; EEG.icawinv = []; EEG.icaact = [];
                EEG = eeg_checkset(EEG);
                c2 = regexprep(c2, '^\s*EEG\s*=\s*pop_runica\(\s*EEG', 'EEGica = pop_runica(EEGica');
                coms = {sprintf(['EEGica = pop_eegfiltnew(EEG, ''locutoff'', %g, ''plotfreqz'', 0); %s ', ...
                    'EEG.icaweights = EEGica.icaweights; EEG.icasphere = EEGica.icasphere; ', ...
                    'EEG.icachansind = EEGica.icachansind; EEG.icawinv = []; EEG.icaact = []; ', ...
                    'EEG = eeg_checkset(EEG); clear EEGica; %% NeuroQC: ICA fitted on a %g Hz high-passed copy'], ...
                    p.fitHighpass, c2, p.fitHighpass)};
            else
                [EEG, com] = pop_runica(EEG, opts{:});
                coms = {com};
            end
        end

        function [EEG, coms, info] = icRemove(EEG, p)
            assert(exist('pop_iclabel', 'file') == 2, 'NeuroQC:Dependency', 'ICLabel plugin not installed');
            [EEG, c1] = pop_iclabel(EEG, 'default');
            cats = {'Brain','Muscle','Eye','Heart','Line Noise','Channel Noise','Other'};
            classes = cellstr(p.classes);
            assert(all(ismember(classes, cats)) && ~ismember('Brain', classes), 'NeuroQC:ICLabel', ...
                'classes must be ICLabel artifact classes: %s', strjoin(cats(2:end), ', '));
            T = nan(7, 2);
            T(ismember(cats, classes), :) = repmat([p.threshold 1], sum(ismember(cats, classes)), 1);
            [EEG, c2] = pop_icflag(EEG, T);
            comps = find(EEG.reject.gcompreject(:)');
            info.icsTotal = size(EEG.icaweights, 1);
            info.icsRemoved = numel(comps);
            coms = {c1, c2};
            if ~isempty(comps)
                [EEG, c3] = pop_subcomp(EEG, comps, 0);
                coms{end+1} = c3;
            end
        end

        function [EEG, coms, info] = rejectEpochs(EEG, type, p)
            n0 = EEG.trials;
            chans = 1:EEG.nbchan;
            if isfield(p, 'exclude') && ~isempty(p.exclude)
                chans = find(~ismember(lower({EEG.chanlocs.labels}), lower(cellstr(p.exclude))));
            end
            switch type
                case 'reject_threshold'
                    [EEG, ~, c1] = pop_eegthresh(EEG, 1, chans, -p.uv, p.uv, EEG.xmin, EEG.xmax, 0, 0);
                    marks = EEG.reject.rejthresh;
                case 'reject_jointprob'
                    [EEG, ~, ~, ~, c1] = pop_jointprob(EEG, 1, chans, p.sd, p.sd, 0, 0, 0, [], 0);
                    marks = EEG.reject.rejjp;
                case 'reject_kurtosis'
                    [EEG, ~, ~, ~, c1] = pop_rejkurt(EEG, 1, chans, p.sd, p.sd, 0, 0, 0, [], 0);
                    marks = EEG.reject.rejkurt;
            end
            idx = find(marks);
            % which channels drive the rejections (a hint for bad channels)
            E = [];
            switch type
                case 'reject_threshold', if isfield(EEG.reject, 'rejthreshE'), E = EEG.reject.rejthreshE; end
                case 'reject_jointprob', if isfield(EEG.reject, 'rejjpE'), E = EEG.reject.rejjpE; end
                case 'reject_kurtosis', if isfield(EEG.reject, 'rejkurtE'), E = EEG.reject.rejkurtE; end
            end
            info.topChannels = '';
            if ~isempty(E) && size(E, 1) == EEG.nbchan && ~isempty(idx)
                [cnt, order] = sort(sum(E(:, idx) ~= 0, 2), 'descend');
                keep = order(cnt > 0); keep = keep(1:min(5, numel(keep)));
                info.topChannels = strjoin(arrayfun(@(c) sprintf('%s (%d)', EEG.chanlocs(c).labels, ...
                    sum(E(c, idx) ~= 0)), keep(:)', 'UniformOutput', false), ', ');
                neuroqc.utils.log('%d/%d epochs rejected; channels most often over the limit: %s', ...
                    numel(idx), n0, info.topChannels);
            end
            coms = {c1};
            if ~isempty(idx)
                assert(numel(idx) < n0, 'NeuroQC:AllRejected', 'every epoch would be rejected');
                [EEG, c2] = pop_rejepoch(EEG, idx, 0);
                coms{end+1} = c2;
            end
            info.rejected = numel(idx);
        end

        function [EEG, coms] = native(EEG, command)
            % Replay a command captured from an EEGLAB dialog. It runs in an
            % isolated workspace that only contains EEG.
            cmd = strtrim(char(command));
            assert(isempty(regexp(cmd, '\<(ALLEEG|CURRENTSET|STUDY|CURRENTSTUDY)\>', 'once')), ...
                'NeuroQC:Native', 'The command refers to other datasets (ALLEEG/STUDY); it cannot be replayed on candidates.');
            % Display-only options must not open windows during a search.
            cmd = regexprep(cmd, '''plotfreqz''\s*,\s*1', '''plotfreqz'',0');
            cmd = regexprep(cmd, '''interrupt''\s*,\s*''on''', '''interrupt'',''off''');
            EEG = evalWithEEG(EEG, cmd);
            coms = {cmd};
        end
    end
end

function EEG = evalWithEEG(EEG, NEUROQC_CMD__)
eval(NEUROQC_CMD__);
end
