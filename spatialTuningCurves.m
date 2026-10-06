function [] = spatialTuningCurves(sess, hd)

 
numSess = size(sess,2);
numPlots = 4;

for n = 1 : size(sess(1).neu,2)
    figure(1); clf(1);

    for sn = 1 : numSess

        if isempty(sess(sn).score.ind)

            % Trajectory plot
            figure(1); subplot(1,numSess,sn);
            plot(sess(sn).x,sess(sn).y,'color',[.5 .5 .5],'LineWidth',1); axis tight; axis square;
            hold on;
            try
                if hd == 1
                    scatter(sess(sn).neu(n).sx, sess(sn).neu(n).sy, 10, sess(sn).neu(n).shd, 'filled');
                    figure(1); ax = subplot(1,numSess,sn);
                    colormap(ax,hsv)
                else
                    figure(1); subplot(numSess,numPlots,1);
                    scatter(sess(sn).neu(n).sx, sess(sn).neu(n).sy, 10, 'b', 'filled');
                end
            end

        else

            runs = [sess(sn).score.ind(1:2:end), sess(sn).score.ind(2:2:end)];
            runinds = nan(0,1);
            for r = 1 : size(runs,1)
                runinds = [runinds; [runs(r,1):runs(r,2)]'];
            end

            [~,spkruninds,~] = intersect(sess(sn).neu(n).spkind, runinds);

            % Trajectory plot
            figure(1); subplot(1,numSess,sn);
            plot(sess(sn).x(runinds),sess(sn).y(runinds),'color',[.5 .5 .5],'LineWidth',1); axis tight; axis square;
            hold on;
            try
                if hd == 1
                    scatter(sess(sn).neu(n).sx(spkruninds), sess(sn).neu(n).sy(spkruninds), 10,...
                        sess(sn).neu(n).shd(spkruninds), 'filled');
                    figure(1); ax = subplot(1,numSess,sn);
                    colormap(ax,hsv)
                else
                    figure(1); subplot(numSess,numPlots,1);
                    scatter(sess(sn).neu(n).sx(spkruninds), sess(sn).neu(n).sy(spkruninds), 10, 'b', 'filled');
                end
            end

        end


        % try
            figure(1); subplot(numSess,numPlots,2);

            minx = min(sess(s).x);
            maxx = max(sess(s).x);
            miny = min(sess(s).y);
            maxy = max(sess(s).y);
            n2 = histcounts2(sess(s).x,sess(s).y,minx:3:maxx,miny:3:maxy);
            ax = subplot(numSess,numPlots,2);
            imagesc(rot90(neu(n).sess(s).twodsm),'AlphaData', rot90(n2)>0);
            caxis([0 prctile(neu(n).sess(s).twodsm(:),99)])
            colormap(ax,parula); axis tight; axis square;
        % end

            figure(1);
            subplot(numSess,numPlots,3);
            plot(neu(n).sess(s).hdsm); axis tight; axis square;
            figure(1);
            subplot(numSess,numPlots,4);
            plotEgoRatemap(neu(n).sess(s).ebc.out);

    end
    % 
    % ax = subplot(1,numSe,1);
    % colormap(ax,hsv)


    pause; clf(1); %clf(2);
end




