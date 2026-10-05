function tests = test_history
%TEST_HISTORY EEG.history parsing and provenance (needs EEGLAB on the path).
tests = functiontests(localfunctions);
end

function setupOnce(tc)
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
assert(exist('pop_epoch', 'file') == 2, 'EEGLAB must be on the path');
% Optional: a real processed dataset (never committed), e.g.
% setenv('PIPECOMPARE_REAL_SET', '/path/to/file.set')
tc.TestData.realSet = getenv('PIPECOMPARE_REAL_SET');
end

function testHistoryOrderedNoDedupe(tc)
h = sprintf([ ...
    'EEG.etc.eeglabvers = ''2026.0.0''; %% this tracks which version\n' ...
    'EEG = pop_eegfiltnew(EEG, ''locutoff'',1,''hicutoff'',30,''plotfreqz'',1);\n' ...
    'figure; pop_spectopo(EEG, 1, [0  4121340], ''EEG'' , ''freq'', [6 10 22]);\n' ...
    'EEG = pop_eegfiltnew(EEG, ''locutoff'',48,''hicutoff'',52,''revfilt'',1,''plotfreqz'',1);\n' ...
    'EEG = pop_select( EEG, ''rmchannel'',{''O1'',''O2''});\n' ...
    'EEG = pop_reref( EEG, []);\n' ...
    'EEG = pop_runica(EEG, ''icatype'', ''runica'', ''extended'',1,''pca'',20,''interrupt'',''on'');\n' ...
    'EEG = pop_interp(EEG, ALLEEG(5).chanlocs, ''spherical'');\n' ...
    'pop_selectcomps(EEG, [1:20] );\n' ...
    'EEG = pop_epoch( EEG, {  ''11''  ''21''  ''31''  }, [-0.2           1], ''epochinfo'', ''yes'');\n' ...
    'EEG = pop_subcomp( EEG, [], 0);\n' ...
    'EEG = pop_rmbase( EEG, [-200 0] ,[]);\n' ...
    'EEG = pop_reref( EEG, []);\n' ...
    'EEG = pop_runica(EEG, ''icatype'', ''runica'', ''extended'',1);\n' ...
    'EEG = pop_eegthresh(EEG,1,[1:30],-100,100,-0.2,0.996,0,0);\n' ...
    'EEG = pop_rejepoch( EEG, [3 7], 0);']);
e = pipecompare.live.History.parse(h);
steps = {e.step};
verifyEqual(tc, sum(strcmp(steps, 'reref')), 2);
verifyEqual(tc, sum(strcmp(steps, 'ica')), 2);
verifyEqual(tc, e(strcmp({e.fn}, 'pop_spectopo')).kind, 'view');
verifyEqual(tc, e(strcmp({e.fn}, 'figure')).kind, 'view');
bp = e(find(strcmp({e.fn}, 'pop_eegfiltnew'), 1));
verifyEqual(tc, bp.step, 'bandpass'); verifyEqual(tc, bp.params.locutoff, 1); verifyEqual(tc, bp.params.hicutoff, 30);
nt = e(find(strcmp({e.fn}, 'pop_eegfiltnew'), 1, 'last'));
verifyEqual(tc, nt.step, 'linenoise');
verifyEqual(tc, e(strcmp({e.fn}, 'pop_select')).step, 'channels');
ep = e(strcmp({e.fn}, 'pop_epoch'));
verifyEqual(tc, ep.params.window, [-0.2 1]);
verifyTrue(tc, contains(e(strcmp({e.fn}, 'pop_interp')).note, 'not reproducible'));
verifyTrue(tc, contains(e(strcmp({e.fn}, 'pop_subcomp')).note, 'gcompreject'));
verifyEqual(tc, e(strcmp({e.fn}, 'pop_eegthresh')).kind, 'mark');
verifyEqual(tc, e(strcmp({e.fn}, 'pop_rejepoch')).step, 'reject_epochs');
verifyEqual(tc, e(1).kind, 'admin');
end

