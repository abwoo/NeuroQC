function pos = onScreen(pos)
%ONSCREEN A figure position [left bottom width height] that fits the
%   screen: at most the screen size less room for the title bar and the
%   task bar or Dock, and moved inside the screen (small laptop screens,
%   display scaling).
s = get(groot, 'ScreenSize');
if s(3) < 400 || s(4) < 300, return; end   % no real screen (e.g. matlab -batch)
pos(3) = min(pos(3), s(3) - 20);
pos(4) = min(pos(4), s(4) - 100);
pos(1) = max(s(1), min(pos(1), s(1) + s(3) - pos(3)));
pos(2) = max(s(2) + 40, min(pos(2), s(2) + s(4) - pos(4) - 60));
end
