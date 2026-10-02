function neuroqc_setup(eeglabRoot)
%NEUROQC_SETUP Put NeuroQC on the path and register it with a running EEGLAB.
%   Copying this folder into eeglab/plugins/ makes EEGLAB load it
%   automatically; otherwise call neuroqc_setup once per session.
addpath(fileparts(mfilename('fullpath')));
if nargin > 0 && ~isempty(eeglabRoot), addpath(eeglabRoot); end
assert(exist('eeglab', 'file') == 2, 'NeuroQC:Dependency', 'Add the EEGLAB folder to the path first.');
fig = findobj(groot, 'Type', 'figure', 'Tag', 'EEGLAB');
if isempty(fig)
    eeglab; % EEGLAB scans plugins; NeuroQC registers itself if installed under plugins/
    fig = findobj(groot, 'Type', 'figure', 'Tag', 'EEGLAB');
end
if ~isempty(fig) && isempty(findobj(fig, 'Tag', 'neuroqc_menu'))
    eegplugin_neuroqc(fig(1), [], []);
end
fprintf('[NeuroQC] Ready: EEGLAB > Tools > NeuroQC, or neuroqc.NeuroQC.app()\n');
end
