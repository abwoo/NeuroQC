function log(fmt, varargin)
%LOG Print a NeuroQC message to the MATLAB Command Window.
%   Every NeuroQC action reports here, so the Command Window always shows
%   what was run, with which parameters, and what happened.
fprintf('[NeuroQC] %s\n', sprintf(fmt, varargin{:}));
end
