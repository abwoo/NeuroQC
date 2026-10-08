classdef Executor
    %EXECUTOR Run every legal pipeline of a plan on the current EEGLAB dataset.
    %
    %   result = pipecompare.run.Executor.run(plan, contract, opts)
    %   result = pipecompare.run.Executor.resume(checkpointDir)
    %
    %   - Reads the dataset that is current in EEGLAB (no loading step),
    %     prints its state and parsed EEG.history. The live dataset is never
    %     modified: everything runs on PipeCompare's own copy ("root").
    %   - Enumerates the legal pipelines (exhaustive, or explicitly
    %     never truncated or sampled) as a prefix tree and runs it depth first, so pipelines
    %     that share their first steps share that work.
    %   - Each EEGLAB command is printed and appended to the candidate's
    %     EEG.history.
    %   - Scores each finished pipeline (pipecompare.eval.Measure), checks that
    %     the signal survives (pipecompare.eval.Injection) and
    %     ranks (pipecompare.eval.Rank).
    %
    %   opts (all optional; see also pipecompare.eval.Rank.defaults):
    %     maxLeaves     refuse above this many pipelines (default 500)
    %     injectUv      injected amplitude (default 5 uV)
    %     dataUnit      'uV' (default) | 'V' (scaled to uV on the copy)
    %     checkpoint    folder: every finished candidate is saved there and
    %                   the search can be resumed with Executor.resume
    %     parallel      true: independent subtrees run on a parallel pool
    %     verbose       'normal' (commands, warnings, results) | 'full'
    %                   (everything EEGLAB prints)
    %     dryRun        enumerate and report, run nothing
    %     filterCheck   true (default): pipelines whose filters alone break
    %                   a signal-check limit are excluded before anything
    %                   runs (Injection.filterCheck)
    %     progress      function stop = f(n), called with the number of
    %                   candidates just evaluated (0 = only asking); when it
    %                   returns true, no further step runs and the
    %                   candidates not run are 'failed' ("not run"), so the
    %                   ranking covers the finished ones. Serial runs only.
    %                   A callback that takes two arguments is also told
    %                   each step as it starts: f(0, inst), inst being the
    %                   plan's step (type, params, label).

    methods (Static)
        function result = run(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            opts = pipecompare.utils.withDefaults(opts, struct('dryRun', false, 'injectUv', 5, 'filterCheck', true, ...
                'dataUnit', 'uV', 'checkpoint', '', 'parallel', false, 'verbose', 'normal', 'progress', []));
            [EEG, live] = pipecompare.live.Session.current();
            assert(~isempty(EEG), 'PipeCompare:NoDataset', 'No dataset is loaded in EEGLAB.');
            if ~live.stored
                pipecompare.utils.log('WARNING: base EEG differs from ALLEEG(CURRENTSET) (changed but not stored); using base EEG.');
            end
            state = pipecompare.live.DataState.fromEEG(EEG);
            pipecompare.live.DataState.print(state);
            contract.validate(state);
            plan.print();
            [leaves, tree, rep] = plan.enumerate(state, contract, opts);
            pipecompare.run.Executor.printReport(rep);
            labels = arrayfun(@(l) l.key, leaves, 'UniformOutput', false);
            result = struct('plan', plan, 'contract', contract, 'options', opts, 'state', state, ...
                'rootFingerprint', live.fingerprint, 'leaves', leaves, 'tree', tree, 'report', rep, ...
                'labels', {labels}, 'cands', [], 'ranking', [], 'marginal', [], 'robustness', [], 'root', [], 'ref', [], ...
                'rootComs', {{}}, 'versions', versions(), 'identity', '');
            if opts.dryRun, return; end
            [root, rootComs] = pipecompare.run.Executor.prepareRoot(EEG, contract, opts);
            result.root = root; result.rootComs = rootComs;
            result = pipecompare.run.Executor.execute(result, false(numel(leaves), 1));
        end

        function result = resume(dirName)
            % Continue an interrupted search from its checkpoint folder.
            M = load(fullfile(dirName, 'manifest.mat'));
            R = load(fullfile(dirName, 'root.mat'));
            assert(isfield(M, 'identity') && isfield(R, 'identity') && strcmp(M.identity, R.identity), ...
                'PipeCompare:Checkpoint', ['%s: the starting dataset (root.mat) and the search description ', ...
                '(manifest.mat) do not belong to the same search (or were written by an older PipeCompare).'], dirName);
            result = M.result; result.root = R.root;
            result.identity = M.identity;
            w = what(dirName); result.options.checkpoint = w(1).path;   % absolute, as writeManifest stores it
            assert(strcmp(searchIdentity(result), M.identity), 'PipeCompare:Checkpoint', ...
                '%s: the stored starting dataset no longer matches the search identity.', dirName);
            v = versions();
            if ~isequal(v.eeglab, result.versions.eeglab) || ~isequal(v.matlab, result.versions.matlab)
                pipecompare.utils.log('WARNING: software versions differ from the interrupted run (%s / %s now, %s / %s then).', ...
                    v.matlab, v.eeglab, result.versions.matlab, result.versions.eeglab);
            end
            done = false(numel(result.leaves), 1);
            files = dir(fullfile(dirName, 'leaf_*.mat'));
            prev = repmat(emptyCand(), numel(result.leaves), 1);
            for f = 1:numel(files)
                d = load(fullfile(dirName, files(f).name));
                assert(isfield(d, 'identity') && strcmp(d.identity, M.identity) && d.id <= numel(result.leaves) && ...
                    strcmp(d.key, result.leaves(d.id).key), 'PipeCompare:Checkpoint', ...
                    'Checkpoint file %s does not belong to this search.', files(f).name);
                c = emptyCand();   % a file from an earlier version may lack newer fields
                for n = fieldnames(d.cand)', c.(n{1}) = d.cand.(n{1}); end
                prev(d.id) = c; done(d.id) = true;
            end
            pipecompare.utils.log('Resuming: %d of %d candidates already evaluated.', sum(done), numel(done));
            result.prevCands = prev;
            if isfield(result.options, 'stopAfter'), result.options = rmfield(result.options, 'stopAfter'); end
            result = pipecompare.run.Executor.execute(result, done);
        end

        function result = execute(result, done)
            opts = result.options; contract = result.contract; leaves = result.leaves; tree = result.tree;
            root = result.root;
            ref = pipecompare.eval.Measure.reference(root, contract);
            result.ref = ref;
            pipecompare.utils.log('Reference trials per condition: %s', ...
                strjoin(arrayfun(@(c) sprintf('%s=%d', ref.names{c}, ref.n(c)), 1:numel(ref.n), 'UniformOutput', false), ', '));
            env = struct('tree', tree, 'leaves', leaves, 'contract', contract, 'ref', ref, 'opts', opts, ...
                'nbchan', root.nbchan + numel(pipecompare.utils.fieldOr(root.etc.pipecompare, 'preRemoved', [])), 'done', done, 'checkpoint', opts.checkpoint, 'tStart', tic, ...
                'truth', [], 'identity', '');
            % signal check: a copy holding only a known signal goes through every
            % candidate with the same operations and decisions as the real data
            [S, env.truth] = pipecompare.eval.Injection.prepare(root, contract, ref, opts);
            pipecompare.utils.log(['Signal check: a known %g uV signal is carried through every candidate with the ', ...
                'same decisions (matched-decision injection).'], opts.injectUv);
            % depth-first execution holds the data and the signal copy once per
            % level of the current branch (the price of sharing prefixes)
            % (a level after a resample step holds data smaller by fs_new/fs)
            b = whos('root'); gb = b.bytes / 2^30;
            levels = max([1 arrayfun(@(l) dataLevels(l.path, root.srate), leaves)]);
            if gb * 2 * levels > 2
                pipecompare.utils.log(['Memory: up to about %.1f GB (%.2f GB of starting data, 2 copies, %.1f data-sized ', ...
                    'levels on the deepest branch). Resampling early in the plan reduces it.'], gb * 2 * levels, gb, levels);
            end
            if ~isempty(opts.checkpoint) && ~any(done)
                result = pipecompare.run.Executor.writeManifest(result);
                env.identity = result.identity; env.checkpoint = result.options.checkpoint;
            elseif isfield(result, 'identity')
                env.identity = result.identity;
            end
            ctx0 = struct('contract', contract, 'highpass', rootHighpass(result.state), 'ref', ref, 'rank', opts);
            acc0 = struct('interpolated', {{}}, 'icsRemoved', 0, 'rejected', 0, 'coms', {{}}, 'seconds', 0, 'unmatched', {{}}, ...
                'ica', {{}}, 'overLimit', noOverLimit(), 'steps', {{}});
            % pipelines whose filters alone distort the known signal are
            % excluded before anything runs (filters are linear and
            % time-invariant: that does not depend on the data)
            pre = repmat(emptyCand(), 0, 1);
            if pipecompare.utils.fieldOr(opts, 'filterCheck', true) && ~isempty(S)
                why = pipecompare.eval.Injection.filterCheck(S, contract, env.truth, leaves, opts);
                out = find(~cellfun(@isempty, why(:)) & ~done(:))';
                for li = out
                    c = emptyCand(); c.id = li; c.key = leaves(li).key; c.stratum = leaves(li).stratum;
                    c.status = 'excluded'; c.message = why{li};
                    pre(end+1, 1) = c; env.done(li) = true; tick(env, 1); %#ok<AGROW>
                    pipecompare.utils.log('candidate %d excluded before running: %s', li, c.message);
                end
                if ~isempty(out)
                    pipecompare.utils.log(['Filter check: %d pipeline(s) excluded before running, because their filters ', ...
                        'alone distort the known signal (e.g. %s).'], numel(out), why{out(1)});
                end
            end
            % pipelines with no step at all (every slot chose 'none') are the starting copy itself
            for li = tree(1).leaves
                if env.done(li), continue; end
                c = evaluateLeaf(env, li, root, S, acc0); pre(end+1, 1) = c; saveLeaf(env, c); %#ok<AGROW>
                tick(env, 1);
            end
            if opts.parallel && canParallel()
                cands = pipecompare.run.Executor.runParallel(env, root, S, ctx0, acc0);
            else
                if opts.parallel, pipecompare.utils.log('Parallel evaluation unavailable (Parallel Computing Toolbox/pool); running serially.'); end
                cands = pipecompare.run.Executor.runSubtree(env, 1, root, S, ctx0, acc0);
            end
            cands = [pre; cands];
            allc = repmat(emptyCand(), numel(leaves), 1);
            if isfield(result, 'prevCands'), allc = result.prevCands; result = rmfield(result, 'prevCands'); end
            for k = 1:numel(cands), allc(cands(k).id) = cands(k); end
            notRun = find([allc.id] == 0);   % only after a stop (opts.progress)
            for li = notRun
                allc(li).id = li; allc(li).key = leaves(li).key; allc(li).stratum = leaves(li).stratum;
                allc(li).status = 'failed'; allc(li).message = 'not run: the search was stopped';
            end
            if ~isempty(notRun)
                pipecompare.utils.log('Stopped: %d of %d candidates were not run; the ranking covers the others.', ...
                    numel(notRun), numel(allc));
            end
            result.notRun = numel(notRun);
            result.cands = allc;
            R = pipecompare.eval.Rank.run(allc, ref, opts);
            result.ranking = R;
            result.marginal = pipecompare.eval.Rank.marginal(R, leaves, result.report.searched);
            result.robustness = pipecompare.eval.Rank.robustness(allc, R, leaves, result.report.searched, ref);
            pipecompare.eval.Rank.print(R, result.labels);
            notes = unique([allc.unmatched]);
            if ~isempty(notes)
                pipecompare.utils.log(['Signal check note: %s step(s) were re-run rather than replayed on the injected copy; ', ...
                    'their signal effect is measured but not decision-matched.'], strjoin(notes, ', '));
            end
            if ~isempty(result.marginal) && height(result.marginal) > 0
                pipecompare.utils.log('Effect of each searched choice (medians over evaluated candidates; best among feasible):');
                disp(result.marginal);
            end
            if ~isempty(result.robustness) && height(result.robustness) > 0
                pipecompare.utils.log(['Multiverse summary: each measure over the feasible pipelines, and the searched ', ...
                    'choice that accounts for most of its spread (share = eta^2). Sensitivity only; not used for the ranking.']);
                disp(result.robustness);
            end
            pipecompare.utils.log('Finished in %.1f s.', toc(env.tStart));
            if isfield(result.options, 'progress'), result.options.progress = []; end   % do not keep the caller's window
        end

        function out = runSubtree(env, node, E, S, ctx, acc)
            % Depth-first execution of the subtree below node. Returns one
            % record per evaluated leaf. No shared state: safe for parfor.
            out = repmat(emptyCand(), 0, 1);
            tree = env.tree;
            labels = [];   % ICLabel classification of E, shared by sibling icremove steps
            for child = tree(node).children
                under = leavesUnder(tree, child);
                if all(env.done(under)), continue; end
                in = tree(child).inst;
                if tick(env, 0, in), continue; end   % stopped: nothing more runs
                t0 = tic;
                try
                    pipecompare.utils.log('step %s', in.label);
                    cx = ctx;
                    if strcmp(in.type, 'icremove'), cx.iclabel = labels; end
                    [E2, coms, info] = runStep(in, E, cx, env.opts.verbose);
                    if isfield(info, 'iclabel'), labels = info.iclabel; end
                    for q = 1:numel(coms)
                        fprintf('    %s\n', coms{q});
                        E2 = eeg_hist(E2, coms{q});
                    end
                catch ME
                    out = [out; failUnder(env, under, in, ME)]; %#ok<AGROW>
                    continue;
                end
                [S2, unmatched] = replayCopy(in, S, info, ctx);
                [ctx2, acc2] = advance(in, ctx, acc, info, coms, unmatched, toc(t0));
                for li = tree(child).leaves
                    if env.done(li), continue; end
                    c = evaluateLeaf(env, li, E2, S2, acc2);
                    out(end+1, 1) = c; %#ok<AGROW>
                    saveLeaf(env, c);
                    tick(env, 1);
                end
                out = [out; pipecompare.run.Executor.runSubtree(env, child, E2, S2, ctx2, acc2)]; %#ok<AGROW>
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
                if tick(env, 0, in), return; end   % stopped: nothing more runs
                pipecompare.utils.log('step %s (shared trunk)', in.label);
                t0 = tic;
                try
                    [E, coms, info] = runStep(in, E, ctx, env.opts.verbose);
                    for q = 1:numel(coms), fprintf('    %s\n', coms{q}); E = eeg_hist(E, coms{q}); end
                catch ME   % same handling as runSubtree: the candidates below fail, the search goes on
                    out = [out; failUnder(env, leavesUnder(tree, child), in, ME)];
                    return;
                end
                [S, unmatched] = replayCopy(in, S, info, ctx);
                [ctx, acc] = advance(in, ctx, acc, info, coms, unmatched, toc(t0));
                for li = tree(child).leaves
                    if env.done(li), continue; end
                    c = evaluateLeaf(env, li, E, S, acc); out(end+1, 1) = c; saveLeaf(env, c); %#ok<AGROW>
                    tick(env, 1);
                end
                node = child;
            end
            kids = tree(node).children;
            if isempty(kids), return; end
            pipecompare.utils.log('Parallel: %d independent subtrees on the pool.', numel(kids));
            % The caller's progress window cannot be reached from the workers:
            % they report to it through a DataQueue (each finished pipeline,
            % and each check for Stop), and its Stop reaches them as a file
            % they look for (the pool's workers run on this computer).
            prog = env.opts.progress; env.opts.progress = [];
            stopFile = [tempname '_pipecompare_stop'];
            cleanStop = onCleanup(@() deleteIfThere(stopFile)); %#ok<NASGU>
            if ~isempty(prog)
                try
                    q = parallel.pool.DataQueue;
                    afterEach(q, @(args) relayProgress(prog, args, stopFile));
                    env.opts.progress = @(varargin) workerProgress(q, stopFile, varargin);
                catch ME
                    pipecompare.utils.log('Progress and Stop are not available while the pool runs (%s).', ME.message);
                end
            end
            parts = cell(1, numel(kids));
            parfor k = 1:numel(kids)
                sub = env;
                sub.tree(node).children = kids(k);
                parts{k} = pipecompare.run.Executor.runSubtree(sub, node, E, S, ctx, acc);
            end
            out = [out; vertcat(parts{:})];
        end

        function [root, coms] = prepareRoot(EEG, contract, opts)
            % PipeCompare's own copy of the live dataset; the original is untouched.
            if nargin < 3, opts = struct('dataUnit', 'uV'); end
            root = EEG; coms = {};
            if ~isempty(root.chanlocs), root.chanlocs = root.chanlocs(:)'; end   % a column after some importers (pop_biosig)
            function add(c), root = eeg_hist(root, c); coms{end+1} = c; end
            if isfield(opts, 'dataUnit') && strcmp(opts.dataUnit, 'V')
                % the script line does exactly what is done here (ICA weights
                % too, so existing activations keep their scale)
                cmd = ['EEG.data = EEG.data * 1e6; if ~isempty(EEG.icaweights), EEG.icaweights = EEG.icaweights / 1e6; ', ...
                    'EEG.icawinv = []; EEG.icaact = []; end; EEG = eeg_checkset(EEG); % PipeCompare: volts -> microvolts'];
                root = evalWithEEG(root, cmd);
                add(cmd);
            end
            r = round(root.srate);
            if root.srate ~= r && abs(root.srate - r) <= 1e-9 * r
                pipecompare.utils.log('EEG.srate is %.17g (floating-point residue); using %d on PipeCompare''s copy.', root.srate, r);
                root.srate = r; root = eeg_checkset(root);
                add(sprintf('EEG.srate = %d; EEG = eeg_checkset(EEG); %% PipeCompare: exact sampling rate', r));
            end
            if ~isfield(root, 'urevent') || isempty(root.urevent)
                root = eeg_checkset(root, 'makeur');
                add('EEG = eeg_checkset(EEG, ''makeur''); % PipeCompare: trial identities');
            end
            if contract.isSegmented() && root.trials == 1
                % consecutive analysis segments, marked with EEGLAB's own function
                % (events and urevents, so each segment is paired across candidates)
                cmd = sprintf(['EEG = eeg_regepochs(EEG, ''recurrence'', %g, ''limits'', [0 %g], ''eventtype'', ''%s'', ', ...
                    '''extractepochs'', ''off''); %% PipeCompare: %g s analysis segments'], contract.segment, contract.segment, ...
                    pipecompare.eval.Contract.SegmentEvent, contract.segment);
                [~, root] = evalc('evalWithEEG(root, cmd)');
                add(cmd);
            end
            % a trial list left in the dataset by an earlier search (e.g. an
            % adopted candidate) must never restrict this one; datasets adopted
            % with NeuroQC (<= 0.7) keep it under EEG.etc.neuroqc
            for f = {'pipecompare', 'neuroqc'}
                if isfield(root, 'etc') && isstruct(root.etc) && isfield(root.etc, f{1}) && isfield(root.etc.(f{1}), 'eligibleUrevents')
                    root.etc.(f{1}) = rmfield(root.etc.(f{1}), 'eligibleUrevents');
                    add(sprintf('EEG.etc.%s = rmfield(EEG.etc.%s, ''eligibleUrevents''); %% PipeCompare: drop an earlier trial rule', ...
                        f{1}, f{1}));
                end
            end
            elig = eligibleTrials(root, contract);
            if ~isempty(elig)
                root.etc.pipecompare.eligibleUrevents = elig;
                add(sprintf('EEG.etc.pipecompare.eligibleUrevents = %s; %% PipeCompare: trial rule %s (urevent ids)', ...
                    mat2str(elig(:)'), contract.trials.mode));
                pipecompare.utils.log('Trial rule %s: %d eligible time-locking events.', contract.trials.mode, numel(elig));
            end
            root.etc.pipecompare.rootChanlocs = root.chanlocs;
            add('EEG.etc.pipecompare.rootChanlocs = EEG.chanlocs; % PipeCompare: montage before the plan');
            pre = pipecompare.live.DataState.fromEEG(root).restorableChannels;
            if ~isempty(pre)
                root.etc.pipecompare.preRemoved = root.chaninfo.removedchans(pre);
                add(sprintf(['EEG.etc.pipecompare.preRemoved = EEG.chaninfo.removedchans(%s); ', ...
                    '%% PipeCompare: channels removed before the plan, restorable by interpolation'], mat2str(pre)));
                pipecompare.utils.log('Channels removed before PipeCompare that a restore step can interpolate: %s', ...
                    strjoin({root.etc.pipecompare.preRemoved.labels}, ', '));
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
            assert(~isempty(d) && isfile(f), 'PipeCompare:Checkpoint', ['The starting dataset of this result is not in ', ...
                'memory and its checkpoint file %s is missing.'], f);
            R = load(f);
            assert(isfield(R, 'identity') && isfield(result, 'identity') && strcmp(R.identity, result.identity), ...
                'PipeCompare:Checkpoint', '%s belongs to another search; the starting dataset cannot be restored.', f);
            root = R.root;
        end

        function EEG = replay(result, idx, recordGlobal)
            % Re-run candidate idx from the stored starting dataset.
            if nargin < 3, recordGlobal = false; end
            EEG = pipecompare.run.Executor.rootOf(result);
            path = result.leaves(idx).path;
            ctx = struct('contract', result.contract, 'highpass', rootHighpass(result.state), 'ref', pipecompare.utils.fieldOr(result, 'ref', []), ...
                'rank', result.options);
            if recordGlobal
                for q = 1:numel(result.rootComs), eegh(result.rootComs{q}); end
            end
            % ICA decompositions the search computed on this path (runica is
            % deterministic here, so fitting again would give the same ones)
            ica = {}; nIca = 0;
            if isfield(result, 'cands') && numel(result.cands) >= idx && isfield(result.cands, 'ica')
                ica = result.cands(idx).ica;
            end
            for k = 1:numel(path)
                in = path{k};
                if strcmp(in.type, 'ica'), nIca = nIca + 1; end
                if strcmp(in.type, 'ica') && nIca <= numel(ica)
                    pipecompare.utils.log('step %s: the decomposition from the search is reused', in.label);
                    d = ica{nIca};
                    EEG.icaweights = d.icaweights; EEG.icasphere = d.icasphere;
                    EEG.icachansind = d.icachansind; EEG.icawinv = []; EEG.icaact = [];
                    EEG = eeg_checkset(EEG);
                    coms = d.coms;
                else
                    pipecompare.utils.log('step %s', in.label);
                    [EEG, coms] = runStep(in, EEG, ctx, result.options.verbose);
                end
                for q = 1:numel(coms)
                    fprintf('    %s\n', coms{q});
                    % eeg_hist always appends; eegh(com, EEG) would skip a command equal to
                    % the previous session command, losing it from the dataset history
                    EEG = eeg_hist(EEG, coms{q});
                    if recordGlobal, eegh(coms{q}); end
                end
                ctx = advance(in, ctx, [], struct(), coms, {}, 0);
            end
            [EEG, com] = pipecompare.run.Executor.selectEligible(EEG, result.contract);
            if ~isempty(com)
                fprintf('    %s\n', com);
                EEG = eeg_hist(EEG, com);
                if recordGlobal, eegh(com); end
            end
        end

        function EEG = apply(EEG, steps, contract)
            % Run steps (rows of type, params) on any dataset as the search
            % runs them, so each step decides from these data (bad
            % channels, components, rejected epochs); used by saved
            % scripts. The preparation is the search's own (unit judged
            % from the amplitude scale); every command goes to EEG.history.
            if nargin < 3 || isempty(contract), contract = pipecompare.eval.Contract(); end
            state = pipecompare.live.DataState.fromEEG(EEG);
            EEG = pipecompare.run.Executor.prepareRoot(EEG, contract, struct('dataUnit', state.unitGuess));
            ctx = struct('contract', contract, 'highpass', rootHighpass(state));
            if any(cellfun(@(p) isfield(p, 'uv') && ischar(p.uv), steps(:, 2)))
                % a limit chosen from the data is judged against these data's own trials
                ctx.ref = pipecompare.eval.Measure.reference(EEG, contract);
            end
            for k = 1:size(steps, 1)
                in = struct('type', steps{k, 1}, 'params', steps{k, 2});
                [EEG, coms] = pipecompare.run.Steps.run(in, EEG, ctx);
                for q = 1:numel(coms), EEG = eeg_hist(EEG, coms{q}); end
                ctx = advance(in, ctx, [], struct(), coms, {}, 0);
            end
            [EEG, com] = pipecompare.run.Executor.selectEligible(EEG, contract);
            if ~isempty(com), EEG = eeg_hist(EEG, com); end
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
            if ~isfield(EEG, 'etc') || ~isstruct(EEG.etc) || ~isfield(EEG.etc, 'pipecompare') || ...
                    ~isfield(EEG.etc.pipecompare, 'eligibleUrevents')
                return;
            end
            if EEG.trials == 1 && (~isfield(EEG, 'epoch') || isempty(EEG.epoch))
                pipecompare.utils.log(['Trial rule: the output is continuous, so it still holds every trial; the ', ...
                    'eligible urevent ids are kept in EEG.etc.pipecompare.eligibleUrevents for later epoching.']);
                return;
            end
            elig = EEG.etc.pipecompare.eligibleUrevents;
            lock = pipecompare.eval.Measure.lockingEvents(EEG, contract.allEvents());
            drop = false(1, EEG.trials);
            for k = find(lock > 0)
                drop(k) = ~ismember(double(EEG.event(lock(k)).urevent), elig);
            end
            if ~any(drop), return; end
            assert(~all(drop), 'PipeCompare:TrialRule', 'The trial rule keeps none of the output epochs.');
            [EEG, com] = pop_select(EEG, 'notrial', find(drop));
            com = sprintf('%s %% PipeCompare: keep only trials of the trial rule (%d removed)', com, sum(drop));
        end

        function idx = pickCandidate(result, idx)
            % idx, or the recommended candidate when idx is empty. With
            % several strata there is no single recommendation, and with no
            % feasible candidate there is none at all: both are errors that
            % name what to do (adopt, script and writeScript share this).
            if ~isempty(idx), return; end
            idx = result.ranking.recommended;
            if isempty(idx) && numel(result.ranking.byStratum) > 1
                error('PipeCompare:Adopt', ['The candidates fall into %d strata (different references) that are not ', ...
                    'comparable; choose one: pass the id of a stratum''s recommendation %s.'], ...
                    numel(result.ranking.byStratum), mat2str([result.ranking.byStratum.recommended]));
            end
            assert(~isempty(idx), 'PipeCompare:Adopt', ['No recommended candidate: none satisfies the constraints. ', ...
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
            idx = pipecompare.run.Executor.pickCandidate(result, idx);
            st = result.ranking.table.status{idx};
            if ~strcmp(st, 'feasible')
                why = result.ranking.table.reason{idx};
                assert(force, 'PipeCompare:Adopt', ['Candidate %d is %s, not feasible: %s. Call adopt(result, %d, true) ', ...
                    'to adopt it anyway.'], idx, st, why, idx);
                pipecompare.utils.log('WARNING: adopting candidate %d although it is %s: %s', idx, st, why);
            end
            [cur, ~] = pipecompare.live.Session.current();
            here = strcmp(pipecompare.live.Session.fingerprint(cur), result.rootFingerprint);
            if ~here && ~force
                inAll = false;
                if evalin('base', 'exist(''ALLEEG'',''var'')')
                    A = evalin('base', 'ALLEEG');
                    for k = 1:numel(A)
                        if strcmp(pipecompare.live.Session.fingerprint(A(k)), result.rootFingerprint), inAll = true; break; end
                    end
                end
                assert(inAll, 'PipeCompare:StaleState', ['The dataset this search started from is no longer in EEGLAB ', ...
                    '(it was changed or removed). Re-run the search, or call adopt(result, id, true) to build the ', ...
                    'candidate from the stored starting copy anyway.']);
                pipecompare.utils.log('The current dataset is not the search''s starting dataset; the candidate is built from that starting dataset.');
            end
            pipecompare.utils.log('Rebuilding candidate %d: %s', idx, result.labels{idx});
            EEG = pipecompare.run.Executor.replay(result, idx, true);
            if strcmp(result.cands(idx).status, 'ok')
                m = pipecompare.eval.Measure.candidate(EEG, result.contract, result.ref, result.options);
                a = [m.objectives.agg]; b = [result.cands(idx).m.objectives.agg];
                same = all(abs(a - b) <= 1e-6 * max(1, abs(b))) && isequal(m.kept, result.cands(idx).m.kept);
                pipecompare.utils.log('Replay check: objectives %s, trials %s (search: %s, %s) -> %s', mat2str(a, 5), ...
                    mat2str(m.kept), mat2str(b, 5), mat2str(result.cands(idx).m.kept), ...
                    pipecompare.utils.ternary(same, 'identical', 'DIFFERENT (non-deterministic step?)'));
                % the evaluation (and the constraints it passed) belongs to the
                % searched data; a rebuilt dataset that differs is not that candidate
                assert(same || force, 'PipeCompare:ReplayMismatch', ['The rebuilt candidate %d differs from the one ', ...
                    'evaluated in the search, so its evaluation does not apply to it. Nothing was stored. Call ', ...
                    'adopt(result, %d, true) to store it anyway.'], idx, idx);
                if ~same, pipecompare.utils.log('WARNING: storing a rebuilt candidate that differs from the evaluated one.'); end
            end
            EEG.setname = sprintf('%s PipeCompare#%d', result.state.setname, idx);
            assignin('base', 'PIPECOMPARE_ADOPT__', EEG);
            evalin('base', ['[ALLEEG, EEG, CURRENTSET] = pop_newset(ALLEEG, PIPECOMPARE_ADOPT__, CURRENTSET, ', ...
                '''gui'', ''off''); clear PIPECOMPARE_ADOPT__; eeglab redraw;']);
            pipecompare.utils.log('Candidate %d stored as a new EEGLAB dataset; its EEG.history lists every step.', idx);
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
                assert(strcmp(prev, identity), 'PipeCompare:Checkpoint', ['Checkpoint folder %s already holds files ', ...
                    'of a different search (other data, contract, plan or options). Use an empty folder, or ', ...
                    'pipecompare.PipeCompare.resume(folder) to continue that search.'], d);
                % same search started again: earlier candidates are discarded, not mixed
                delete(fullfile(d, 'leaf_*.mat'));
            end
            root = result.root; %#ok<NASGU>
            save(fullfile(d, 'root.mat'), 'root', 'identity', '-v7.3');
            result.root = [];          % read back on demand (Executor.rootOf)
            M = struct('result', result, 'identity', identity);   % without the caller's progress window
            if isfield(M.result.options, 'progress'), M.result.options.progress = []; end
            save(fullfile(d, 'manifest.mat'), '-struct', 'M', '-v7.3');
            pipecompare.utils.log('Checkpoint folder: %s (resume with pipecompare.PipeCompare.resume).', d);
        end

        function printReport(rep)
            pipecompare.utils.log('Exhaustive search: %d legal pipeline(s) from %d order(s).', rep.nLeaves, rep.nOrders);
            pipecompare.utils.log('%d step executions with prefix sharing (%d without).', rep.nNodes, rep.nStepsUnshared);
            for k = 1:numel(rep.rejected)
                pipecompare.utils.log('  excluded combinations: %s (x%d)', rep.rejected(k).reason, rep.rejected(k).count);
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
%                           'excluded' (not run: its filters alone distort
%                           the known signal) | 'failed', with the reason
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
%   ica                     the ICA decompositions of its path (weights,
%                           sphere, channels, commands), reused by replay
%   overLimit               per channel (labels, counts), the rejected
%                           epochs in which it was over the limit: names
%                           bad channels the detection missed
%   steps                   per step of its path, in order: the step's
%                           type and settings and what it did on these
%                           data (channels interpolated, components and
%                           epochs removed), for the list of steps
% Rank.run reads status, m, signal, interpolatedFraction and stratum.
c = struct('id', 0, 'key', '', 'stratum', '', 'status', 'pending', 'message', '', 'm', [], 'signal', [], ...
    'interpolatedFraction', NaN, 'icsRemoved', 0, 'rejectedEpochs', 0, 'coms', {{}}, 'seconds', 0, 'unmatched', {{}}, ...
    'notes', {{}}, 'ica', {{}}, 'overLimit', noOverLimit(), 'steps', {{}});
end

function o = noOverLimit()
% per channel, the rejected epochs in which it was over the limit
o = struct('labels', {{}}, 'counts', []);
end

function out = failUnder(env, under, in, ME)
% A step failed: every not yet evaluated candidate below it fails with the
% reason (the search goes on with the other branches).
pipecompare.utils.log('FAILED %s: %s (%d candidate(s) affected)', in.label, ME.message, numel(under));
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
if strcmp(ME.identifier, 'PipeCompare:AllRejected'), s = 'rejected'; else, s = 'failed'; end
end

function [ctx, acc] = advance(in, ctx, acc, info, coms, unmatched, secs)
% State carried to the next step. One definition for the serial search,
% the parallel trunk and replay, so all three run identical steps.
if strcmp(in.type, 'highpass'), ctx.highpass = max(ctx.highpass, in.params.cutoff); end
if strcmp(in.type, 'native')
    for stmt = pipecompare.run.Native.statements(in.params.command)
        e = pipecompare.live.History.classify(stmt{1});
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
if isfield(info, 'ica'), acc.ica{end+1} = info.ica; end
if isfield(info, 'overLimit') && ~isempty(info.overLimit.counts)
    [labels, ~, j] = unique([acc.overLimit.labels(:); info.overLimit.labels(:)]);
    acc.overLimit = struct('labels', {labels(:)'}, 'counts', accumarray(j(:), [acc.overLimit.counts(:); info.overLimit.counts(:)])');
end
acc.steps{end+1} = stepFacts(in, info);
end

function f = stepFacts(in, info)
% What a step did, for the results' list of steps: its settings and the
% decisions it made on these data (channels, components, epochs, epochs
% kept by interpolating channels in them), and for ICLabel how many
% components it took for brain activity and for 'Other' and how many data
% points ICA had (the ICA check); for a rejection limit chosen from the
% data, the limit (uvChosen).
f = struct('type', in.type, 'params', in.params, 'interpolated', {{}}, 'removed', {{}}, ...
    'icsRemoved', NaN, 'icsTotal', NaN, 'rejected', NaN, 'epochsBefore', NaN, 'epochsInterpolated', NaN, ...
    'icsBrain', NaN, 'icsOther', NaN, 'otherMedian', NaN, 'icaPoints', NaN, 'uvChosen', NaN);
for n = {'interpolated', 'removed'}
    if isfield(info, n{1}), f.(n{1}) = cellstr(info.(n{1})); end
end
for n = {'icsRemoved', 'icsTotal', 'rejected', 'epochsBefore', 'epochsInterpolated', 'icsBrain', 'icsOther', 'otherMedian', 'icaPoints', 'uvChosen'}
    if isfield(info, n{1}), f.(n{1}) = info.(n{1}); end
end
end

function [S, unmatched] = replayCopy(in, S, info, ctx)
% The step's decisions applied to the signal-check copy. An error here
% costs only the signal check of the candidates below (they are excluded
% with 'signal check missing'), not the candidates: their real data ran.
unmatched = {};
if isempty(S), return; end
try
    [~, S, matched] = evalc('pipecompare.run.Steps.replayDecision(in, S, info, ctx)');
    if ~matched, unmatched = {in.type}; end
catch ME
    pipecompare.utils.log('Signal check: the copy failed at step %s (%s); the pipelines below have no signal check.', ...
        in.label, ME.message);
    S = [];
end
end

function [E2, coms, info] = runStep(in, E, ctx, verbose)
if strcmp(verbose, 'full')
    [E2, coms, info] = pipecompare.run.Steps.run(in, E, ctx);
    return;
end
[txt, E2, coms, info] = evalc('pipecompare.run.Steps.run(in, E, ctx)');
lines = regexp(txt, '[^\n]+', 'match');
keep = lines(~cellfun(@isempty, regexpi(lines, 'warning|error|\[PipeCompare\]', 'once')));
for k = 1:numel(keep), fprintf('    %s\n', strtrim(keep{k})); end
end

function c = evaluateLeaf(env, li, E, S, acc)
c = emptyCand();
c.id = li; c.key = env.leaves(li).key; c.stratum = env.leaves(li).stratum;
c.coms = acc.coms; c.seconds = acc.seconds;
c.icsRemoved = acc.icsRemoved; c.rejectedEpochs = acc.rejected;
c.interpolatedFraction = numel(acc.interpolated) / env.nbchan;
c.unmatched = acc.unmatched; c.ica = acc.ica; c.overLimit = acc.overLimit; c.steps = acc.steps;
try
    c.m = pipecompare.eval.Measure.candidate(E, env.contract, env.ref, env.opts);
    nm = markedNotRemoved(E);
    if nm > 0
        c.notes{end+1} = sprintf(['%d epoch(s) are marked for rejection (EEG.reject) but still in the data; ', ...
            'marks do not remove epochs, so they count in the scores. Remove them in the plan ', ...
            '(e.g. pop_rejepoch) if they should not count.'], nm);
    end
    [~, ~, tcom] = evalc('pipecompare.run.Executor.selectEligible(E, env.contract)');
    if ~isempty(tcom), c.coms{end+1} = tcom; end
    if ~isempty(S)
        c.signal = pipecompare.eval.Injection.compare(S, env.contract, env.truth, env.leaves(li).path);
    end
    c.status = 'ok';
catch ME
    c.status = 'failed'; c.message = ['evaluation: ' ME.message];
end
el = toc(env.tStart);
if strcmp(c.status, 'ok')
    pipecompare.utils.log('candidate %d: objectives %s, retention %s, %.0f s elapsed', li, ...
        mat2str([c.m.objectives.agg], 4), mat2str(round(100 * c.m.retention)), el);
else
    pipecompare.utils.log('candidate %d failed: %s', li, c.message);
end
end

function stop = tick(env, n, in)
% Tell the caller's opts.progress that n more candidates are evaluated (and,
% before a step, which step starts) and return its request to stop.
stop = false;
if ~isfield(env.opts, 'progress') || isempty(env.opts.progress), return; end
if nargin < 3, stop = callProgress(env.opts.progress, {n}); else, stop = callProgress(env.opts.progress, {n, in}); end
end

function stop = callProgress(f, args)
% a callback of one argument is only told the count
if nargin(f) == 1, args = args(1); end
stop = f(args{:});
end

function relayProgress(prog, args, stopFile)
% client side of a parallel run: show the workers' progress; Stop pressed
% there leaves the file the workers look for
if callProgress(prog, args) && ~isfile(stopFile), fclose(fopen(stopFile, 'w')); end
end

function stop = workerProgress(q, stopFile, args)
% worker side of a parallel run (the progress callback tick() calls)
send(q, args);
stop = isfile(stopFile);
end

function deleteIfThere(file)
if isfile(file), delete(file); end
end

function saveLeaf(env, cand)
if isempty(env.checkpoint), return; end
id = cand.id; key = cand.key; identity = env.identity; %#ok<NASGU>
tmp = fullfile(env.checkpoint, sprintf('leaf_%06d.tmp.mat', id));
save(tmp, 'id', 'key', 'cand', 'identity', '-v7.3');
movefile(tmp, fullfile(env.checkpoint, sprintf('leaf_%06d.mat', id)), 'f');
if isfield(env.opts, 'stopAfter') && numel(dir(fullfile(env.checkpoint, 'leaf_*.mat'))) >= env.opts.stopAfter
    % simulated interruption (tests): everything saved so far is kept
    error('PipeCompare:Interrupted', 'Search interrupted after %d candidates (opts.stopAfter).', env.opts.stopAfter);
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
% honours its own flags (Lopez-Calderon & Luck, 2014), PipeCompare's scores
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
        % 'Processes' is the profile's name from R2022b on, 'local' before
        p = gcp('nocreate'); if isempty(p), try, parpool('Processes'); catch, parpool('local'); end, end
    catch
        tf = false;
    end
end
end

function v = versions()
v = struct('matlab', version, 'eeglab', 'unknown', 'pipecompare', pipecompare.PipeCompare.Version, ...
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
assert(~isempty(elig), 'PipeCompare:TrialRule', 'The trial rule keeps no trials.');
end


function EEG = evalWithEEG(EEG, PIPECOMPARE_CMD__)
% Run a script line on EEG exactly as the exported script will.
eval(PIPECOMPARE_CMD__);
end

function id = searchIdentity(result)
% What makes two searches the same: the starting data (full content), the
% analysis contract, the enumerated pipelines and the options that change
% results. A checkpoint folder belongs to exactly one identity.
o = result.options;
o = rmfield(o, intersect(fieldnames(o), {'checkpoint','stopAfter','parallel','verbose','dryRun','progress'}));
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
