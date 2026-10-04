function pipecompare_setup(eeglabRoot)
%PIPECOMPARE_SETUP Put PipeCompare on the path and register it with a running EEGLAB.
%   For development from a folder outside eeglab/plugins/. The normal
%   installation is to copy this folder into eeglab/plugins/: EEGLAB then
%   adds the menu itself at every start.
%   Calling eeglab again rebuilds EEGLAB's menus and drops the PipeCompare
%   menu added here: call pipecompare_setup again after each eeglab call.
addpath(fileparts(mfilename('fullpath')));
if nargin > 0 && ~isempty(eeglabRoot), addpath(eeglabRoot); end
assert(exist('eeglab', 'file') == 2, 'PipeCompare:Dependency', 'Add the EEGLAB folder to the path first.');
fig = findobj(groot, 'Type', 'figure', 'Tag', 'EEGLAB');
if isempty(fig)
    eeglab; % EEGLAB scans plugins; PipeCompare registers itself if installed under plugins/
    fig = findobj(groot, 'Type', 'figure', 'Tag', 'EEGLAB');
end
if ~isempty(fig) && isempty(findobj(fig, 'Tag', 'pipecompare_menu'))
    eegplugin_pipecompare(fig(1), [], []);
end
fprintf('[PipeCompare] Ready: EEGLAB > Tools > PipeCompare, or pipecompare.PipeCompare.app()\n');
end
