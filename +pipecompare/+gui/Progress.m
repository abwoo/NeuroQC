classdef Progress < handle
    %PROGRESS Progress window of a search, with Stop.
    %
    %   p = pipecompare.gui.Progress(nTotal, hasIca);
    %   opts.progress = @p.step;    % the Executor's progress callback
    %
    %   Shows how many pipelines are done and the time left; Stop (or
    %   closing the window) asks the search to stop after the current step,
    %   keeping the pipelines already finished. Used by the simple mode and
    %   the panel. delete(p) closes the window.

    properties
        Fig
        Dlg
        NTotal
        NDone = 0
        T1 = []           % tic when the first pipeline finished
        Stopping = false
    end

    methods
        function obj = Progress(nTotal, hasIca)
            obj.NTotal = nTotal;
            first = 'the first one runs every step from the start';
            if hasIca, first = 'ICA is fitted first (once; the slow part)'; end
            obj.Fig = uifigure('Name', 'PipeCompare', 'Position', [300 300 460 150]);
            obj.Dlg = uiprogressdlg(obj.Fig, 'Title', 'Comparing pipelines', 'Cancelable', 'on', 'CancelText', 'Stop', ...
                'Message', sprintf('Running %d pipelines; %s.', nTotal, first));
        end

        function delete(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end

        function stop = step(obj, n)
            % n more pipelines are finished (0 = only asking)
            if ~isvalid(obj.Fig) || ~isvalid(obj.Dlg), stop = true; return; end   % the window was closed: stop as well
            dlg = obj.Dlg;
            obj.NDone = obj.NDone + n;
            if n > 0 && ~obj.Stopping
                % the time after the first pipeline: it alone runs the shared
                % steps (ICA included), so it would inflate the estimate
                if isempty(obj.T1), obj.T1 = tic; end
                dlg.Value = min(1, obj.NDone / obj.NTotal);
                if obj.NDone >= obj.NTotal
                    dlg.Message = 'All pipelines done; ranking them...';
                elseif obj.NDone < 3
                    dlg.Message = sprintf('%d of %d pipelines done; estimating the time left...', obj.NDone, obj.NTotal);
                else
                    dlg.Message = sprintf('%d of %d pipelines done, about %s left. Stop keeps the finished ones.', ...
                        obj.NDone, obj.NTotal, pipecompare.gui.Progress.timeText(toc(obj.T1) / (obj.NDone - 1) * (obj.NTotal - obj.NDone)));
                end
            end
            drawnow;
            stop = dlg.CancelRequested;
            if stop && ~obj.Stopping, obj.Stopping = true; dlg.Message = 'Stopping after the current step...'; drawnow; end
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
    end
end
