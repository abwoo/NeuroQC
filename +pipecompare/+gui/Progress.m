classdef Progress < handle
    %PROGRESS Progress window of a search, with Stop.
    %
    %   p = pipecompare.gui.Progress(nTotal, hasIca);
    %   opts.progress = @(n, varargin) p.step(n, varargin{:});   % the Executor's progress callback
    %
    %   Shows how many pipelines are done, the step running now, the time so
    %   far (updated every second) and the time left, a bar and Stop, all in
    %   one window (not a progress box drawn inside another window); until
    %   the first pipeline is done (it alone runs the shared steps, ICA
    %   included) a short block moves along the bar instead of a fill
    %   level. Stop (or closing the window) asks the search to stop after
    %   the current step, keeping the pipelines already finished. Used by
    %   the simple mode and the panel. delete(p) closes the window.

    properties
        Fig
        Message           % the text: pipelines done, the step now, the time
        Track; Fill       % the bar: its background and its filled part
        StopButton
        Timer
        NTotal
        NDone = 0
        Value = 0         % the fraction of the bar filled
        Indeterminate = true
        Tick = 0          % where the moving block is while Indeterminate
        CancelRequested = false
        First = ''        % what happens before the first pipeline is done
        Step = ''         % the step running now, in words
        T0                % tic when the window opened
        T1 = []           % tic when the first pipeline finished
    end

    methods
        function obj = Progress(nTotal, hasIca)
            obj.NTotal = nTotal;
            obj.T0 = tic;
            obj.First = 'the first one runs every step from the start';
            if hasIca, obj.First = 'ICA is fitted first (once; the slow part)'; end
            obj.Fig = uifigure('Name', 'PipeCompare: comparing pipelines', ...
                'Position', pipecompare.utils.onScreen([300 300 520 190]), 'CloseRequestFcn', @(~, ~) obj.requestStop());
            g = uigridlayout(obj.Fig, [3 1]); g.RowHeight = {'1x', 12, 30}; g.Padding = [20 16 20 16]; g.RowSpacing = 14;
            obj.Message = uilabel(g, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top');
            obj.Track = uipanel(g, 'BorderType', 'none', 'BackgroundColor', [0.78 0.78 0.78]);
            obj.Fill = uipanel(obj.Track, 'BorderType', 'none', 'BackgroundColor', [0.26 0.58 0.95], 'Position', [0 0 1 12]);
            b = uigridlayout(g, [1 2]); b.Padding = [0 0 0 0]; b.ColumnWidth = {'1x', 110};
            uilabel(b, 'Text', '');
            obj.StopButton = uibutton(b, 'Text', 'Stop', 'ButtonPushedFcn', @(~, ~) obj.requestStop());
            obj.refresh();
            % the time so far keeps moving while a long step (e.g. ICA) runs
            obj.Timer = timer('Name', 'PipeCompare progress', 'Period', 1, 'ExecutionMode', 'fixedSpacing', ...
                'BusyMode', 'drop', 'TimerFcn', @(~, ~) refreshIfOpen(obj));
            start(obj.Timer);
        end

        function delete(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer), stop(obj.Timer); delete(obj.Timer); end
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        function requestStop(obj)
            % Stop, or closing the window: the search stops after the
            % current step; the window stays until the search has stopped
            obj.CancelRequested = true;
            obj.refresh();
        end

        function stop = step(obj, n, in)
            % n more pipelines are finished (0 = only asking); in: the step
            % that starts now (optional)
            if isempty(obj.Fig) || ~isvalid(obj.Fig), stop = true; return; end   % the window is gone: stop as well
            obj.NDone = obj.NDone + n;
            if nargin > 2
                try, obj.Step = pipecompare.gui.Progress.stepText(in); catch, obj.Step = ''; end   % never stops a search
            end
            if n > 0 && ~obj.CancelRequested
                % the time after the first pipeline: it alone runs the shared
                % steps (ICA included), so it would inflate the estimate
                if isempty(obj.T1), obj.T1 = tic; obj.Indeterminate = false; end
                obj.Value = min(1, obj.NDone / obj.NTotal);
            end
            obj.refresh();
            drawnow;
            stop = obj.CancelRequested;
        end

        function refresh(obj)
            % the window's text and bar: pipelines done, the step now, the time so far
            if isempty(obj.Fig) || ~isvalid(obj.Fig), return; end
            if obj.CancelRequested
                obj.Message.Text = 'Stopping after the current step...';
                obj.StopButton.Enable = 'off';
            else
                if obj.NDone == 0
                    done = sprintf('Running %d pipelines; %s.', obj.NTotal, obj.First);
                elseif obj.NDone >= obj.NTotal
                    done = 'All pipelines done; ranking them...';
                elseif obj.NDone < 3
                    done = sprintf('%d of %d pipelines done; estimating the time left...', obj.NDone, obj.NTotal);
                else
                    done = sprintf('%d of %d pipelines done, about %s left.', obj.NDone, obj.NTotal, ...
                        pipecompare.gui.Progress.timeText(toc(obj.T1) / (obj.NDone - 1) * (obj.NTotal - obj.NDone)));
                end
                msg = {done};
                if ~isempty(obj.Step) && obj.NDone < obj.NTotal, msg{end+1} = ['Now: ' obj.Step]; end
                msg{end+1} = sprintf('Time so far: %s. Stop keeps the finished pipelines.', ...
                    pipecompare.gui.Progress.clockText(toc(obj.T0)));
                obj.Message.Text = msg;
            end
            % the bar: a fill level, or a block moving along it
            w = obj.Track.InnerPosition(3); h = obj.Track.InnerPosition(4);
            if obj.Indeterminate
                obj.Tick = mod(obj.Tick + 1, 5);
                obj.Fill.Position = [round(obj.Tick * w / 5) 0 max(1, round(w / 5)) h];
            else
                obj.Fill.Position = [0 0 max(1, round(obj.Value * w)) h];
            end
            drawnow nocallbacks;
        end
    end

    methods (Static)
        function t = timeText(sec)
            % 'about 40 s', '12 min', '2 h 10 min'
            % (whole minutes first, so 59.5 min reads 1 h 0 min, not 60 min)
            m = round(sec / 60);
            if sec < 90, t = sprintf('%.0f s', sec);
            elseif m < 60, t = sprintf('%d min', m);
            else, t = sprintf('%d h %d min', floor(m / 60), mod(m, 60)); end
        end

        function t = clockText(sec)
            % '45 s', '6 min 12 s', '1 h 3 min': the time so far, to the second
            s = floor(sec);
            if s < 60, t = sprintf('%d s', s);
            elseif s < 3600, t = sprintf('%d min %d s', floor(s / 60), mod(s, 60));
            else, t = sprintf('%d h %d min', floor(s / 3600), mod(floor(s / 60), 60)); end
        end

        function t = stepText(in)
            % the step that runs now, in words (the plan's label for the others)
            p = in.params;
            switch in.type
                case 'highpass', t = sprintf('high-pass filter %g Hz', p.cutoff);
                case 'lowpass', t = sprintf('low-pass filter %g Hz', p.cutoff);
                case 'linenoise', t = 'removing line noise';
                case 'resample', t = 'resampling';
                case 'asr', t = 'ASR burst correction';
                case 'badchannels', t = 'finding bad channels';
                case 'restore', t = 'restoring removed channels';
                case 'reref', t = 're-referencing';
                case 'ica', t = 'fitting ICA (the slow part)';
                case 'icremove', t = 'ICLabel: removing artifact components';
                case 'epoch', t = 'cutting epochs';
                case 'baseline', t = 'removing the baseline';
                case {'reject_threshold', 'reject_jointprob', 'reject_kurtosis'}, t = 'rejecting bad epochs';
                otherwise, t = in.label;
            end
        end
    end
end

function refreshIfOpen(obj)
% the timer's call: nothing (and no error message) once the window is gone
try
    if isvalid(obj), obj.refresh(); end
catch
end
end