function testEdgesOfOtherFilters(tc)
% Filters other than pop_eegfiltnew (ERPLAB, firfilt's windowed sinc, the
% old and the IIR filter) and clean_rawdata's own high-pass give their
% edges, so the simple mode knows the data are already filtered there.
h = sprintf([ ...
    'EEG  = pop_basicfilter( EEG,  1:32 , ''Boundary'', ''boundary'', ''Cutoff'', [ 0.1 30], ''Design'', ''butter'', ''Filter'', ''bandpass'', ''Order'',  2 );\n' ...
    'EEG = pop_firws(EEG, ''fcutoff'', 0.5, ''ftype'', ''highpass'', ''wtype'', ''hamming'', ''forder'', 1650, ''minphase'', 0);\n' ...
    'EEG = pop_eegfilt( EEG, 0, 40, [], [0], 0, 0, ''fir1'', 0);\n' ...
    'EEG = pop_iirfilt( EEG, 0.05, 0, [], 0, 0);\n' ...
    'EEG = pop_firma(EEG, ''forder'', 10);\n' ...
    'EEG = pop_clean_rawdata(EEG, ''FlatlineCriterion'',5,''ChannelCriterion'',0.8,''LineNoiseCriterion'',4,' ...
    '''Highpass'',[0.25 0.75] ,''BurstCriterion'',20,''WindowCriterion'',''off'',''BurstRejection'',''off'',''Distance'',''Euclidian'');']);
e = pipecompare.live.History.parse(h);
p = e(strcmp({e.fn}, 'pop_basicfilter')).params;
verifyEqual(tc, [p.locutoff p.hicutoff], [0.1 30]); verifyFalse(tc, p.revfilt);
verifyEqual(tc, e(strcmp({e.fn}, 'pop_firws')).params.locutoff, 0.5);
p = e(strcmp({e.fn}, 'pop_eegfilt')).params;
verifyTrue(tc, isnan(p.locutoff)); verifyEqual(tc, p.hicutoff, 40);   % 0: no edge on that side
verifyEqual(tc, e(strcmp({e.fn}, 'pop_iirfilt')).params.locutoff, 0.05);
verifyTrue(tc, contains(e(strcmp({e.fn}, 'pop_firma')).note, 'not parsed'));
EEG = nqc_synth(struct('seconds', 20, 'nPerCond', 5));
EEG.history = h;
f = pipecompare.live.DataState.fromEEG(EEG).filters;
verifyEqual(tc, f.highpass, [0.1 0.5 0.05 0.75]);              % clean_rawdata: the end of its transition band
verifyEqual(tc, f.lowpass, [30 40]);
verifyEqual(tc, f.other, 1);                                    % pop_firma only
end

function testIcaFittedOnAFilteredCopy(tc)
% The line PipeCompare writes for ICA fitted on a high-passed copy: an ICA
% step, and no filter of the data.
h = sprintf(['EEG = pop_eegfiltnew(EEG, ''locutoff'',0.1,''plotfreqz'',0);\n' ...
    'EEGica = pop_eegfiltnew(EEG, ''locutoff'', 1, ''plotfreqz'', 0); EEGica = pop_runica(EEGica, ' ...
    '''icatype'',''runica'',''extended'',1,''rndreset'',''no'',''interrupt'',''off''); ' ...
    'EEG.icaweights = EEGica.icaweights; EEG.icasphere = EEGica.icasphere; ' ...
    'EEG.icachansind = EEGica.icachansind; EEG.icawinv = []; EEG.icaact = []; ' ...
    'EEG = eeg_checkset(EEG); clear EEGica; %% PipeCompare: ICA fitted on a 1 Hz high-passed copy']);
e = pipecompare.live.History.parse(h);
verifyEqual(tc, sum(strcmp({e.step}, 'ica')), 1);
verifyEqual(tc, sum(strcmp({e.step}, 'highpass')), 1);
EEG = nqc_synth(struct('seconds', 20, 'nPerCond', 5)); EEG.history = h;
s = pipecompare.live.DataState.fromEEG(EEG);
verifyEqual(tc, s.filters.highpass, 0.1);
end

