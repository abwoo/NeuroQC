% NeuroQC GUI launch (uifigure wizard)
% Requires NeuroQC on the MATLAB path.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
eeg = [];
if evalin('base', 'exist(''EEG'',''var'')')
    eeg = evalin('base', 'EEG');
end
app = neuroqc.gui.NeuroQCApp(eeg);
app.launch();
