classdef Steps
    %STEPS Execute one plan step with native EEGLAB functions.
    %
    %   [EEG, coms, info] = pipecompare.run.Steps.run(inst, EEG, ctx)
    %
    %   coms are the EEGLAB commands that reproduce the step; the executor
    %   appends them to the candidate's EEG.history. info carries the
    %   data-dependent decisions the step took (bad channels, ICA matrices,
    %   removed components, rejected epochs) and counts for the evaluation.
    %
    %   EEG = pipecompare.run.Steps.replayDecision(inst, EEG, info, ctx)
    %
    %   Applies the SAME decisions to another dataset with the same
    %   structure (used by pipecompare.eval.Injection to measure how a known
    %   signal is transferred by exactly the operations applied to the
    %   real data). ASR replays its recorded window-by-window
    %   reconstructions (pipecompare.run.AsrRecord, verified against EEGLAB's
    %   output); captured mark/remove workflows replay the epochs and
    %   components they removed. Other native commands are re-run and
    %   reported as not decision-matched.

    methods (Static)
        function [EEG, coms, info] = run(inst, EEG, ctx)
            p = inst.params;
            coms = {};
            info = struct();
            switch inst.type
                case 'resample'
                    [EEG, com] = pop_resample(EEG, p.fs);
                    coms = {com};
                    if EEG.srate ~= p.fs && abs(EEG.srate - p.fs) <= 1e-9 * p.fs
                        % pop_resample leaves e.g. 250.00000000000003 when the
                        % original rate was not exactly representable; only a
                        % floating-point residue is corrected (ICLabel needs it).
                        EEG.srate = p.fs; EEG = eeg_checkset(EEG);
                        coms{end+1} = sprintf('EEG.srate = %g; EEG = eeg_checkset(EEG); %% PipeCompare: exact rate after resampling', p.fs);
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
                    assert(exist('pop_clean_rawdata', 'file') == 2, 'PipeCompare:Dependency', 'clean_rawdata plugin not installed');
                    E0 = EEG;
                    [EEG, com] = pop_clean_rawdata(EEG, 'FlatlineCriterion', 'off', 'ChannelCriterion', 'off', ...
                        'LineNoiseCriterion', 'off', 'Highpass', 'off', 'BurstCriterion', p.cutoff, ...
                        'WindowCriterion', 'off', 'BurstRejection', 'off', 'Distance', 'Euclidian', ...
                        'MaxMem', pipecompare.run.AsrRecord.MaxMemMB);
                    coms = {com};
                    info.asr = recordAsr(E0, EEG, p.cutoff);
                case 'badchannels'
                    [EEG, coms, info] = pipecompare.run.Steps.badChannels(EEG, p, ctx);
                case 'channels'
                    [EEG, coms, info] = pipecompare.run.Steps.listedChannels(EEG, p);
                case 'restore'
                    % back to the starting montage, then the channels removed
                    % before PipeCompare (EEG.etc.pipecompare.preRemoved)
                    target = rootChanlocs(EEG);
                    missing = setdiff(lower({target.labels}), lower({EEG.chanlocs.labels}));
                    pre = [];
                    if isfield(EEG.etc.pipecompare, 'preRemoved'), pre = EEG.etc.pipecompare.preRemoved; end
                    if ~isempty(missing) || isempty(pre)
                        requireLocations(target(ismember(lower({target.labels}), missing)), 'restore');
                        EEG = pop_interp(EEG, target, 'spherical');
                        coms = {'EEG = pop_interp(EEG, EEG.etc.pipecompare.rootChanlocs, ''spherical'');'};
                    end
                    if ~isempty(pre)
                        absent = ~ismember(lower({pre.labels}), lower({EEG.chanlocs.labels}));
                        if any(absent)
                            requireLocations(pre(absent), 'restore');
                            EEG = pop_interp(EEG, pre(absent), 'spherical');
                            coms{end+1} = sprintf(['EEG = pop_interp(EEG, EEG.etc.pipecompare.preRemoved(%s), ''spherical''); ', ...
                                '%% PipeCompare: channels removed before the plan'], mat2str(find(absent)));
                            missing = [missing lower({pre(absent).labels})];
                        end
                    end
                    info.interpolated = missing;
                case 'reref'
                    ex = {};
                    if isfield(p, 'exclude') && ~isempty(p.exclude)
                        present = presentChannels(EEG, p.exclude, 'reref exclude');
                        xi = find(ismember(lower({EEG.chanlocs.labels}), lower(present)));
                        if ~isempty(xi), ex = {'exclude', xi}; end
                    end
                    if strcmp(p.mode, 'average')
                        [EEG, com] = pop_reref(EEG, [], ex{:});
                    else
                        ch = cellstr(p.channels);
                        assert(~isempty(ch), 'PipeCompare:Reref', 'reref mode channels needs channel labels');
                        [EEG, com] = pop_reref(EEG, ch, ex{:});
                    end
                    coms = {com};
                    info.reref = p;
                case 'ica'
                    [EEG, coms] = pipecompare.run.Steps.ica(EEG, p, ctx);
                    info.ica = struct('icaweights', EEG.icaweights, 'icasphere', EEG.icasphere, 'icachansind', EEG.icachansind);
                case 'icremove'
                    [EEG, coms, info] = pipecompare.run.Steps.icRemove(EEG, p);
                case 'epoch'
                    c = ctx.contract;
                    [EEG, ~, com] = pop_epoch(EEG, c.allEvents(), c.epoch, 'epochinfo', 'yes');
                    coms = {com};
                case 'baseline'
                    c = ctx.contract;
                    assert(~isempty(c.baseline), 'PipeCompare:Baseline', 'The contract defines no baseline window.');
                    % clamp to the epoch limits (they can differ from the
                    % contract by less than one sample after resampling)
                    b = 1000 * c.baseline;
                    assert(b(1) >= 1000 * EEG.xmin - 1000 / EEG.srate && b(2) <= 1000 * EEG.xmax + 1000 / EEG.srate, ...
                        'PipeCompare:Baseline', 'Baseline [%g %g] ms lies outside the epochs [%g %g] ms', b, 1000 * [EEG.xmin EEG.xmax]);
                    b = [max(b(1), 1000 * EEG.xmin) min(b(2), 1000 * EEG.xmax)];
                    [EEG, com] = pop_rmbase(EEG, b, []);
                    coms = {com};
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    [EEG, coms, info] = pipecompare.run.Steps.rejectEpochs(EEG, inst.type, p);
                case 'native'
                    [EEG, coms, info] = pipecompare.run.Steps.native(EEG, p.command);
                otherwise
                    error('PipeCompare:UnknownStep', 'Unknown step %s', inst.type);
            end
            coms = coms(~cellfun(@isempty, coms));
        end

        function [EEG, matched] = replayDecision(inst, EEG, info, ctx)
            % Same decisions on a structurally identical dataset.
            matched = true;
            EEG = pipecompare.eval.Injection.noteReference(EEG, inst);
            switch inst.type
                case 'badchannels'
                    if strcmp(inst.params.action, 'remove')
                        if ~isempty(info.badIdx), EEG = pop_select(EEG, 'nochannel', info.badIdx); end
                    elseif ~isempty(info.badIdx)
                        EEG = pop_interp(EEG, info.badIdx, 'spherical');
                    end
                case 'channels'
                    if ~isempty(info.listedIdx)
                        if strcmp(inst.params.action, 'remove'), EEG = pop_select(EEG, 'nochannel', info.listedIdx);
                        else, EEG = pop_interp(EEG, info.listedIdx, 'spherical'); end
                    end
                case 'ica'
                    EEG.icaweights = info.ica.icaweights; EEG.icasphere = info.ica.icasphere;
                    EEG.icachansind = info.ica.icachansind; EEG.icawinv = []; EEG.icaact = [];
                    EEG = eeg_checkset(EEG);
                case 'icremove'
                    if ~isempty(info.comps), EEG = pop_subcomp(EEG, info.comps, 0); end
                case {'reject_threshold','reject_jointprob','reject_kurtosis'}
                    if ~isempty(info.rejIdx), EEG = pop_rejepoch(EEG, info.rejIdx, 0); end
                case 'native'
                    if isfield(info, 'decisions') && ~isempty(info.decisions)
                        % a workflow of marks and removals: the removals the
                        % real data decided, applied to this copy
                        for d = info.decisions
                            if strcmp(d.kind, 'epochs') && ~isempty(d.idx), EEG = pop_rejepoch(EEG, d.idx, 0); end
                            if strcmp(d.kind, 'comps') && ~isempty(d.idx), EEG = pop_subcomp(EEG, d.idx, 0); end
                        end
                    else
                        % re-run; that is the same operation when every
                        % statement is a fixed transform (no data-driven choice)
                        EEG = pipecompare.run.Steps.run(inst, EEG, ctx);
                        matched = all(cellfun(@isFixedTransform, pipecompare.run.Native.statements(inst.params.command)));
                    end
                case 'asr'
                    if isfield(info, 'asr') && ~isempty(info.asr)
                        % the windows and reconstructions ASR chose on the real data
                        EEG.data = cast(pipecompare.run.AsrRecord.apply(info.asr, EEG.data), 'like', EEG.data);
                    else
                        matched = false;
                        EEG = pipecompare.run.Steps.run(inst, EEG, ctx);
                    end
                otherwise
                    EEG = pipecompare.run.Steps.run(inst, EEG, ctx);
            end
        end

        function [EEG, coms, info] = badChannels(EEG, p, ctx)
            elec = 1:EEG.nbchan;
            if isfield(p, 'exclude') && ~isempty(p.exclude)   % e.g. EOG / reference channels are not tested
                elec = find(~ismember(lower({EEG.chanlocs.labels}), lower(presentChannels(EEG, p.exclude, 'badchannels exclude'))));
            end
            args = {'elec', elec, 'threshold', p.threshold, 'norm', 'on', 'measure', p.measure};
            if strcmp(p.measure, 'spec'), args = [args {'freqrange', [1 min(50, EEG.srate/2 - 1)]}]; end
            % Detect on a high-passed copy (slow drifts distort kurtosis
            % and probability), interpolate or remove on the data as they are.
            hp = pipecompare.utils.fieldOr(p, 'detectHighpass', 0);
            applied = 0; if nargin > 2 && isfield(ctx, 'highpass'), applied = ctx.highpass; end
            copy = hp > 0 && hp > applied;
            src = EEG; on = '';
            if copy
                src = pop_eegfiltnew(EEG, 'locutoff', hp, 'plotfreqz', 0);
                on = sprintf(' on a %g Hz high-passed copy', hp);
            end
            [EEGrem, bad, ~, com] = pop_rejchan(src, args{:});
            bad = elec(bad(:)');   % pop_rejchan indexes the tested channels (it removes opt.elec(indelec) itself)
            labels = {EEG.chanlocs(bad).labels};
            info.badChannels = labels; info.badIdx = bad;
            if strcmp(p.action, 'remove')
                info.removed = labels;
                if ~copy
                    EEG = EEGrem;
                    coms = {com};
                    return;
                end
                coms = {sprintf('%% PipeCompare: pop_rejchan(measure %s, threshold %g, norm on, %d channels tested)%s -> bad channels [%s] removed', ...
                    p.measure, p.threshold, numel(elec), on, strjoin(labels, ' '))};
                if ~isempty(bad)
                    [EEG, com2] = pop_select(EEG, 'nochannel', bad);
                    coms{end+1} = com2;
                end
                return;
            end
            coms = {sprintf('%% PipeCompare: pop_rejchan(measure %s, threshold %g, norm on, %d channels tested)%s -> bad channels [%s] interpolated in place', ...
                p.measure, p.threshold, numel(elec), on, strjoin(labels, ' '))};
            info.interpolated = labels;
            if ~isempty(bad)
                requireLocations(EEG.chanlocs(bad), 'badchannels');
                [EEG, com2] = pop_interp(EEG, bad, 'spherical');
                coms{end+1} = com2;
            end
        end

        function [EEG, coms, info] = listedChannels(EEG, p)
            % Channels you name (e.g. known-bad O1/O2): remove or interpolate.
            labels = cellstr(p.labels);
            [ok, idx] = ismember(lower(labels), lower({EEG.chanlocs.labels}));
            assert(all(ok), 'PipeCompare:Channels', 'Channel(s) not in the data: %s', strjoin(labels(~ok), ', '));
            info.listedIdx = idx(:)';
            switch p.action
                case 'remove'
                    [EEG, com] = pop_select(EEG, 'rmchannel', labels);
                    coms = {com}; info.removed = labels;
                case 'interpolate'
                    requireLocations(EEG.chanlocs(idx), 'channels');
                    [EEG, com] = pop_interp(EEG, idx(:)', 'spherical');
                    coms = {com}; info.interpolated = labels;
                otherwise
                    error('PipeCompare:Channels', 'channels action must be remove or interpolate');
            end
        end

        function [EEG, coms] = ica(EEG, p, ctx)
            % 'rndreset','no' makes runica start from a fixed random state,
            % so the same data give the same decomposition. Adopting a
            % candidate (replay must reproduce the evaluated scores) relies
            % on this; it holds for runica in EEGLAB 2026.0 (checked by
            % test_engine/testEndToEndRecoversSensibleChoice and the adopt
            % replay check, which refuses a candidate that differs).
            opts = {'icatype', 'runica', 'extended', p.extended, 'rndreset', 'no', 'interrupt', 'off'};
            applied = 0; if isfield(ctx, 'highpass'), applied = ctx.highpass; end
            if p.fitHighpass > 0 && p.fitHighpass > applied
                % Fit on a high-passed copy (stable decomposition), apply
                % the weights to the data as they are (ERP signal kept).
                [tmp, ~] = pop_eegfiltnew(EEG, 'locutoff', p.fitHighpass, 'plotfreqz', 0);
                [tmp, c2] = pop_runica(tmp, opts{:});
                EEG.icaweights = tmp.icaweights; EEG.icasphere = tmp.icasphere;
                EEG.icachansind = tmp.icachansind; EEG.icawinv = []; EEG.icaact = [];
                EEG = eeg_checkset(EEG);
                c2 = regexprep(c2, '^\s*EEG\s*=\s*pop_runica\(\s*EEG', 'EEGica = pop_runica(EEGica');
                coms = {sprintf(['EEGica = pop_eegfiltnew(EEG, ''locutoff'', %g, ''plotfreqz'', 0); %s ', ...
                    'EEG.icaweights = EEGica.icaweights; EEG.icasphere = EEGica.icasphere; ', ...
                    'EEG.icachansind = EEGica.icachansind; EEG.icawinv = []; EEG.icaact = []; ', ...
                    'EEG = eeg_checkset(EEG); clear EEGica; %% PipeCompare: ICA fitted on a %g Hz high-passed copy'], ...
                    p.fitHighpass, c2, p.fitHighpass)};
            else
                [EEG, com] = pop_runica(EEG, opts{:});
                coms = {com};
            end
        end

        function [EEG, coms, info] = icRemove(EEG, p)
            assert(exist('pop_iclabel', 'file') == 2, 'PipeCompare:Dependency', 'ICLabel plugin not installed');
            [EEG, c1] = pop_iclabel(EEG, 'default');
            cats = {'Brain','Muscle','Eye','Heart','Line Noise','Channel Noise','Other'};
            classes = cellstr(p.classes);
            assert(all(ismember(classes, cats)) && ~ismember('Brain', classes), 'PipeCompare:ICLabel', ...
                'classes must be ICLabel artifact classes: %s', strjoin(cats(2:end), ', '));
            T = nan(7, 2);
            T(ismember(cats, classes), :) = repmat([p.threshold 1], sum(ismember(cats, classes)), 1);
            [EEG, c2] = pop_icflag(EEG, T);
            comps = find(EEG.reject.gcompreject(:)');
            info.icsTotal = size(EEG.icaweights, 1);
            info.icsRemoved = numel(comps);
            info.comps = comps;
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
                    marks = EEG.reject.rejthresh; E = pipecompare.utils.fieldOr(EEG.reject, 'rejthreshE');
                case 'reject_jointprob'
                    [EEG, ~, ~, ~, c1] = pop_jointprob(EEG, 1, chans, p.sd, p.sd, 0, 0, 0, [], 0);
                    marks = EEG.reject.rejjp; E = pipecompare.utils.fieldOr(EEG.reject, 'rejjpE');
                case 'reject_kurtosis'
                    [EEG, ~, ~, ~, c1] = pop_rejkurt(EEG, 1, chans, p.sd, p.sd, 0, 0, 0, [], 0);
                    marks = EEG.reject.rejkurt; E = pipecompare.utils.fieldOr(EEG.reject, 'rejkurtE');
            end
            idx = find(marks);
            % which channels drive the rejections (a hint for bad channels)
            info.topChannels = '';
            if ~isempty(E) && size(E, 1) == EEG.nbchan && ~isempty(idx)
                [cnt, order] = sort(sum(E(:, idx) ~= 0, 2), 'descend');
                keep = order(cnt > 0); keep = keep(1:min(5, numel(keep)));
                info.topChannels = strjoin(arrayfun(@(c) sprintf('%s (%d)', EEG.chanlocs(c).labels, ...
                    sum(E(c, idx) ~= 0)), keep(:)', 'UniformOutput', false), ', ');
                pipecompare.utils.log('%d/%d epochs rejected; channels most often over the limit: %s', ...
                    numel(idx), n0, info.topChannels);
            end
            coms = {c1};
            if ~isempty(idx)
                assert(numel(idx) < n0, 'PipeCompare:AllRejected', 'every epoch would be rejected');
                [EEG, c2] = pop_rejepoch(EEG, idx, 0);
                coms{end+1} = c2;
            end
            info.rejected = numel(idx); info.rejIdx = idx;
        end

        function [EEG, coms, info] = native(EEG, command)
            % Replay a command captured from an EEGLAB dialog, statement by
            % statement, in an isolated workspace that only contains EEG.
            % When a native step only marks and removes (a captured
            % workflow), the removals it took on these data are recorded
            % (info.decisions) so the signal check can apply the same
            % removals instead of re-deciding on its own copy.
            st = pipecompare.run.Native.statements(command);
            coms = cell(1, numel(st));
            info = struct('decisions', struct('kind', {}, 'idx', {}), 'rejected', 0, 'icsRemoved', 0);
            decided = true;
            for k = 1:numel(st)
                cmd = st{k};
                assert(isempty(regexp(cmd, '\<(ALLEEG|CURRENTSET|STUDY|CURRENTSTUDY)\>', 'once')), ...
                    'PipeCompare:Native', 'The command refers to other datasets (ALLEEG/STUDY); it cannot be replayed on candidates.');
                % Display-only options must not open windows during a search.
                cmd = regexprep(cmd, '''plotfreqz''\s*,\s*1', '''plotfreqz'',0');
                cmd = regexprep(cmd, '''interrupt''\s*,\s*''on''', '''interrupt'',''off''');
                e = pipecompare.live.History.classify(cmd);
                if strcmp(e.step, 'reject_epochs') && EEG.trials > 1
                    n0 = EEG.trials; gone = []; known = false;
                    if strcmp(e.fn, 'pop_rejepoch') && numel(e.args) >= 2
                        % the epochs it removes, read before it runs
                        v = evalExprWithEEG(EEG, e.args{2});
                        if islogical(v) || (numel(v) == n0 && all(ismember(v(:), [0 1]))), gone = find(v(:)');
                        else, gone = unique(double(v(:)')); end
                        known = true;
                        EEG = evalWithEEG(EEG, cmd);
                    elseif all(ismember(1:n0, unique([EEG.event.epoch])))
                        % other removals: every epoch carries an event, so the
                        % surviving events tell which epochs are left
                        for q = 1:numel(EEG.event), EEG.event(q).nqc_epoch = EEG.event(q).epoch; end
                        EEG = evalWithEEG(EEG, cmd);
                        if isfield(EEG.event, 'nqc_epoch')
                            gone = setdiff(1:n0, unique(arrayfun(@(x) double(x.nqc_epoch), EEG.event)));
                            EEG.event = rmfield(EEG.event, 'nqc_epoch'); known = true;
                        end
                    else
                        EEG = evalWithEEG(EEG, cmd);   % an epoch without events: cannot be told apart
                    end
                    assert(EEG.trials > 0, 'PipeCompare:AllRejected', 'every epoch would be rejected');
                    if known && EEG.trials == n0 - numel(gone)
                        info.decisions(end+1) = struct('kind', 'epochs', 'idx', gone);
                    else
                        decided = false;               % re-run on the signal copy, flagged
                    end
                    info.rejected = info.rejected + (n0 - EEG.trials);
                elseif strcmp(e.fn, 'pop_subcomp') && ~isempty(EEG.icaweights)
                    W0 = EEG.icaweights;
                    EEG = evalWithEEG(EEG, cmd);
                    gone = find(~ismember(W0, EEG.icaweights, 'rows'))';
                    info.decisions(end+1) = struct('kind', 'comps', 'idx', gone);
                    info.icsRemoved = info.icsRemoved + numel(gone);
                else
                    if ~strcmp(e.kind, 'mark'), decided = false; end
                    EEG = evalWithEEG(EEG, cmd);
                end
                coms{k} = cmd;
            end
            if ~decided, info.decisions = info.decisions([]); end   % not only marks and removals: re-run instead
        end
    end
end

function EEG = evalWithEEG(EEG, PIPECOMPARE_CMD__)
eval(PIPECOMPARE_CMD__);
end

function v = evalExprWithEEG(EEG, PIPECOMPARE_EXPR__) %#ok<INUSL>
% value of an argument expression of a captured command (e.g.
% EEG.reject.rejthresh), in a workspace that only contains EEG
v = eval(PIPECOMPARE_EXPR__);
end

function tf = isFixedTransform(stmt)
% EEGLAB calls whose effect does not depend on the data values (filters,
% resampling, re-referencing, baseline, epoching, channel selection or
% interpolation by explicit lists): re-running them on another dataset
% applies exactly the same operation.
e = pipecompare.live.History.classify(stmt);
% Filters are linear time-invariant operators fixed by their design
% parameters (Widmann, Schroger & Maess, 2015); selections by events or
% channel lists depend on the events, which the signal copy shares.
tf = any(strcmp(e.fn, {'pop_eegfiltnew','pop_firws','pop_firma','pop_firpm','pop_eegfilt','pop_basicfilter', ...
    'pop_resample','pop_reref','pop_rmbase','pop_epoch','pop_select','pop_selectevent','pop_rmdat', ...
    'pop_interp','pop_chanedit'}));
end

function L = presentChannels(EEG, wanted, what)
% The listed channels that are still in the data. A channel of the
% starting montage that an earlier step removed is skipped (nothing left
% to exclude); a label that never existed is an error (a typo).
wanted = cellstr(wanted);
here = ismember(lower(wanted), lower({EEG.chanlocs.labels}));
known = {EEG.chanlocs.labels};
if isfield(EEG, 'etc') && isstruct(EEG.etc) && isfield(EEG.etc, 'pipecompare') && isfield(EEG.etc.pipecompare, 'rootChanlocs')
    known = [known {EEG.etc.pipecompare.rootChanlocs.labels}];
end
unknown = wanted(~ismember(lower(wanted), lower(known)));
assert(isempty(unknown), 'PipeCompare:Channels', '%s: channel(s) not in the dataset: %s', what, strjoin(unknown, ', '));
if any(~here)
    pipecompare.utils.log('%s: %s already removed by an earlier step; nothing to exclude there.', what, strjoin(wanted(~here), ', '));
end
L = wanted(here);
end

function rec = recordAsr(E0, E1, cutoff)
% ASR's decisions on these data, kept only if replaying them reproduces
% EEGLAB's own output (otherwise the signal check re-runs ASR, flagged).
rec = [];
try
    r = pipecompare.run.AsrRecord.record(E0, cutoff);
    Y = pipecompare.run.AsrRecord.apply(r, E0.data);
    err = max(abs(Y(:) - double(E1.data(:)))) / max(1, max(abs(double(E1.data(:)))));
    if isequal(size(Y), size(E1.data)) && err < 1e-6
        rec = r;
    else
        pipecompare.utils.log('ASR decisions not reproduced exactly (relative difference %.2g); the signal check re-runs ASR.', err);
    end
catch ME
    pipecompare.utils.log('ASR decisions not recorded (%s); the signal check re-runs ASR.', ME.message);
end
end

function requireLocations(locs, what)
% The channels to interpolate must have positions: EEGLAB's eeg_interp
% leaves a channel without one as it was, silently, while the step would
% report it interpolated.
ok = @(v) isnumeric(v) && isscalar(v) && isfinite(v);
has = arrayfun(@(c) isfield(c, 'X') && ok(c.X) && ok(c.Y) && ok(c.Z), locs);
assert(all(has), 'PipeCompare:Chanlocs', ['%s: no channel location for %s, so it cannot be interpolated ', ...
    '(Edit > Channel locations, or exclude/remove it).'], what, strjoin({locs(~has).labels}, ', '));
end

function target = rootChanlocs(EEG)
assert(isfield(EEG, 'etc') && isfield(EEG.etc, 'pipecompare') && isfield(EEG.etc.pipecompare, 'rootChanlocs'), ...
    'PipeCompare:Restore', 'Root channel montage not recorded');
target = EEG.etc.pipecompare.rootChanlocs;
end
