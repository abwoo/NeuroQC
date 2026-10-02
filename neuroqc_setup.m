function neuroqc_setup(eeglabRoot)
% Add only package root; never genpath (results contain replay scripts).
root=fileparts(mfilename('fullpath')); addpath(root);
if nargin>0 && ~isempty(eeglabRoot), addpath(eeglabRoot); end
assert(exist('eeglab','file')~=0,'NeuroQC:Dependency','Add the EEGLAB root first');
eeglab;
figs=findall(groot,'Type','figure');
for k=1:numel(figs)
    if ~isempty(findobj(figs(k),'Tag','tools')), eegplugin_neuroqc(figs(k),[],[]); end
end
fprintf('NeuroQC ready: EEGLAB > Tools > NeuroQC. Path: %s\n',root);
end
