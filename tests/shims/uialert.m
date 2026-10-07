function uialert(fig, message, title, varargin)
%UIALERT Test stand-in for MATLAB's uialert, used only by CI on MATLAB
%   R2022b and R2023a: there MATLAB's own uialert never returns on the test
%   machines' virtual display, even on an empty uifigure. The message is
%   printed instead; everything else in the tests is unchanged.
assert(isvalid(fig), 'uialert: invalid figure');
fprintf('[uialert] %s: %s\n', title, message);
end
