classdef uiprogressdlg < handle
%UIPROGRESSDLG Test stand-in for MATLAB's uiprogressdlg, used only by CI on
%   MATLAB R2022b and R2023a, where dialogs drawn inside a uifigure (as
%   uialert) never return on the test machines' virtual display. It keeps
%   the same properties, closes with close() and goes with its figure.
    properties
        Title = ''
        Message = ''
        Value = 0
        Indeterminate = 'off'
        Cancelable = 'off'
        CancelText = 'Cancel'
        ShowPercentage = 'off'
        Icon = ''
        Interpreter = 'none'
        CancelRequested = false
    end
    properties (Access = private)
        Listener
    end
    methods
        function obj = uiprogressdlg(fig, varargin)
            assert(isvalid(fig), 'uiprogressdlg: invalid figure');
            for k = 1:2:numel(varargin), obj.(varargin{k}) = varargin{k + 1}; end
            obj.Listener = addlistener(fig, 'ObjectBeingDestroyed', @(~, ~) delete(obj));
        end
        function close(obj)
            delete(obj);
        end
        function delete(obj)
            if ~isempty(obj.Listener), delete(obj.Listener); end
        end
    end
end
