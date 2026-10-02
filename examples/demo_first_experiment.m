% demo_first_experiment.m
% Same data, only high-pass differs: 0.1 / 0.5 / 1 Hz.
% Recommend three recipes; rank only after importing external QC from EEGLAB.

clear; clc;
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
fprintf('NeuroQC v%s — first experiment (advice path)\n', neuroqc.NeuroQC.version());

%% 1) Data
[EEG, ~] = neuroqc.inspect.SyntheticEEG.generate(struct( ...
    'durationSec', 120, 'nTarget', 50, 'nStandard', 150));
subject = 'Synthetic01';

%% 2) Inspect
report = neuroqc.inspect.DatasetInspector.inspect(EEG); %#ok<NASGU>
eventReport = neuroqc.inspect.EventInspector.inspect(EEG);
neuroqc.inspect.EventInspector.summary(eventReport);

%% 3) Analysis Contract
contract = neuroqc.contract.AnalysisContract();
contract.subject = subject;
contract.paradigm = 'oddball';
contract = contract.addCondition('target', {'s1002'}, 'oddball target');
contract = contract.addCondition('standard', {'s1001'}, 'oddball standard');
contract = contract.setEpoch(-0.2, 1.0);
contract = contract.setBaseline(-0.2, 0);
contract = contract.addComponent('P300', [0.30 0.60], {'Pz','Cz'}, 'mean');
contract.summary();

%% 4) Search space: ONLY high-pass differs
space = neuroqc.pipeline.SearchSpace.defaultERP();
space.resample = {[]};
space.highpass = {0.1, 0.5, 1.0};
space.lowpass = {30};
space.reference = {'original'};
space.badChannel = {'none'};
space.interpolate = {false};
space.ica = {false};
space.artifactThresholdUv = {100};

outDir = fullfile(root, 'results', ['first_exp_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
opts = struct('selectedSteps',{{'filter','epoch','baseline','artifact_reject'}},'trialSelection',struct('mode','all'),'dataUnit', 'V', 'outputDir', outDir, ...
    'orderMode', 'set', ...
    'stepOrder', {{'filter','reref','badchannel','epoch','artifact_reject','baseline'}});
out = neuroqc.advice.RecommendPath.run(EEG, contract, space, opts);

fprintf('\nRecommended %d recipes under:\n  %s\n', numel(out.pipelines), out.recipesDir);
for k = 1:numel(out.pipelines)
    hp = out.pipelines(k).metadata.candidate.highpass;
    fprintf('  %s  HP=%.1f  steps=%s\n', out.pipelines(k).id, hp, ...
        strjoin({out.pipelines(k).steps.type}, '>'));
end

%% 5) Export one recipe snippet for EEGLAB
if ~isempty(out.pipelines)
    script = neuroqc.advice.EEGLABRecipe.fromPipeline(out.pipelines(1), contract, opts);
    fid = fopen(fullfile(root, 'examples', 'first_experiment_export.m'), 'w');
    fwrite(fid, script, 'char');
    fclose(fid);
    fprintf('\nWrote examples/first_experiment_export.m (run inside EEGLAB).\n');
end

fprintf('Done.\n');
