classdef Executor
    %EXECUTOR Run every legal pipeline of a plan on the current EEGLAB dataset.
    %
    %   result = neuroqc.run.Executor.run(plan, contract, opts)
    %   result = neuroqc.run.Executor.resume(checkpointDir)
    %
    %   - Reads the dataset that is current in EEGLAB (no loading step),
    %     prints its state and parsed EEG.history. The live dataset is never
    %     modified: everything runs on NeuroQC's own copy ("root").
    %   - Enumerates the legal pipelines (exhaustive, or explicitly
    %     never truncated or sampled) as a prefix tree and runs it depth first, so pipelines
    %     that share their first steps share that work.
    %   - Each EEGLAB command is printed and appended to the candidate's
    %     EEG.history.
    %   - Scores each finished pipeline (neuroqc.eval.Measure), checks that
    %     the signal survives (neuroqc.eval.Injection) and
    %     ranks (neuroqc.eval.Rank).
    %
    %   opts (all optional; see also neuroqc.eval.Rank.defaults):
    %     maxLeaves     refuse above this many pipelines (default 500)
    %     injectUv      injected amplitude (default 5 uV)
    %     dataUnit      'uV' (default) | 'V' (scaled to uV on the copy)
    %     checkpoint    folder: every finished candidate is saved there and
    %                   the search can be resumed with Executor.resume
    %     parallel      true: independent subtrees run on a parallel pool
    %     verbose       'normal' (commands, warnings, results) | 'full'
    %                   (everything EEGLAB prints)
    %     dryRun        enumerate and report, run nothing

    methods (Static)
        function result = run(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            opts = neuroqc.utils.withDefaults(opts, struct('dryRun', false, 'injectUv', 5, ...
                'dataUnit', 'uV', 'checkpoint', '', 'parallel', false, 'verbose', 'normal'));
            [EEG, live] = neuroqc.live.Session.current();
            assert(~isempty(EEG), 'NeuroQC:NoDataset', 'No dataset is loaded in EEGLAB.');
            if ~live.stored
                neuroqc.utils.log('WARNING: base EEG differs from ALLEEG(CURRENTSET) (changed but not stored); using base EEG.');
            end
            state = neuroqc.live.DataState.fromEEG(EEG);
            neuroqc.live.DataState.print(state);
            contract.validate(state);
            plan.print();
            [leaves, tree, rep] = plan.enumerate(state, contract, opts);
            neuroqc.run.Executor.printReport(rep);
            labels = arrayfun(@(l) l.key, leaves, 'UniformOutput', false);
            result = struct('plan', plan, 'contract', contract, 'options', opts, 'state', state, ...
                'rootFingerprint', live.fingerprint, 'leaves', leaves, 'tree', tree, 'report', rep, ...
                'labels', {labels}, 'cands', [], 'ranking', [], 'marginal', [], 'robustness', [], 'root', [], 'ref', [], ...
                'rootComs', {{}}, 'versions', versions(), 'identity', '');
            if opts.dryRun, return; end
            [root, rootComs] = neuroqc.run.Executor.prepareRoot(EEG, contract, opts);
            result.root = root; result.rootComs = rootComs;
            result = neuroqc.run.Executor.execute(result, false(numel(leaves), 1));
        end

        function result = resume(dirName)
            % Continue an interrupted search from its checkpoint folder.
            M = load(fullfile(dirName, 'manifest.mat'));
            R = load(fullfile(dirName, 'root.mat'));
            assert(isfield(M, 'identity') && isfield(R, 'identity') && strcmp(M.identity, R.identity), ...
                'NeuroQC:Checkpoint', ['%s: the starting dataset (root.mat) and the search description ', ...
                '(manifest.mat) do not belong to the same search (or were written by an older NeuroQC).'], dirName);
            result = M.result; result.root = R.root;
            result.identity = M.identity;
            w = what(dirName); result.options.checkpoint = w(1).path;   % absolute, as writeManifest stores it
            assert(strcmp(searchIdentity(result), M.identity), 'NeuroQC:Checkpoint', ...
                '%s: the stored starting dataset no longer matches the search identity.', dirName);
            v = versions();
            if ~isequal(v.eeglab, result.versions.eeglab) || ~isequal(v.matlab, result.versions.matlab)
                neuroqc.utils.log('WARNING: software versions differ from the interrupted run (%s / %s now, %s / %s then).', ...
                    v.matlab, v.eeglab, result.versions.matlab, result.versions.eeglab);
            end
            done = false(numel(result.leaves), 1);
            files = dir(fullfile(dirName, 'leaf_*.mat'));
            prev = repmat(emptyCand(), numel(result.leaves), 1);
            for f = 1:numel(files)
                d = load(fullfile(dirName, files(f).name));
                assert(isfield(d, 'identity') && strcmp(d.identity, M.identity) && d.id <= numel(result.leaves) && ...
                    strcmp(d.key, result.leaves(d.id).key), 'NeuroQC:Checkpoint', ...
                    'Checkpoint file %s does not belong to this search.', files(f).name);
                prev(d.id) = d.cand; done(d.id) = true;
            end
            neuroqc.utils.log('Resuming: %d of %d candidates already evaluated.', sum(done), numel(done));
            result.prevCands = prev;
            if isfield(result.options, 'stopAfter'), result.options = rmfield(result.options, 'stopAfter'); end
            result = neuroqc.run.Executor.execute(result, done);
        end

        function result = execute(result, done)
            opts = result.options; contract = result.contract; leaves = result.leaves; tree = result.tree;
            root = result.root;
            ref = neuroqc.eval.Measure.reference(root, contract);
            result.ref = ref;
            neuroqc.utils.log('Reference trials per condition: %s', ...
                strjoin(arrayfun(@(c) sprintf('%s=%d', ref.names{c}, ref.n(c)), 1:numel(ref.n), 'UniformOutput', false), ', '));
            env = struct('tree', tree, 'leaves', leaves, 'contract', contract, 'ref', ref, 'opts', opts, ...
                'nbchan', root.nbchan + numel(neuroqc.utils.fieldOr(root.etc.neuroqc, 'preRemoved', [])), 'done', done, 'checkpoint', opts.checkpoint, 'tStart', tic, ...
                'truth', [], 'identity', '');
            % signal check: a copy holding only a known signal goes through every
            % candidate with the same operations and decisions as the real data
            [S, env.truth] = neuroqc.eval.Injection.prepare(root, contract, ref, opts);
            neuroqc.utils.log(['Signal check: a known %g uV signal is carried through every candidate with the ', ...
                'same decisions (matched-decision injection).'], opts.injectUv);
            % depth-first execution holds the data and the signal copy once per
            % level of the current branch (the price of sharing prefixes)
            % (a level after a resample step holds data smaller by fs_new/fs)
            b = whos('root'); gb = b.bytes / 2^30;
            levels = max([1 arrayfun(@(l) dataLevels(l.path, root.srate), leaves)]);
            if gb * 2 * levels > 2
                neuroqc.utils.log(['Memory: up to about %.1f GB (%.2f GB of starting data, 2 copies, %.1f data-sized ', ...
                    'levels on the deepest branch). Resampling early in the plan reduces it.'], gb * 2 * levels, gb, levels);
            end
            if ~isempty(opts.checkpoint) && ~any(done)
                result = neuroqc.run.Executor.writeManifest(result);
                env.identity = result.identity; env.checkpoint = result.options.checkpoint;
            elseif isfield(result, 'identity')
                env.identity = result.identity;
            end
            ctx0 = struct('contract', contract, 'highpass', rootHighpass(result.state));
            acc0 = struct('interpolated', {{}}, 'icsRemoved', 0, 'rejected', 0, 'coms', {{}}, 'seconds', 0, 'unmatched', {{}});
            % pipelines with no step at all (every slot chose 'none') are the starting copy itself
            pre = repmat(emptyCand(), 0, 1);
            for li = tree(1).leaves
                if done(li), continue; end
                c = evaluateLeaf(env, li, root, S, acc0); pre(end+1, 1) = c; saveLeaf(env, c); %#ok<AGROW>
            end
            if opts.parallel && canParallel()
                cands = neuroqc.run.Executor.runParallel(env, root, S, ctx0, acc0);
            else
                if opts.parallel, neuroqc.utils.log('Parallel evaluation unavailable (Parallel Computing Toolbox/pool); running serially.'); end
                cands = neuroqc.run.Executor.runSubtree(env, 1, root, S, ctx0, acc0);
            end
            cands = [pre; cands];
            allc = repmat(emptyCand(), numel(leaves), 1);
            if isfield(result, 'prevCands'), allc = result.prevCands; result = rmfield(result, 'prevCands'); end
            for k = 1:numel(cands), allc(cands(k).id) = cands(k); end
            result.cands = allc;
            R = neuroqc.eval.Rank.run(allc, ref, opts);
            result.ranking = R;
            result.marginal = neuroqc.eval.Rank.marginal(R, leaves, result.report.searched);
            result.robustness = neuroqc.eval.Rank.robustness(allc, R, leaves, result.report.searched, ref);
            neuroqc.eval.Rank.print(R, result.labels);
            notes = unique([allc.unmatched]);
            if ~isempty(notes)
                neuroqc.utils.log(['Signal check note: %s step(s) were re-run rather than replayed on the injected copy; ', ...
                    'their signal effect is measured but not decision-matched.'], strjoin(notes, ', '));
            end
            if ~isempty(result.marginal) && height(result.marginal) > 0
                neuroqc.utils.log('Effect of each searched choice (medians over evaluated candidates; best among feasible):');
                disp(result.marginal);
            end
            if ~isempty(result.robustness) && height(result.robustness) > 0
                neuroqc.utils.log(['Multiverse summary: each measure over the feasible pipelines, and the searched ', ...
                    'choice that accounts for most of its spread (share = eta^2). Sensitivity only; not used for the ranking.']);
                disp(result.robustness);
            end
            neuroqc.utils.log('Finished in %.1f s.', toc(env.tStart));
        end

        function out = runSubtree(env, node, E, S, ctx, acc)
            % Depth-first execution of the subtree below node. Returns one
            % record per evaluated leaf. No shared state: safe for parfor.
            out = repmat(emptyCand(), 0, 1);
            tree = env.tree;
            for child = tree(node).children
                under = leavesUnder(tree, child);
                if all(env.done(under)), continue; end
                in = tree(child).inst;
                t0 = tic;
                try
                    neuroqc.utils.log('step %s', in.label);
                    [E2, coms, info] = runStep(in, E, ctx, env.opts.verbose);
                    for q = 1:numel(coms)
                        fprintf('    %s\n', coms{q});
                        E2 = eeg_hist(E2, coms{q});
                    end
                    S2 = []; unmatched = {};
                    if ~isempty(S)
                        [~, S2, matched] = evalc('neuroqc.run.Steps.replayDecision(in, S, info, ctx)');
                        if ~matched, unmatched = {in.type}; end
                    end
                catch ME
                    out = [out; failUnder(env, under, in, ME)]; %#ok<AGROW>
                    continue;
                end
                [ctx2, acc2] = advance(in, ctx, acc, info, coms, unmatched, toc(t0));
                for li = tree(child).leaves
                    if env.done(li), continue; end
                    c = evaluateLeaf(env, li, E2, S2, acc2);
                    out(end+1, 1) = c; %#ok<AGROW>
                    saveLeaf(env, c);
                end
                out = [out; neuroqc.run.Executor.runSubtree(env, child, E2, S2, ctx2, acc2)]; %#ok<AGROW>
            end
        end

        function out = runParallel(env, root, S, ctx, acc)
            % Run the shared single-path trunk serially, then the independent
            % subtrees below it on pool workers. Each worker receives its
            % own copies of the datasets (MATLAB value semantics), so no
            % candidate can see another candidate's data.
            tree = env.tree; node = 1; E = root;
            out = repmat(emptyCand(), 0, 1);
            while isscalar(tree(node).children)
                child = tree(node).children;
                in = tree(child).inst;
                neuroqc.utils.log('step %s (shared trunk)', in.label);
                t0 = tic;
                try
                    [E, coms, info] = runStep(in, E, ctx, env.opts.verbose);
                    for q = 1:numel(coms), fprintf('    %s\n', coms{q}); E = eeg_hist(E, coms{q}); end
                    unmatched = {};
                    if ~isempty(S)
                        [~, S, matched] = evalc('neuroqc.run.Steps.replayDecision(in, S, info, ctx)');
                        if ~matched, unmatched = {in.type}; end
                    end
                catch ME   % same handling as runSubtree: the candidates below fail, the search goes on
                    out = [out; failUnder(env, leavesUnder(tree, child), in, ME)];
                    return;
                end
                [ctx, acc] = advance(in, ctx, acc, info, coms, unmatched, toc(t0));
                for li = tree(child).leaves
                    if env.done(li), continue; end
                    c = evaluateLeaf(env, li, E, S, acc); out(end+1, 1) = c; saveLeaf(env, c); %#ok<AGROW>
                end
                node = child;
            end
            kids = tree(node).children;
            if isempty(kids), return; end
            neuroqc.utils.log('Parallel: %d independent subtrees on the pool.', numel(kids));
            parts = cell(1, numel(kids));
            parfor k = 1:numel(kids)
                sub = env;
                sub.tree(node).children = kids(k);
                parts{k} = neuroqc.run.Executor.runSubtree(sub, node, E, S, ctx, acc);
            end
            out = [out; vertcat(parts{:})];
        end

        function [root, coms] = prepareRoot(EEG, contract, opts)
            % NeuroQC's own copy of the live dataset; the original is untouched.
            if nargin < 3, opts = struct('dataUnit', 'uV'); end
            root = EEG; coms = {};
            function add(c), root = eeg_hist(root, c); coms{end+1} = c; end
            if isfield(opts, 'dataUnit') && strcmp(opts.dataUnit, 'V')
                % the script line does exactly what is done here (ICA weights
                % too, so existing activations keep their scale)
                cmd = ['EEG.data = EEG.data * 1e6; if ~isempty(EEG.icaweights), EEG.icaweights = EEG.icaweights / 1e6; ', ...
                    'EEG.icawinv = []; EEG.icaact = []; end; EEG = eeg_checkset(EEG); % NeuroQC: volts -> microvolts'];
                root = evalWithEEG(root, cmd);
                add(cmd);
            end
            r = round(root.srate);
            if root.srate ~= r && abs(root.srate - r) <= 1e-9 * r
                neuroqc.utils.log('EEG.srate is %.17g (floating-point residue); using %d on NeuroQC''s copy.', root.srate, r);
                root.srate = r; root = eeg_checkset(root);
                add(sprintf('EEG.srate = %d; EEG = eeg_checkset(EEG); %% NeuroQC: exact sampling rate', r));
            end
            if ~isfield(root, 'urevent') || isempty(root.urevent)
                root = eeg_checkset(root, 'makeur');
                add('EEG = eeg_checkset(EEG, ''makeur''); % NeuroQC: trial identities');
            end
            if contract.isSegmented() && root.trials == 1
                % consecutive analysis segments, marked with EEGLAB's own function
                % (events and urevents, so each segment is paired across candidates)
                cmd = sprintf(['EEG = eeg_regepochs(EEG, ''recurrence'', %g, ''limits'', [0 %g], ''eventtype'', ''%s'', ', ...
                    '''extractepochs'', ''off''); %% NeuroQC: %g s analysis segments'], contract.segment, contract.segment, ...
                    neuroqc.eval.Contract.SegmentEvent, contract.segment);
                [~, root] = evalc('evalWithEEG(root, cmd)');
                add(cmd);
            end
            % a trial list left in the dataset by an earlier search (e.g. an
            % adopted candidate) must never restrict this one
            if isfield(root, 'etc') && isstruct(root.etc) && isfield(root.etc, 'neuroqc') && isfield(root.etc.neuroqc, 'eligibleUrevents')
                root.etc.neuroqc = rmfield(root.etc.neuroqc, 'eligibleUrevents');
                add('EEG.etc.neuroqc = rmfield(EEG.etc.neuroqc, ''eligibleUrevents''); % NeuroQC: drop an earlier trial rule');
            end
            elig = eligibleTrials(root, contract);
            if ~isempty(elig)
                root.etc.neuroqc.eligibleUrevents = elig;
                add(sprintf('EEG.etc.neuroqc.eligibleUrevents = %s; %% NeuroQC: trial rule %s (urevent ids)', ...
                    mat2str(elig(:)'), contract.trials.mode));
                neuroqc.utils.log('Trial rule %s: %d eligible time-locking events.', contract.trials.mode, numel(elig));
            end
            root.etc.neuroqc.rootChanlocs = root.chanlocs;
            add('EEG.etc.neuroqc.rootChanlocs = EEG.chanlocs; % NeuroQC: montage before the plan');
            pre = neuroqc.live.DataState.fromEEG(root).restorableChannels;
            if ~isempty(pre)
                root.etc.neuroqc.preRemoved = root.chaninfo.removedchans(pre);
                add(sprintf(['EEG.etc.neuroqc.preRemoved = EEG.chaninfo.removedchans(%s); ', ...
                    '%% NeuroQC: channels removed before the plan, restorable by interpolation'], mat2str(pre)));
                neuroqc.utils.log('Channels removed before NeuroQC that a restore step can interpolate: %s', ...
                    strjoin({root.etc.neuroqc.preRemoved.labels}, ', '));
            end
        end

        function root = rootOf(result)
            % The starting dataset of a search. With a checkpoint folder it
            % is not kept in the result (long searches start from large
            % data); it is read back from root.mat, checked against the
            % search identity.
            root = result.root;
            if ~isempty(root), return; end
            d = '';
            if isfield(result.options, 'checkpoint'), d = result.options.checkpoint; end
            f = fullfile(d, 'root.mat');
            assert(~isempty(d) && isfile(f), 'NeuroQC:Checkpoint', ['The starting dataset of this result is not in ', ...
                'memory and its checkpoint file %s is missing.'], f);
            R = load(f);
            assert(isfield(R, 'identity') && isfield(result, 'identity') && strcmp(R.identity, result.identity), ...
                'NeuroQC:Checkpoint', '%s belongs to another search; the starting dataset cannot be restored.', f);
            root = R.root;
        end

        function EEG = replay(result, idx, recordGlobal)
            % Re-run candidate idx from the stored starting dataset.
            if nargin < 3, recordGlobal = false; end
            EEG = neuroqc.run.Executor.rootOf(result);
            path = result.leaves(idx).path;
            ctx = struct('contract', result.contract, 'highpass', rootHighpass(result.state));
            if recordGlobal
                for q = 1:numel(result.rootComs), eegh(result.rootComs{q}); end
            end
            for k = 1:numel(path)
                in = path{k};
                neuroqc.utils.log('step %s', in.label);
                [EEG, coms] = runStep(in, EEG, ctx, result.options.verbose);
                for q = 1:numel(coms)
                    fprintf('    %s\n', coms{q});
                    % eeg_hist always appends; eegh(com, EEG) would skip a command equal to
                    % the previous session command, losing it from the dataset history
                    EEG = eeg_hist(EEG, coms{q});
                    if recordGlobal, eegh(coms{q}); end
                end
                ctx = advance(in, ctx, [], struct(), coms, {}, 0);
            end
            [EEG, com] = neuroqc.run.Executor.selectEligible(EEG, result.contract);
            if ~isempty(com)
                fprintf('    %s\n', com);
                EEG = eeg_hist(EEG, com);
                if recordGlobal, eegh(com); end
            end
        end

        function [elig, EEG] = eligibleUrevents(EEG, contract)
            % urevent ids the contract's trial rule keeps ([] = all trials),
            % for display before a search (EEG is a copy; urevents are
            % built the same way the search builds them).
            if ~isfield(EEG, 'urevent') || isempty(EEG.urevent)
                [~, EEG] = evalc('eeg_checkset(EEG, ''makeur'')');
            end
            elig = eligibleTrials(EEG, contract);
        end

        function [EEG, com] = selectEligible(EEG, contract)
            % Output only the trials the trial rule keeps. The rule decides
            % which trials are scored; the data a candidate hands on must
            % hold the same trials. Epochs time-locked to a condition event
            % outside the rule are removed (pop_select, in EEG.history).
            com = '';
            if ~isfield(EEG, 'etc') || ~isstruct(EEG.etc) || ~isfield(EEG.etc, 'neuroqc') || ...
                    ~isfield(EEG.etc.neuroqc, 'eligibleUrevents')
                return;
            end
            if EEG.trials == 1 && (~isfield(EEG, 'epoch') || isempty(EEG.epoch))
                neuroqc.utils.log(['Trial rule: the output is continuous, so it still holds every trial; the ', ...
                    'eligible urevent ids are kept in EEG.etc.neuroqc.eligibleUrevents for later epoching.']);
                return;
            end
            elig = EEG.etc.neuroqc.eligibleUrevents;
            lock = neuroqc.eval.Measure.lockingEvents(EEG, contract.allEvents());
            drop = false(1, EEG.trials);
            for k = find(lock > 0)
                drop(k) = ~ismember(double(EEG.event(lock(k)).urevent), elig);
            end
            if ~any(drop), return; end
            assert(~all(drop), 'NeuroQC:TrialRule', 'The trial rule keeps none of the output epochs.');
            [EEG, com] = pop_select(EEG, 'notrial', find(drop));
            com = sprintf('%s %% NeuroQC: keep only trials of the trial rule (%d removed)', com, sum(drop));
        end

        function idx = pickCandidate(result, idx)
            % idx, or the recommended candidate when idx is empty. With
            % several strata there is no single recommendation, and with no
            % feasible candidate there is none at all: both are errors that
            % name what to do (adopt, script and writeScript share this).
            if ~isempty(idx), return; end
            idx = result.ranking.recommended;
            if isempty(idx) && numel(result.ranking.byStratum) > 1
                error('NeuroQC:Adopt', ['The candidates fall into %d strata (different references) that are not ', ...
                    'comparable; choose one: pass the id of a stratum''s recommendation %s.'], ...
                    numel(result.ranking.byStratum), mat2str([result.ranking.byStratum.recommended]));
            end
            assert(~isempty(idx), 'NeuroQC:Adopt', ['No recommended candidate: none satisfies the constraints. ', ...
                'Pass a candidate id explicitly.']);
        end

        function id = identity(result)
            % The checkpoint identity of a search (see searchIdentity).
            id = searchIdentity(result);
        end

        function adopt(result, idx, force)
            % Store candidate idx as a NEW EEGLAB dataset with its full history.
            if nargin < 2, idx = []; end
            if nargin < 3, force = false; end
            idx = neuroqc.run.Executor.pickCandidate(result, idx);
            st = result.ranking.table.status{idx};
            if ~strcmp(st, 'feasible')
                why = result.ranking.table.reason{idx};
                assert(force, 'NeuroQC:Adopt', ['Candidate %d is %s, not feasible: %s. Call adopt(result, %d, true) ', ...
                    'to adopt it anyway.'], idx, st, why, idx);
                neuroqc.utils.log('WARNING: adopting candidate %d although it is %s: %s', idx, st, why);
            end
            [cur, ~] = neuroqc.live.Session.current();
            here = strcmp(neuroqc.live.Session.fingerprint(cur), result.rootFingerprint);
            if ~here && ~force
                inAll = false;
                if evalin('base', 'exist(''ALLEEG'',''var'')')
                    A = evalin('base', 'ALLEEG');
                    for k = 1:numel(A)
                        if strcmp(neuroqc.live.Session.fingerprint(A(k)), result.rootFingerprint), inAll = true; break; end
                    end
                end
                assert(inAll, 'NeuroQC:StaleState', ['The dataset this search started from is no longer in EEGLAB ', ...
                    '(it was changed or removed). Re-run the search, or call adopt(result, id, true) to build the ', ...
                    'candidate from the stored starting copy anyway.']);
                neuroqc.utils.log('The current dataset is not the search''s starting dataset; the candidate is built from that starting dataset.');
            end
            neuroqc.utils.log('Rebuilding candidate %d: %s', idx, result.labels{idx});
            EEG = neuroqc.run.Executor.replay(result, idx, true);
            if strcmp(result.cands(idx).status, 'ok')
                m = neuroqc.eval.Measure.candidate(EEG, result.contract, result.ref, result.options);
                a = [m.objectives.agg]; b = [result.cands(idx).m.objectives.agg];
                same = all(abs(a - b) <= 1e-6 * max(1, abs(b))) && isequal(m.kept, result.cands(idx).m.kept);
                neuroqc.utils.log('Replay check: objectives %s, trials %s (search: %s, %s) -> %s', mat2str(a, 5), ...
                    mat2str(m.kept), mat2str(b, 5), mat2str(result.cands(idx).m.kept), ...
                    neuroqc.utils.ternary(same, 'identical', 'DIFFERENT (non-deterministic step?)'));
                % the evaluation (and the constraints it passed) belongs to the
                % searched data; a rebuilt dataset that differs is not that candidate
                assert(same || force, 'NeuroQC:ReplayMismatch', ['The rebuilt candidate %d differs from the one ', ...
                    'evaluated in the search, so its evaluation does not apply to it. Nothing was stored. Call ', ...
                    'adopt(result, %d, true) to store it anyway.'], idx, idx);
                if ~same, neuroqc.utils.log('WARNING: storing a rebuilt candidate that differs from the evaluated one.'); end
            end
            EEG.setname = sprintf('%s NeuroQC#%d', result.state.setname, idx);
            assignin('base', 'NEUROQC_ADOPT__', EEG);
            evalin('base', ['[ALLEEG, EEG, CURRENTSET] = pop_newset(ALLEEG, NEUROQC_ADOPT__, CURRENTSET, ', ...
                '''gui'', ''off''); clear NEUROQC_ADOPT__; eeglab redraw;']);
            neuroqc.utils.log('Candidate %d stored as a new EEGLAB dataset; its EEG.history lists every step.', idx);
        end

        function result = writeManifest(result)
            % Bind the checkpoint folder to this search. A folder holding
            % files of another search (other data, contract, plan or
            % options) is refused rather than mixed.
            d = result.options.checkpoint;
            if ~isfolder(d), mkdir(d); end
            w = what(d); d = w(1).path;        % absolute (from MATLAB's current folder): found from any folder later
            result.options.checkpoint = d;
            identity = searchIdentity(result);
            result.identity = identity;
            used = ~isempty(dir(fullfile(d, '*.mat')));
            if used
                prev = '';
                if isfile(fullfile(d, 'manifest.mat'))
                    M = load(fullfile(d, 'manifest.mat'), 'identity');
                    if isfield(M, 'identity'), prev = M.identity; end
                end
                assert(strcmp(prev, identity), 'NeuroQC:Checkpoint', ['Checkpoint folder %s already holds files ', ...
                    'of a different search (other data, contract, plan or options). Use an empty folder, or ', ...
                    'neuroqc.NeuroQC.resume(folder) to continue that search.'], d);
                % same search started again: earlier candidates are discarded, not mixed
                delete(fullfile(d, 'leaf_*.mat'));
            end
            root = result.root; %#ok<NASGU>
            save(fullfile(d, 'root.mat'), 'root', 'identity', '-v7.3');
            result.root = [];          % read back on demand (Executor.rootOf)
            save(fullfile(d, 'manifest.mat'), 'result', 'identity', '-v7.3');
            neuroqc.utils.log('Checkpoint folder: %s (resume with neuroqc.NeuroQC.resume).', d);
        end

        function printReport(rep)
            neuroqc.utils.log('Exhaustive search: %d legal pipeline(s) from %d order(s).', rep.nLeaves, rep.nOrders);
            neuroqc.utils.log('%d step executions with prefix sharing (%d without).', rep.nNodes, rep.nStepsUnshared);
            for k = 1:numel(rep.rejected)
                neuroqc.utils.log('  excluded combinations: %s (x%d)', rep.rejected(k).reason, rep.rejected(k).count);
            end
        end
    end
end

% ---------------------------------------------------------------------
function c = emptyCand()
% One evaluated pipeline. Every field is set here and only here; the
% producers and consumers are:
%   id, key, stratum        leaf index, pipeline key and measure-defining
%                           choices (Plan.enumerate leaves)
%   status, message         'ok' | 'rejected' (e.g. all epochs removed) |
%                           'failed', with the reason
%   m                       Measure.candidate: kept, retention, objectives
%                           (per-measure SME), composite
%   signal                  Injection.compare: source, amplitudeError,
%                           latencyShiftMs, artifactPct, waveformCorr,
%                           topoCorr, notApplicable
%   interpolatedFraction    share of the montage interpolated
%   icsRemoved, rejectedEpochs   counts from the steps' decisions
%   coms                    EEGLAB commands that rebuild it (script/adopt)
%   seconds                 run time of its steps
%   unmatched               step types re-run (not decision-matched) on
%                           the signal copy
%   notes                   facts the user must know that are not
%                           failures (e.g. epochs marked but not removed)
% Rank.run reads status, m, signal, interpolatedFraction and stratum.
c = struct('id', 0, 'key', '', 'stratum', '', 'status', 'pending', 'message', '', 'm', [], 'signal', [], ...
    'interpolatedFraction', NaN, 'icsRemoved', 0, 'rejectedEpochs', 0, 'coms', {{}}, 'seconds', 0, 'unmatched', {{}}, ...
    'notes', {{}});
end

function out = failUnder(env, under, in, ME)
% A step failed: every not yet evaluated candidate below it fails with the
% reason (the search goes on with the other branches).
neuroqc.utils.log('FAILED %s: %s (%d candidate(s) affected)', in.label, ME.message, numel(under));
out = repmat(emptyCand(), 0, 1);
for li = under
    if env.done(li), continue; end
    c = emptyCand(); c.id = li; c.key = env.leaves(li).key; c.stratum = env.leaves(li).stratum;
    c.status = failStatus(ME); c.message = sprintf('%s: %s', in.label, ME.message);
    out(end+1, 1) = c; %#ok<AGROW>
    saveLeaf(env, c);
end
end

function s = failStatus(ME)
% A step that removes every epoch is an outcome (retention 0), not an error.
if strcmp(ME.identifier, 'NeuroQC:AllRejected'), s = 'rejected'; else, s = 'failed'; end
end

function [ctx, acc] = advance(in, ctx, acc, info, coms, unmatched, secs)
% State carried to the next step. One definition for the serial search,
% the parallel trunk and replay, so all three run identical steps.
if strcmp(in.type, 'highpass'), ctx.highpass = max(ctx.highpass, in.params.cutoff); end
if strcmp(in.type, 'native')
    for stmt = neuroqc.run.Native.statements(in.params.command)
        e = neuroqc.live.History.classify(stmt{1});
        if isfield(e.params, 'locutoff') && isfinite(e.params.locutoff) && ~(isfield(e.params, 'revfilt') && e.params.revfilt)
            ctx.highpass = max(ctx.highpass, e.params.locutoff);
        end
    end
end
if isempty(acc), return; end
acc.seconds = acc.seconds + secs;
acc.coms = [acc.coms coms];
acc.unmatched = unique([acc.unmatched unmatched]);
if isfield(info, 'interpolated'), acc.interpolated = union(acc.interpolated, lower(info.interpolated)); end
if isfield(info, 'icsRemoved'), acc.icsRemoved = acc.icsRemoved + info.icsRemoved; end
if isfield(info, 'rejected'), acc.rejected = acc.rejected + info.rejected; end
end

function [E2, coms, info] = runStep(in, E, ctx, verbose)
if strcmp(verbose, 'full')
    [E2, coms, info] = neuroqc.run.Steps.run(in, E, ctx);
    return;
end
[txt, E2, coms, info] = evalc('neuroqc.run.Steps.run(in, E, ctx)');
lines = regexp(txt, '[^\n]+', 'match');
keep = lines(~cellfun(@isempty, regexpi(lines, 'warning|error|\[NeuroQC\]', 'once')));
for k = 1:numel(keep), fprintf('    %s\n', strtrim(keep{k})); end
end

function c = evaluateLeaf(env, li, E, S, acc)
c = emptyCand();
c.id = li; c.key = env.leaves(li).key; c.stratum = env.leaves(li).stratum;
c.coms = acc.coms; c.seconds = acc.seconds;
c.icsRemoved = acc.icsRemoved; c.rejectedEpochs = acc.rejected;
c.interpolatedFraction = numel(acc.interpolated) / env.nbchan;
c.unmatched = acc.unmatched;
try
    c.m = neuroqc.eval.Measure.candidate(E, env.contract, env.ref, env.opts);
    nm = markedNotRemoved(E);
    if nm > 0
        c.notes{end+1} = sprintf(['%d epoch(s) are marked for rejection (EEG.reject) but still in the data; ', ...
            'marks do not remove epochs, so they count in the scores. Remove them in the plan ', ...
            '(e.g. pop_rejepoch) if they should not count.'], nm);
    end
    [~, ~, tcom] = evalc('neuroqc.run.Executor.selectEligible(E, env.contract)');
    if ~isempty(tcom), c.coms{end+1} = tcom; end
    if ~isempty(S)
        c.signal = neuroqc.eval.Injection.compare(S, env.contract, env.truth, env.leaves(li).path);
    end
    c.status = 'ok';
catch ME
    c.status = 'failed'; c.message = ['evaluation: ' ME.message];
end
el = toc(env.tStart);
if strcmp(c.status, 'ok')
    neuroqc.utils.log('candidate %d: objectives %s, retention %s, %.0f s elapsed', li, ...
        mat2str([c.m.objectives.agg], 4), mat2str(round(100 * c.m.retention)), el);
else
    neuroqc.utils.log('candidate %d failed: %s', li, c.message);
end
end

function saveLeaf(env, cand)
if isempty(env.checkpoint), return; end
id = cand.id; key = cand.key; identity = env.identity; %#ok<NASGU>
tmp = fullfile(env.checkpoint, sprintf('leaf_%06d.tmp.mat', id));
save(tmp, 'id', 'key', 'cand', 'identity', '-v7.3');
movefile(tmp, fullfile(env.checkpoint, sprintf('leaf_%06d.mat', id)), 'f');
if isfield(env.opts, 'stopAfter') && numel(dir(fullfile(env.checkpoint, 'leaf_*.mat'))) >= env.opts.stopAfter
    % simulated interruption (tests): everything saved so far is kept
    error('NeuroQC:Interrupted', 'Search interrupted after %d candidates (opts.stopAfter).', env.opts.stopAfter);
end
end

function n = dataLevels(path, fs0)
% Copies of the data a depth-first branch holds, in units of the starting
% data (the start, then one per step; resampling shrinks what follows).
f = 1; n = 1;
for q = 1:numel(path)
    if strcmp(path{q}.type, 'resample'), f = f * path{q}.params.fs / fs0; fs0 = path{q}.params.fs; end
    n = n + f;
end
end

function n = markedNotRemoved(EEG)
% Epochs that a marking step (EEGLAB's pop_eegthresh/pop_jointprob/...,
% ERPLAB's artifact detection, which marks EEG.reject.rejmanual) flagged
% but no step removed. EEGLAB keeps marks and data apart: only
% pop_rejepoch removes epochs (Delorme & Makeig, 2004); ERPLAB's averager
% honours its own flags (Lopez-Calderon & Luck, 2014), NeuroQC's scores
% do not.
n = 0;
if EEG.trials <= 1 || ~isfield(EEG, 'reject') || ~isstruct(EEG.reject), return; end
f = {'rejmanual','rejthresh','rejconst','rejjp','rejkurt','rejfreq'};
any_ = false(1, EEG.trials);
for k = 1:numel(f)
    if isfield(EEG.reject, f{k}) && numel(EEG.reject.(f{k})) == EEG.trials
        any_ = any_ | logical(EEG.reject.(f{k})(:)');
    end
end
n = sum(any_);
end

function hp = rootHighpass(state)
hp = 0;
if ~isempty(state.filters.highpass), hp = max(state.filters.highpass); end
end

function out = leavesUnder(tree, node)
out = tree(node).leaves;
for c = tree(node).children
    out = [out leavesUnder(tree, c)]; %#ok<AGROW>
end
end

function tf = canParallel()
tf = license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel'));
if tf
    try
        p = gcp('nocreate'); if isempty(p), parpool('Processes'); end
    catch
        tf = false;
    end
end
end

function v = versions()
v = struct('matlab', version, 'eeglab', 'unknown', 'neuroqc', neuroqc.NeuroQC.Version, ...
    'iclabel', which('pop_iclabel'), 'firfilt', which('pop_eegfiltnew'));
try, v.eeglab = eeg_getversion; catch, end
end

function elig = eligibleTrials(root, contract)
% urevent ids of the time-locking events the trial rule keeps ([] = all).
elig = [];
r = contract.trials;
if strcmp(r.mode, 'all'), return; end
codes = contract.allEvents();
ev = root.event;
types = arrayfun(@(e) strtrim(char(string(e.type))), ev, 'UniformOutput', false);
isCode = ismember(types, codes);
ure = arrayfun(@(e) double(e.urevent), ev);
switch r.mode
    case 'urevents'
        keep = isCode & ismember(ure, r.ids);
    case 'time_ranges'
        t = ([ev.latency] - 1) / root.srate; keep = false(size(t));
        for k = 1:size(r.ranges, 1), keep = keep | (t >= r.ranges(k, 1) & t < r.ranges(k, 2)); end
        keep = keep & isCode;
    case 'marker_ranges'
        active = false; keep = false(size(types));
        for k = 1:numel(types)
            if strcmp(types{k}, char(string(r.startCode))), active = true;
            elseif strcmp(types{k}, char(string(r.endCode))), active = false;
            elseif isCode(k), keep(k) = active; end
        end
end
elig = unique(ure(keep));
assert(~isempty(elig), 'NeuroQC:TrialRule', 'The trial rule keeps no trials.');
end


function EEG = evalWithEEG(EEG, NEUROQC_CMD__)
% Run a script line on EEG exactly as the exported script will.
eval(NEUROQC_CMD__);
end

function id = searchIdentity(result)
% What makes two searches the same: the starting data (full content), the
% analysis contract, the enumerated pipelines and the options that change
% results. A checkpoint folder belongs to exactly one identity.
o = result.options;
o = rmfield(o, intersect(fieldnames(o), {'checkpoint','stopAfter','parallel','verbose','dryRun'}));
md = java.security.MessageDigest.getInstance('SHA-256');
root = result.root;
% the data in blocks: the same bytes as double(root.data(:)), without a
% double copy of the whole recording in memory
N = numel(root.data); step = 2^22;
for i0 = 1:step:N
    md.update(typecast(double(root.data(i0:min(N, i0 + step - 1))), 'uint8'));
end
parts = {getByteStreamFromArray(result.rootComs), getByteStreamFromArray(result.contract.toStruct()), ...
    getByteStreamFromArray(result.labels), getByteStreamFromArray(o), ...
    getByteStreamFromArray({root.chanlocs.labels}), getByteStreamFromArray(root.srate), ...
    getByteStreamFromArray(arrayfun(@(e) {char(string(e.type)), double(e.latency)}, root.event, 'UniformOutput', false))};
for k = 1:numel(parts), md.update(parts{k}); end
id = lower(reshape(dec2hex(typecast(md.digest(), 'uint8'))', 1, []));
end
