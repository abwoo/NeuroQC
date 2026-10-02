classdef eeglabmenu
    % eeglabmenu - EEGLAB menu callbacks for NeuroQC (advisor path)

    methods (Static)
        function inspect()
            if ~evalin('base', 'exist(''EEG'',''var'')')
                errordlg('No EEG in workspace');
                return;
            end
            EEG = evalin('base', 'EEG');
            if isempty(EEG)
                errordlg('No EEG in workspace');
                return;
            end
            neuroqc.inspect.DatasetInspector.inspect(EEG);
            neuroqc.inspect.EventInspector.inspect(EEG);
        end

        function comparePipelines()
            neuroqc.gui.NeuroQCApp.launchWizardFromMenu();
        end

        function wizard()
            % Single wizard entry for define / recommend / resume / compare / import QC.
            neuroqc.gui.NeuroQCApp.launchWizardFromMenu();
        end

        function exportScript()
            % Open a recipe_*.m from the last recommend output (EEGLAB-side execution).
            if evalin('base','exist(''neuroqc_out'',''var'')')
                out=evalin('base','neuroqc_out');
                if isfield(out,'recipesDir') && isfolder(out.recipesDir)
                    listing=dir(fullfile(out.recipesDir,'recipe_*.m'));
                    if isempty(listing)
                        errordlg('No recipe scripts in output folder.');
                        return;
                    end
                    names={listing.name};
                    [ix,ok]=listdlg('PromptString','Open recipe:','ListString',names,'SelectionMode','single');
                    if ~ok, return; end
                    edit(fullfile(out.recipesDir,names{ix}));
                    return;
                end
            end
            errordlg('Run Recommend first; recipes are saved under recipes/.');
        end

        function openRecipes()
            if evalin('base','exist(''neuroqc_out'',''var'')')
                out=evalin('base','neuroqc_out');
                if isfield(out,'recipesDir') && isfolder(out.recipesDir)
                    open(out.recipesDir);
                    return;
                end
            end
            errordlg('Run Recommend first; recipes folder not found.');
        end

        function loadRecommended()
            neuroqc.eeglabmenu.openRecipes();
        end

        function about()
            msgbox(sprintf(['NeuroQC %s\nDiscrete recipe advisor for EEGLAB.\n' ...
                'Processing runs in EEGLAB; import QC to rank.\nCandidates remain REVIEW.'], ...
                neuroqc.NeuroQC.version()), 'NeuroQC');
        end

        function checkpoint()
            if ~evalin('base', 'exist(''EEG'',''var'')')
                errordlg('No EEG in workspace');
                return;
            end
            EEG = evalin('base', 'EEG');
            if isempty(EEG)
                errordlg('No EEG in workspace');
                return;
            end
            neuroqc.gui.CheckpointDialog.open(EEG);
        end

        function captureLastAction()
            if ~evalin('base', 'exist(''EEG'',''var'')')
                errordlg('No EEG in workspace');
                return;
            end
            EEG = evalin('base', 'EEG');
            if isempty(EEG)
                errordlg('No EEG in workspace');
                return;
            end
            neuroqc.gui.CheckpointDialog.captureLastAction(EEG);
        end
    end
end
