function r=workflowQC(before,after,type,p)
    r=struct('status','PASS','metrics',p,'warnings',{{}},'recommendations',{{}});
    assert(all(isfinite(after.data),'all'),'NeuroQC:NonFinite','Nonfinite output');
    switch type
        case 'remove_bad'
            r.metrics.channelCount=after.nbchan;
            if p.removedRatio>0.3, r.status='FAIL'; end
        case 'restore_channels'
            r=neuroqc.qc.interpolateQC(before,after,p);
        case 'reject_continuous'
            if p.removedFraction>0.3, r.status='REVIEW'; end
        case 'notch'
            r.metrics.eventCountPreserved = numel(before.event) == numel(after.event);
            if ~r.metrics.eventCountPreserved
                r.status = 'FAIL';
                r.warnings{end+1} = sprintf('Notch changed event count (%d -> %d)', ...
                    numel(before.event), numel(after.event));
            end
    end
end
