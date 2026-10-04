function v = eegplugin_pipecompare(fig, try_strings, catch_strings)
%EEGPLUGIN_PIPECOMPARE EEGLAB plugin: Tools > PipeCompare.
%   Installed under eeglab/plugins/, EEGLAB puts this folder on the path
%   and calls this function at every start. Keeps EEGLAB's own try/catch
%   strings so that steps PipeCompare applies to the current dataset go
%   through exactly the same code path (history, ALLCOM, new dataset,
%   redraw) as EEGLAB's menus, and wraps the menu callbacks in them, so an
%   error shows EEGLAB's usual error window.
v = pipecompare.PipeCompare.version();   % the one version number (PipeCompare.Version)
tryStr = 'try,';
if nargin >= 3 && isstruct(try_strings) && isstruct(catch_strings)
    setappdata(0, 'pipecompare_eeglab_strings', struct('try_strings', try_strings, 'catch_strings', catch_strings));
    tryStr = try_strings.no_check;
end
wrap = @(cmd) [tryStr ' ' cmd ' catch, eeglab_error; end;'];
tools = findobj(fig, 'tag', 'tools');
if isempty(tools) || ~isempty(findobj(tools, 'Tag', 'pipecompare_menu')), return; end
m = uimenu(tools, 'Label', 'PipeCompare', 'Separator', 'on', 'Tag', 'pipecompare_menu', 'userdata', 'startup:on;study:off');
uimenu(m, 'Label', 'Compare pipelines...', 'userdata', 'startup:off;study:off', ...
    'Callback', wrap('[EEG, LASTCOM] = pop_pipecompare(EEG); if ~isempty(LASTCOM), eegh(LASTCOM); end;'));
uimenu(m, 'Label', 'Advanced panel...', 'userdata', 'startup:on;study:off', ...
    'Callback', wrap('pipecompare.PipeCompare.app();'));
uimenu(m, 'Label', 'Show dataset state and history', 'userdata', 'startup:off;study:off', ...
    'Callback', wrap('pipecompare.PipeCompare.state();'));
end
