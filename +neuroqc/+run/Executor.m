classdef Executor
    %EXECUTOR Run every legal pipeline of a plan on the current EEGLAB dataset.
    %
    %   result = neuroqc.run.Executor.run(plan, contract, opts)
    %
    %   - Reads the dataset that is current in EEGLAB (no loading step) and
    %     prints its state and parsed EEG.history.
    %   - Enumerates the legal pipelines as a prefix tree and runs it depth
    %     first, so pipelines that share their first steps share that work
    %     (e.g. one ICA per distinct preceding prefix, not one per pipeline).
    %   - Every EEGLAB command is printed to the Command Window and appended
    %     to the candidate's EEG.history.
    %   - Scores each finished pipeline (neuroqc.eval.Measure,
    %     neuroqc.eval.FilterProbe) and ranks them (neuroqc.eval.Rank).
    %
    %   opts (all optional): maxLeaves (500), maxOrders, dryRun (false),
    %   plus the constraint/bootstrap fields of neuroqc.eval.Rank.defaults.
    %   The live dataset in EEGLAB is never modified.

    methods (Static)
        function result = run(plan, contract, opts)
            if nargin < 3, opts = struct(); end
            if ~isfield(opts, 'dryRun'), opts.dryRun = false; end
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
            neuroqc.utils.log(['%d legal pipeline(s) from %d order(s); %d step executions with prefix sharing ', ...
                '(%d without).'], rep.nLeaves, rep.nOrders, rep.nNodes, rep.nStepsUnshared);
            for k = 1:numel(rep.rejected)
                neuroqc.utils.log('  excluded combinations: %s (x%d)', rep.rejected(k).reason, rep.rejected(k).count);
            end
            labels = arrayfun(@(l) l.key, leaves, 'UniformOutput', false);
            result = struct('plan', plan, 'contract', contract, 'options', opts, 'state', state, ...
                'rootFingerprint', live.fingerprint, 'leaves', leaves, 'tree', tree, 'report', rep, ...
                'labels', {labels}, 'cands', [], 'ranking', [], 'marginal', [], 'root', []);
            if opts.dryRun, return; end

            root = neuroqc.run.Executor.prepareRoot(EEG);
            ref = neuroqc.eval.Measure.reference(root, contract);
            neuroqc.utils.log('Reference trials per condition: %s', ...
                strjoin(arrayfun(@(c) sprintf('%s=%d', contract.conditions(c).name, ref.n(c)), ...
                1:numel(ref.n), 'UniformOutput', false), ', '));

            cands = repmat(struct('status', 'pending', 'message', '', 'm', [], 'probe', [], ...
                'interpolatedFraction', NaN, 'icsRemoved', 0, 'rejectedEpochs', 0, 'coms', {{}}, 'seconds', 0), ...
                numel(leaves), 1);
            probeCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            done = 0; tStart = tic;
            acc0 = struct('interpolated', {{}}, 'icsRemoved', 0, 'rejected', 0, 'coms', {{}}, 'seconds', 0);
            ctx0 = struct('contract', contract, 'highpass', rootHighpass(state));
            visit(1, root, ctx0, acc0);

            result.cands = cands;
            result.root = root;
            result.ref = ref;
            R = neuroqc.eval.Rank.run(cands, ref, opts);
            result.ranking = R;
            result.marginal = neuroqc.eval.Rank.marginal(R, leaves, rep.searched);
            neuroqc.eval.Rank.print(R, labels);
            if ~isempty(result.marginal) && height(result.marginal) > 0
                neuroqc.utils.log('Effect of each searched choice (medians over evaluated candidates; best among feasible):');
                disp(result.marginal);
            end
            neuroqc.utils.log('Finished in %.1f s.', toc(tStart));

            function visit(node, E, ctx, acc)
                for child = tree(node).children
                    in = tree(child).inst;
                    t0 = tic;
                    try
                        neuroqc.utils.log('step %s', in.label);
                        [E2, coms, info] = neuroqc.run.Steps.run(in, E, ctx);
                        for q = 1:numel(coms)
                            fprintf('    %s\n', coms{q});
                            E2 = eeg_hist(E2, coms{q});
                        end
                    catch ME
                        under = leavesUnder(tree, child);
                        for li = under
                            cands(li).status = 'failed';
                            cands(li).message = sprintf('%s: %s', in.label, ME.message);
                        end
                        neuroqc.utils.log('FAILED %s: %s (%d candidate(s) affected)', in.label, ME.message, numel(under));
                        done = done + numel(under);
                        continue;
                    end
                    ctx2 = ctx; acc2 = acc;
                    acc2.seconds = acc.seconds + toc(t0);
                    acc2.coms = [acc.coms coms];
                    if strcmp(in.type, 'highpass'), ctx2.highpass = max(ctx.highpass, in.params.cutoff); end
                    if strcmp(in.type, 'native')
                        e = neuroqc.live.History.classify(in.params.command);
                        if isfield(e.params, 'locutoff') && isfinite(e.params.locutoff) && ~e.params.revfilt
                            ctx2.highpass = max(ctx.highpass, e.params.locutoff);
                        end
                    end
                    if isfield(info, 'interpolated'), acc2.interpolated = union(acc.interpolated, lower(info.interpolated)); end
                    if isfield(info, 'icsRemoved'), acc2.icsRemoved = acc.icsRemoved + info.icsRemoved; end
                    if isfield(info, 'rejected'), acc2.rejected = acc.rejected + info.rejected; end
                    for li = tree(child).leaves
                        evaluateLeaf(li, E2, acc2);
                    end
                    visit(child, E2, ctx2, acc2);
                end
            end

            function evaluateLeaf(li, E, acc)
                c = cands(li);
                c.coms = acc.coms; c.seconds = acc.seconds;
                c.icsRemoved = acc.icsRemoved; c.rejectedEpochs = acc.rejected;
                c.interpolatedFraction = numel(acc.interpolated) / state.nbchan;
                try
                    c.m = neuroqc.eval.Measure.candidate(E, contract, ref);
                    pk = probeKey(leaves(li).path);
                    if ~isKey(probeCache, pk)
                        probeCache(pk) = neuroqc.eval.FilterProbe.run(leaves(li).path, state.srate, contract);
                    end
                    c.probe = probeCache(pk);
                    c.status = 'ok';
                catch ME
                    c.status = 'failed'; c.message = ['evaluation: ' ME.message];
                end
                cands(li) = c;
                done = done + 1;
                el = toc(tStart);
                if c.status(1) == 'o'
                    neuroqc.utils.log('[%d/%d] candidate %d: SME %.3f uV, retention %s, %.0f s elapsed, ~%.0f s left', ...
                        done, numel(leaves), li, c.m.composite, mat2str(round(100*c.m.retention)), el, ...
                        el / done * (numel(leaves) - done));
                else
                    neuroqc.utils.log('[%d/%d] candidate %d failed: %s', done, numel(leaves), li, c.message);
                end
            end
        end

        function root = prepareRoot(EEG)
            % NeuroQC's own copy of the live dataset; the original is untouched.
            root = EEG;
            if ~isfield(root, 'urevent') || isempty(root.urevent)
                root = eeg_checkset(root, 'makeur');
                root = eeg_hist(root, 'EEG = eeg_checkset(EEG, ''makeur''); % NeuroQC: trial identities');
            end
            if root.srate ~= round(root.srate) && abs(root.srate - round(root.srate)) < 1e-6
                neuroqc.utils.log('EEG.srate is %.17g; set to %d on NeuroQC''s copy (ICLabel needs an integer rate).', root.srate, round(root.srate));
                root.srate = round(root.srate); root = eeg_checkset(root);
                root = eeg_hist(root, sprintf('EEG.srate = %d; EEG = eeg_checkset(EEG); %% NeuroQC: exact sampling rate', root.srate));
            end
            root.etc.neuroqc.rootChanlocs = root.chanlocs;
            root = eeg_hist(root, 'EEG.etc.neuroqc.rootChanlocs = EEG.chanlocs; % NeuroQC: montage before the plan');
        end

        function EEG = replay(result, idx, recordGlobal)
            % Re-run candidate idx from the stored starting dataset.
            if nargin < 3, recordGlobal = false; end
            EEG = result.root;
            path = result.leaves(idx).path;
            ctx = struct('contract', result.contract, 'highpass', rootHighpass(result.state));
            for k = 1:numel(path)
                in = path{k};
                neuroqc.utils.log('step %s', in.label);
                [EEG, coms] = neuroqc.run.Steps.run(in, EEG, ctx);
                for q = 1:numel(coms)
                    fprintf('    %s\n', coms{q});
                    if recordGlobal, EEG = eegh(coms{q}, EEG); else, EEG = eeg_hist(EEG, coms{q}); end
                end
                if strcmp(in.type, 'highpass'), ctx.highpass = max(ctx.highpass, in.params.cutoff); end
            end
        end

        function adopt(result, idx)
            % Store candidate idx as a NEW EEGLAB dataset with its full history.
            if nargin < 2 || isempty(idx), idx = result.ranking.recommended; end
            assert(~isempty(idx), 'NeuroQC:Adopt', 'No candidate to adopt.');
            [cur, ~] = neuroqc.live.Session.current();
            if ~strcmp(neuroqc.live.Session.fingerprint(cur), result.rootFingerprint)
                neuroqc.utils.log(['WARNING: the current EEGLAB dataset is not the one this search started from; ', ...
                    'the candidate is rebuilt from the stored starting dataset.']);
            end
            neuroqc.utils.log('Rebuilding candidate %d: %s', idx, result.labels{idx});
            EEG = neuroqc.run.Executor.replay(result, idx, true);
            if strcmp(result.cands(idx).status, 'ok')
                m = neuroqc.eval.Measure.candidate(EEG, result.contract, result.ref);
                same = abs(m.composite - result.cands(idx).m.composite) <= 1e-6 * max(1, abs(m.composite));
                neuroqc.utils.log('Replay check: SME %.4f (search: %.4f) -> %s', m.composite, ...
                    result.cands(idx).m.composite, ternary(same, 'identical', 'DIFFERENT (non-deterministic step?)'));
            end
            EEG.setname = sprintf('%s NeuroQC#%d', result.state.setname, idx);
            assignin('base', 'NEUROQC_ADOPT__', EEG);
            evalin('base', ['[ALLEEG, EEG, CURRENTSET] = pop_newset(ALLEEG, NEUROQC_ADOPT__, CURRENTSET, ', ...
                '''gui'', ''off''); clear NEUROQC_ADOPT__; eeglab redraw;']);
            neuroqc.utils.log('Candidate %d stored as a new EEGLAB dataset; its EEG.history lists every step.', idx);
        end
    end
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

function k = probeKey(path)
parts = {};
for q = 1:numel(path)
    if any(strcmp(path{q}.type, {'highpass','lowpass','linenoise','resample','native'}))
        parts{end+1} = path{q}.key; %#ok<AGROW>
    end
end
k = strjoin(parts, '>');
if isempty(k), k = 'none'; end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
