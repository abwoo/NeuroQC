function log(fmt, varargin)
%LOG Print a PipeCompare message to the MATLAB Command Window.
%   Every PipeCompare action reports here, so the Command Window always shows
%   what was run, with which parameters, and what happened.
fprintf('[PipeCompare] %s\n', sprintf(fmt, varargin{:}));
end
