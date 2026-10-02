% Recommend discrete preprocessing recipes (generate-only).
% Execution stays in EEGLAB: open recipe_*.m under recipes/ there.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root);
[EEG,~]=neuroqc.inspect.SyntheticEEG.generate(struct('durationSec',60,'nTarget',20,'nStandard',40));
c=neuroqc.contract.AnalysisContract();
c=c.addCondition('target',{'s1002'},'Target stimulus');
c=c.addCondition('standard',{'s1001'},'Standard stimulus');
c=c.addComponent('P300',[0.3 0.6],{'Pz','Cz'},'mean');
s=neuroqc.pipeline.SearchSpace.defaultERP();
s.resample={[]}; s.highpass={0.1,0.5}; s.lowpass={20,30};
s.reference={'original'}; s.badChannel={'none'}; s.interpolate={false};
s.ica={false}; s.artifactThresholdUv={100,120};
outDir=fullfile(root,'results',['demo_recipes_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
opts=struct('selectedSteps',{{'filter','epoch','baseline','artifact_reject'}},'trialSelection',struct('mode','all'),'dataUnit','V','outputDir',outDir, ...
    'completedStages',{{}},'orderMode','set', ...
    'stepOrder',{{'filter','notch','reref','epoch','baseline','artifact_reject'}});
out=neuroqc.advice.RecommendPath.run(EEG,c,s,opts);
disp(out.search);
fprintf('Recipes: %s (%d candidates)\n', out.recipesDir, numel(out.pipelines));
fprintf('Status without external QC: %s\n', out.status);
% Optional: supply metrics measured in EEGLAB:
% opts.externalQC = fullfile(outDir,'my_qc.csv');
% out = neuroqc.advice.RecommendPath.run(EEG,c,s,opts);
