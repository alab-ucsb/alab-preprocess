function [] = sess2Drm(sess)

for sn = 1 : size(sess,2)
    
    xrange = [sess(sn).minx sess(sn).maxx];
    yrange = [sess(sn).miny sess(sn).maxy];

    for nn = 1 : size(sess(sn).neu,2)
                clear n n2
                
                n = histcounts2(sess(sn).neu(nn).sx, sess(sn).neu(nn).sy,...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                
                n2 = histcounts2(sess(sn).x, sess(sn).y,...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                
                sess(sn).neu(nn).twod.rm = (n./n2).*sess(sn).info.bsF;
                sess(sn).neu(nn).twod.rmsm = smoothdata2(sess(sn).neu(nn).twod.rm,'gaussian',3);
                sess(sn).neu(nn).twod.params.xbins = min(xrange(:,1)):3:max(xrange(:,2)); 
                sess(sn).neu(nn).twod.params.ybins = min(yrange(:,1)):3:max(yrange(:,2)); 
                
                clear aind bind iB*
                aind = 1 : floor(length(sess(sn).x)./2);
                bind = floor(length(sess(sn).x)./2)+1:length(sess(sn).x);
                
                % First half
                iA = ismember(neu(nn).sess(sn).spkind(:), aind(:));
                clear n n2
                n = histcounts2(neu(nn).sess(sn).spk_x(iA),neu(nn).sess(sn).spk_y(iA),...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                n2 = histcounts2(sess(sn).x(aind),sess(sn).y(aind),...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                neu(nn).sess(sn).twod.arm = (n./n2).*30;
                neu(nn).sess(sn).twod.armsm = smoothdata2(neu(nn).sess(sn).twod.arm,'gaussian',3);
                
                % Second half
                iA2 = ismember(neu(nn).sess(sn).spkind(:), bind(:));
                clear n n2
                n = histcounts2(neu(nn).sess(sn).spk_x(iA2),neu(nn).sess(sn).spk_y(iA2),...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                n2 = histcounts2(sess(sn).x(bind),sess(sn).y(bind),...
                    'XBinEdges',min(xrange(:,1)):3:max(xrange(:,2)), 'YBinEdges',min(yrange(:,1)):3:max(yrange(:,2)));
                neu(nn).sess(sn).twod.brm = (n./n2).*30;
                neu(nn).sess(sn).twod.brmsm = smoothdata2(neu(nn).sess(sn).twod.brm,'gaussian',3);
    
                neu(nn).sess(sn).twod.cor = corr(neu(nn).sess(sn).twod.arm(:),...
                    neu(nn).sess(sn).twod.brm(:),'rows','complete','type','spearman');      
    end
end