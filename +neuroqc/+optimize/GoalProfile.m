classdef GoalProfile
    % GoalProfile - Named set of ObjectiveSpec for GoalRanker scalarization.
    % Default profiles do NOT enable preservation objectives (user decision).

    properties
        name
        objectives   % neuroqc.optimize.ObjectiveSpec vector
        enablePreservationObjectives  % default false
    end

    methods
        function obj = GoalProfile(name, objectives)
            if nargin < 1, name = 'custom'; end
            if nargin < 2, objectives = neuroqc.optimize.ObjectiveSpec.empty(); end
            obj.name = char(name);
            obj.objectives = objectives;
            obj.enablePreservationObjectives = false;
            obj.validate();
        end

        function validate(obj)
            if isempty(obj.objectives)
                error('NeuroQC:GoalProfileEmpty', 'GoalProfile must contain at least one objective');
            end
            names = {obj.objectives.name};
            if numel(unique(names)) ~= numel(names)
                error('NeuroQC:GoalProfileDuplicate', 'Objective names must be unique');
            end
            for k = 1:numel(obj.objectives)
                obj.objectives(k).validate();
            end
            if ~islogical(obj.enablePreservationObjectives) && ...
                    ~(isnumeric(obj.enablePreservationObjectives) && isscalar(obj.enablePreservationObjectives))
                error('NeuroQC:GoalProfileFlag', 'enablePreservationObjectives must be logical');
            end
        end

        function en = enabledObjectives(obj)
            en = obj.objectives([obj.objectives.enabled]);
            if ~obj.enablePreservationObjectives
                pref = {'topoFidelity','latencyShiftMs','amplitudeError','bandEnergyError'};
                keep = true(size(en));
                for k = 1:numel(en)
                    if any(strcmp(en(k).metricKey, pref)), keep(k) = false; end
                end
                en = en(keep);
            end
            if isempty(en)
                error('NeuroQC:GoalProfileNoEnabled', 'No enabled objectives remain after profile filtering');
            end
            w = [en.weight];
            if ~any(w > 0)
                error('NeuroQC:GoalProfileZeroWeight', 'At least one objective weight must be > 0');
            end
        end

        function s = toStruct(obj)
            s = struct('name', obj.name, ...
                'enablePreservationObjectives', logical(obj.enablePreservationObjectives), ...
                'objectives', {arrayfun(@(o) o.toStruct(), obj.objectives)});
        end
    end

    methods (Static)
        function p = balanced()
            o = neuroqc.optimize.ObjectiveSpec.empty();
            o(end+1) = neuroqc.optimize.ObjectiveSpec('reliability','reliability','max',1);
            o(end+1) = neuroqc.optimize.ObjectiveSpec('retention','retention','max',1);
            o(end+1) = neuroqc.optimize.ObjectiveSpec('topoStability','topoStability','max',1);
            o(end+1) = neuroqc.optimize.ObjectiveSpec('waveformDistortion','waveformDistortion','min',1);
            o(end+1) = neuroqc.optimize.ObjectiveSpec('interpRatio','interpRatio','min',1);
            p = neuroqc.optimize.GoalProfile('balanced', o);
        end

        function p = minimalRetention()
            b = neuroqc.optimize.GoalProfile.balanced();
            for k = 1:numel(b.objectives)
                switch b.objectives(k).name
                    case {'retention','minConditionRetention'}
                        b.objectives(k).weight = 3;
                    case 'interpRatio'
                        b.objectives(k).weight = 2;
                    otherwise
                        b.objectives(k).weight = 0.5;
                end
            end
            b.name = 'minimalRetention';
            b.validate();
            p = b;
        end

        function p = minimalDistortion()
            b = neuroqc.optimize.GoalProfile.balanced();
            for k = 1:numel(b.objectives)
                switch b.objectives(k).name
                    case 'waveformDistortion'
                        b.objectives(k).weight = 3;
                    case 'reliability'
                        b.objectives(k).weight = 2;
                    otherwise
                        b.objectives(k).weight = 0.5;
                end
            end
            b.name = 'minimalDistortion';
            b.validate();
            p = b;
        end

        function p = topoStability()
            b = neuroqc.optimize.GoalProfile.balanced();
            for k = 1:numel(b.objectives)
                switch b.objectives(k).name
                    case 'topoStability'
                        b.objectives(k).weight = 3;
                    otherwise
                        b.objectives(k).weight = 1;
                end
            end
            b.name = 'topoStability';
            b.validate();
            p = b;
        end

        function p = fromJSON(filepath)
            s = jsondecode(fileread(filepath));
            objs = neuroqc.optimize.ObjectiveSpec.empty();
            raw = s.objectives;
            if isstruct(raw), raw = num2cell(raw); end
            for k = 1:numel(raw)
                objs(end+1) = neuroqc.optimize.ObjectiveSpec.fromStruct(raw{k}); %#ok<AGROW>
            end
            p = neuroqc.optimize.GoalProfile(s.name, objs);
            if isfield(s,'enablePreservationObjectives')
                p.enablePreservationObjectives = logical(s.enablePreservationObjectives);
            end
            p.validate();
        end

        function p = resolve(profile)
            % Accept GoalProfile, char preset name, struct, or [] -> balanced
            if nargin < 1 || isempty(profile)
                p = neuroqc.optimize.GoalProfile.balanced();
            elseif isa(profile, 'neuroqc.optimize.GoalProfile')
                p = profile;
                p.validate();
            elseif ischar(profile) || isstring(profile)
                switch lower(char(profile))
                    case 'balanced', p = neuroqc.optimize.GoalProfile.balanced();
                    case 'minimalretention', p = neuroqc.optimize.GoalProfile.minimalRetention();
                    case 'minimaldistortion', p = neuroqc.optimize.GoalProfile.minimalDistortion();
                    case 'topostability', p = neuroqc.optimize.GoalProfile.topoStability();
                    otherwise
                        error('NeuroQC:GoalProfileUnknown', 'Unknown profile name: %s', char(profile));
                end
            elseif isstruct(profile)
                p = neuroqc.optimize.GoalProfile.balanced();
                p.name = profile.name;
                objs = neuroqc.optimize.ObjectiveSpec.empty();
                raw = profile.objectives;
                if isstruct(raw), raw = num2cell(raw); end
                for k = 1:numel(raw)
                    objs(end+1) = neuroqc.optimize.ObjectiveSpec.fromStruct(raw{k}); %#ok<AGROW>
                end
                p.objectives = objs;
                if isfield(profile,'enablePreservationObjectives')
                    p.enablePreservationObjectives = logical(profile.enablePreservationObjectives);
                end
                p.validate();
            else
                error('NeuroQC:GoalProfileType', 'Unsupported profile type');
            end
        end
    end
end
