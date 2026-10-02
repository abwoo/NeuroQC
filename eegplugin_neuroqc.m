function v = eegplugin_neuroqc(fig, try_strings, catch_strings) %#ok<INUSD>
%eegplugin_neuroqc EEGLAB plugin entry point for NeuroQC
%   Lives at NeuroQC/ root (or NeuroQC/plugin/) so EEGLAB can auto-discover it.
%
%   Usage: v = eegplugin_neuroqc(fig, try_strings, catch_strings)
%   Returns the NeuroQC version string for the EEGLAB plugin manager.
%   Menu activation keywords (userdata) follow the EEGLAB menu integration
%   scheme: items that need an EEG dataset stay disabled at startup, while
%   standalone entries (Wizard / Recipe / About) are enabled at startup.

    if nargin < 3
        error('eegplugin_neuroqc requires 3 arguments');
    end

    addpath(fileparts(mfilename('fullpath')));
    v = '0.6.0';
    try
        v = neuroqc.NeuroQC.version();
    catch
    end
    tools = findobj(fig, 'tag', 'tools');
    if isempty(tools)
        return;
    end

    if ~isempty(findobj(tools,'Tag','neuroqc_menu')), return; end
    submenu = uimenu(tools, 'label', 'NeuroQC', 'separator', 'on','Tag','neuroqc_menu', ...
        'userdata', 'startup:on;study:on');
    uimenu(submenu, 'label', ['Inspector v' v], ...
        'callback', 'neuroqc.eeglabmenu.inspect()');
    uimenu(submenu, 'label', 'Wizard...', ...
        'callback', 'neuroqc.eeglabmenu.wizard()', 'userdata', 'startup:on;study:on');
    uimenu(submenu, 'label', 'Checkpoint...', ...
        'callback', 'neuroqc.eeglabmenu.checkpoint()');
    uimenu(submenu, 'label', 'Capture last action...', ...
        'callback', 'neuroqc.eeglabmenu.captureLastAction()');
    uimenu(submenu, 'label', 'Recipe script...', ...
        'callback', 'neuroqc.eeglabmenu.exportScript()', 'userdata', 'startup:on;study:on');
    uimenu(submenu, 'label', 'Recipes folder', ...
        'callback', 'neuroqc.eeglabmenu.openRecipes()', 'userdata', 'startup:on;study:on');
    uimenu(submenu, 'label', 'About', ...
        'callback', 'neuroqc.eeglabmenu.about()', 'userdata', 'startup:on;study:on');
end
