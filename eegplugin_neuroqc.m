function v = eegplugin_neuroqc(fig, try_strings, catch_strings)
%EEGPLUGIN_NEUROQC EEGLAB plugin: Tools > NeuroQC.
%   Keeps EEGLAB's own try/catch strings so that steps NeuroQC applies to
%   the current dataset go through exactly the same code path (history,
%   ALLCOM, new dataset, redraw) as EEGLAB's menus.
addpath(fileparts(mfilename('fullpath')));
v = neuroqc.NeuroQC.version();   % the one version number (NeuroQC.Version)
if nargin >= 3 && isstruct(try_strings) && isstruct(catch_strings)
    setappdata(0, 'neuroqc_eeglab_strings', struct('try_strings', try_strings, 'catch_strings', catch_strings));
end
tools = findobj(fig, 'tag', 'tools');
if isempty(tools) || ~isempty(findobj(tools, 'Tag', 'neuroqc_menu')), return; end
m = uimenu(tools, 'Label', 'NeuroQC', 'Separator', 'on', 'Tag', 'neuroqc_menu', 'userdata', 'startup:on;study:off');
uimenu(m, 'Label', 'Optimize from current dataset...', 'userdata', 'startup:on;study:off', ...
    'Callback', 'neuroqc.NeuroQC.app();');
uimenu(m, 'Label', 'Show dataset state and history', 'userdata', 'startup:off;study:off', ...
    'Callback', 'neuroqc.NeuroQC.state();');
end