function testHistoryCharMatrixAndPositional(tc)
h = char({'EEG = pop_eegfiltnew(EEG, 0.5, []);', 'EEG = pop_eegfiltnew(EEG, [], 40);', ...
    'EEG = pop_resample( EEG, 250);'});
e = pipecompare.live.History.parse(h);
verifyEqual(tc, {e.step}, {'highpass','lowpass','resample'});
verifyEqual(tc, e(3).params.fs, 250);
end

function testRealDatasetHistory(tc)
assumeTrue(tc, ~isempty(tc.TestData.realSet) && isfile(tc.TestData.realSet), 'set PIPECOMPARE_REAL_SET to run');
EEG = pop_loadset(tc.TestData.realSet);
s = pipecompare.live.DataState.fromEEG(EEG);
% every pop_* call that the history contains is kept (no deduplication)
h = char(EEG.history); h = h(:)';
for fn = {'pop_runica', 'pop_reref', 'pop_epoch', 'pop_eegfiltnew'}
    verifyEqual(tc, sum(strcmp({s.history.fn}, fn{1})), numel(regexp(h, ['\<' fn{1} '\s*\('])), fn{1});
end
pipecompare.live.DataState.print(s);
end

% ------------------------------------------------------------------- plan

function testContinuationLinesAreOneCommand(tc)
h = sprintf(['EEG = pop_eegfiltnew(EEG, ''locutoff'', 0.5, ...\n' ...
    '    ''hicutoff'', 30);\n' ...
    'EEG = pop_reref(EEG, []); %% comment with ... inside\n' ...
    'EEG = pop_select(EEG, ''rmchannel'', {''O1'', ... first\n' ...
    '    ''O2''});']);
e = pipecompare.live.History.parse(h);
verifyEqual(tc, {e.step}, {'bandpass', 'reref', 'channels'});
verifyEqual(tc, e(1).params.hicutoff, 30);
verifyEqual(tc, [e.line], [1 3 4]);   % line numbers of the first physical line
end

function testRepeatedOperationsStayDistinct(tc)
h = sprintf('EEG = pop_eegfiltnew(EEG, ''locutoff'', 0.1);\nEEG = pop_eegfiltnew(EEG, ''locutoff'', 1);\nEEG = pop_eegfiltnew(EEG, ''locutoff'', 0.1);');
e = pipecompare.live.History.parse(h);
verifyEqual(tc, numel(e), 3);
verifyEqual(tc, arrayfun(@(x) x.params.locutoff, e), [0.1 1 0.1]);
end

function testProvenanceCategories(tc)
EEG = nqc_synth(struct('seconds', 30, 'nPerCond', 5));
EEG.history = sprintf(['EEG = pop_loadset(''x.set'');\nEEG = pop_reref(EEG, []);\n' ...
    'EEG = pop_subcomp(EEG, [], 0);\nEEG.etc.pipecompare.rootChanlocs = EEG.chanlocs; %% PipeCompare: montage']);
EEG.icaweights = eye(EEG.nbchan); EEG.icasphere = eye(EEG.nbchan); EEG.icachansind = 1:EEG.nbchan;
EEG = eeg_checkset(EEG);
global ALLCOM %#ok<GVMIS>
saved = ALLCOM; cleanup = onCleanup(@() restoreAllcom(saved));
ALLCOM = {'EEG = pop_resample( EEG, 100);'};
s = pipecompare.live.DataState.fromEEG(EEG);
cats = {s.provenance.category};
verifyTrue(tc, any(strcmp(cats, 'recorded in EEG.history')));
verifyTrue(tc, any(strcmp(cats, 'inferred from the data')));            % ICA matrices, no ICA call
verifyTrue(tc, any(strcmp(cats, 'cannot be verified')));                % pop_subcomp with []
verifyTrue(tc, any(contains(cats, 'session command')));                  % ALLCOM entry not in history
inf = s.provenance(strcmp(cats, 'inferred from the data'));
verifyTrue(tc, any(strcmp({inf.item}, 'ica')));
end

function restoreAllcom(saved)
global ALLCOM %#ok<GVMIS>
ALLCOM = saved;
end
