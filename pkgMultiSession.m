% chzBrdBehavioralAnalysis
% Dependencies:
% CircStat: https://github.com/circstat/circstat-matlab
% OpenEphys : https://github.com/open-ephys/open-ephys-matlab-tools
% Egocentric Boundary Ratemaps : https://github.com/hasselmonians/EgocentricBoundaryCells/tree/master

%% Define paths and get files
clear all; clc; close all;

% Define path and file for position data
[sessfile, sesspath] = uigetfile('*.xlsx', 'Select sessions information spreadsheet')
recList = readtable(fullfile(sesspath,sessfile));
cd(sesspath)

% Define folder with concatenated KS output
kspath = uigetdir([],'Select KS output folder') %'D:\041625_A\rawnode';

naspath = 'Z:\'; % Change

% Loop through all recordings in this experiment.
for n = 1 : size(recList,1)
    %% Load continuous dat
    clear session rawrec rec data;

    % Use OEphys package to extract continuous data for all channels.
    session = Session(fullfile(naspath,recList.rawnode{n}));
    rawnode = 1;

    rawrec = session.recordNodes{rawnode};
    rec = rawrec.recordings{1,1};
    streamNames = rec.continuous.keys();
    sn = streamNames{1};
    data = rec.continuous(sn);

    %% Package length of recording so you can reattribute spikes to each
    % session.
    sess(n).info.startTime = data.metadata.startTimestamp;
    sess(n).info.numSamp = length(data.sampleNumbers);
    sess(n).info.indSamp = data.sampleNumbers;

    %% Load position data
    %% Load and clean position data
    if ~isempty(recList.dlc{n})
        clear pos* tempsess
        pos = readtable((fullfile(naspath,recList.path{n},recList.dlc{n})));
        btspath = fullfile(naspath,recList.path{n},recList.bTs{n})
        [tempsess] = behavPreprocess(pos, recList, n, btspath);
        sess(n).x = tempsess.x;
        sess(n).y = tempsess.y;
        sess(n).hd = tempsess.hd;
        sess(n).lv = tempsess.lv;
        sess(n).acc = tempsess.acc;
        sess(n).t = tempsess.t;
        sess(n).info.bsF = tempsess.bsF;
        
        % Max and min x,y vals.
        sess(n).minx = min(sess(n).x); 
        sess(n).maxx = max(sess(n).x);
        sess(n).miny = min(sess(n).y);
        sess(n).maxy = max(sess(n).y);
    else
        sess(n).x = [];
        sess(n).y = [];
        sess(n).hd = [];
        sess(n).lv = [];
        sess(n).acc = [];
        sess(n).t = [];
        sess(n).bsF = [];
    end

    %% Sync signals
    clear timeneu indneu
    sess(n).info.timeneu = data.timestamps;
    indneu = data.sampleNumbers;
    clear ttl* dTtlPos
    ttl = rec.ttlEvents(sn);
    
    %% Synchronize with LED strip TTL pulses;
    % Load video TTL roi_data (i.e. pulse train on IR LED strip)
    clear pxlint
    pxlint = load(fullfile(naspath,recList.path{n},recList.vidTTLout{n}));

    % Reconstruct the TTL inputs 
    LEDch = find(ttl.line==2);
    LEDttl = ttl(LEDch,:);
    [rcTtl,LEDind] = reconLEDTtlNeuralClock(LEDttl, sess(n).info.indSamp, sess(n).info.timeneu);

    sess(n).sync = syncClocks(pxlint.roi_data, rcTtl);

    %% Load scoring if it exists
    if ismember('score', recList.Properties.VariableNames)
        if ~isempty(recList.score{n})
        score = readtable(fullfile(naspath,recList.path{n},recList.score{n}));
        sess(n).score.ind = score.ImageIndex;
        sess(n).score.code = score.BehaviorType;
        else
            sess(n).score.ind = [];
            sess(n).score.code = [];
        end
    else
        sess(n).score.ind = [];
        sess(n).score.code = [];
    end

end

%% Load/Parse Single Unit spiking data by session.
% cif = fullfile(kspath,"cluster_info.tsv")
% cifclusterinf = readtable(cif, "FileType","text",'Delimiter', '\t');
cif = fullfile(kspath,"cluster_group.tsv")
clusterinf = readtable(cif, "FileType","text",'Delimiter', '\t');

spikets = readNPY(fullfile(kspath,"spike_times.npy"));
spikeclusters = readNPY(fullfile(kspath,"spike_clusters.npy"));
spiketemps = readNPY(fullfile(kspath,"spike_templates.npy"));

gcells = clusterinf.cluster_id(strmatch('good',clusterinf.group));

%% Package sample numbers by session.
clear indsess sn
indsess(1,:) = [1 sess(1).info.numSamp];
for sn = 2 : size(sess,2)
    indsess(sn,:) = [indsess(sn-1,2) + 1  indsess(sn-1,2)+1 + sess(sn).info.numSamp];
end

% Match spike times to corresponding behavioral frames
for sn = 1 : length(sess)
    for nn = 1 : length(gcells)
        nn
        clear cn spkind;
        cn = gcells(nn);
        sess(sn).neu(nn).info = clusterinf(clusterinf.cluster_id==cn,:);
        spkind = double(spikets(spikeclusters==cn));

        for sn = 1 : size(sess,2)
            clear sessspkind
            sesspkind = spkind(find(spkind>=indsess(sn,1) & spkind<indsess(sn,2))); % Find spike inds in this session
            sesspkind = sesspkind - indsess(sn,1)+1; % Bring indices to 1.
            sess(sn).neu(nn).ts = sess(sn).info.timeneu(sesspkind); % Pull spike times within session.
            sess(sn).neu(nn).spkind = sess(sn).sync.ephysSampleToFrame(sesspkind); % Pull corresponding behav frames for each spike.
            sess(sn).neu(nn).spkind(isnan(sess(sn).neu(nn).spkind)) = [];

            % Extract behav variables for each spike.
            sess(sn).neu(nn).sx = sess(sn).x(sess(sn).neu(nn).spkind);
            sess(sn).neu(nn).sy = sess(sn).y(sess(sn).neu(nn).spkind);
            sess(sn).neu(nn).shd = sess(sn).hd(sess(sn).neu(nn).spkind);
            sess(sn).neu(nn).slv = sess(sn).lv(sess(sn).neu(nn).spkind);
            sess(sn).neu(nn).sacc = sess(sn).acc(sess(sn).neu(nn).spkind);
        end
    end
end



% 
%             % HD + 2D Ratemaps
%             clear n n2
%             n = histcounts2(neu(nn).sess(sn).spk_x,neu(nn).sess(sn).spk_y,minx:3:maxx,miny:3:maxy);
%             n2 = histcounts2(sess(sn).x,sess(sn).y,minx:3:maxx,miny:3:maxy);
%             neu(nn).sess(sn).twod = (n./n2).*30;
%             neu(nn).sess(sn).twodsm = smoothdata2(neu(nn).sess(sn).twod,'gaussian',3);
% 
%             clear n n2
%             n = histcounts(deg2rad(neu(nn).sess(sn).spk_hd),20);
%             n2 = histcounts(deg2rad(sess(sn).hd),20);
%             neu(nn).sess(sn).hd = (n./n2).*30;
%             neu(nn).sess(sn).hdsm = smoothdata(neu(nn).sess(sn).hd, 'gaussian',3);
% 
% 
%             % Egocentric Boundary
%             clear r
%             r.x = sess(sn).x;
%             r.y = sess(sn).y;
%             r.md = deg2rad(sess(sn).hd)';
%             r.spike = zeros(1,length(r.x));
%             r.spike(neu(nn).sess(sn).spkind) = 1; r.spike = r.spike';
%             r.ts = sess(sn).info.ttlts - min(sess(sn).info.ttlts);
%             out = EgocentricRatemap(r);
%             % neu(nn).sess(sn).ebc.r = r;
%             neu(nn).sess(sn).ebc.out = out;
% 
% 
%         end
%     end
% end
% 

%% Plot the data
hd = 1;
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


        % % try
        %     figure(1); subplot(numSess,numPlots,2);
        %
        %     minx = min(sess(s).x);
        %     maxx = max(sess(s).x);
        %     miny = min(sess(s).y);
        %     maxy = max(sess(s).y);
        %     n2 = histcounts2(sess(s).x,sess(s).y,minx:3:maxx,miny:3:maxy);
        %     ax = subplot(numSess,numPlots,2);
        %     imagesc(rot90(neu(n).sess(s).twodsm),'AlphaData', rot90(n2)>0);
        %     caxis([0 prctile(neu(n).sess(s).twodsm(:),99)])
        %     colormap(ax,parula); axis tight; axis square;
        % % end
        %
        %     figure(1);
        %     subplot(numSess,numPlots,3);
        %     plot(neu(n).sess(s).hdsm); axis tight; axis square;
        %     figure(1);
        %     subplot(numSess,numPlots,4);
        %     plotEgoRatemap(neu(n).sess(s).ebc.out);

    end
    % 
    % ax = subplot(1,numSe,1);
    % colormap(ax,hsv)


    pause; clf(1); %clf(2);
end









% %% Sync signals
% timeneu = data.timestamps;
% indneu = data.sampleNumbers;
% 
% ttl = rec.ttlEvents(sn);
% ttlts = ttl.timestamp;
% ttlts = ttlts(2:2:end-1);
% dTtlPos = length(ttlts)-size(pos,1)
% ttlts = ttlts(dTtlPos+1:end)
% minttl = min(ttlts);
% ttlts_zd = ttlts-minttl;
% 
% ttlstate = double(ttl.state);
% 
% neuttlrem = find(timeneu < ttlts(1) | timeneu > ttlts(end));
% 
% %% Load Single Unit Data
% cif = fullfile(kspath,"cluster_info.tsv")
% clusterinf = readtable(cif, "FileType","text",'Delimiter', '\t');
% spikets = readNPY(fullfile(kspath,"spike_times.npy"));
% spikeclusters = readNPY(fullfile(kspath,"spike_clusters.npy"));
% spiketemps = readNPY(fullfile(kspath,"spike_templates.npy"));
% 
% gcells = strmatch('good',clusterinf.KSLabel);
% 
% for n = 1 : length(gcells)
%     cn = gcells(n);
%     neu(n).info = clusterinf(cn,:);
% 
%     clear tempts;
%     tempts = data.timestamps(double(spikets(spikeclusters==cn)))-minttl;
%     tempts(tempts<0 | tempts>max(ttlts_zd)) = []; 
%     neu(n).spkts = tempts;
% 
%     for s = 1 : length(neu(n).spkts)
%         [~,si] = min(abs(neu(n).spkts(s) - ttlts_zd));
%         neu(n).spkind(s) = si;
%         neu(n).spk_x(s) = sess.x(si);
%         neu(n).spk_y(s) = sess.y(si);
%         neu(n).spk_hd(s) = sess.hd(si);
%         neu(n).spk_lv(s) = sess.lv(si);
%     end
% 
% end
% 
% 
% % save(fullfile(savepath,'sess.mat'),"sess")
% 
% %% LFPS
% lfpdecfac = data.metadata.sampleRate./1000;
% numCh = size(data.samples,1);
% 
% d = designfilt('bandstopiir','FilterOrder',2, ...
%                'HalfPowerFrequency1',59,'HalfPowerFrequency2',61, ...
%                'DesignMethod','butter','SampleRate',1000);
% lfps = [];
% for lf = 1 : numCh
%     lf
%     clear templfp; 
%     templfp = double(data.samples(lf,:));
%     templfp(neuttlrem) = [];
%     lfps(lf,:) = decimate(templfp,lfpdecfac);
%     [pxx,f] = pwelch(lfps(lf,:),1000,500,1000,'power',1000);
%     lPSD(lf,:) = pxx;
% end
% lPSD2 = lPSD;
% lPSD2(:, [59:62 119:122 179:182 239:242]) = NaN;
% mpsd = nanmean(log(lPSD2(:,1:250))); mpsd = smoothdata(mpsd,"movmean",3);
% spsd = nanstd(log(lPSD2(:,1:250))); spsd = smoothdata(spsd,"movmean",3);
% 
% % Generate LFP time vector
% fs = 1000;
% lfpt = [0 : (1/fs) : ((size(lfps,2)./fs) - (1/fs))]';
% 
% %% Filter LFP
% glfp = 26; % glfp = 3; CK % glfp = 26; % CP
% [fLFP, lfpPhase] = filtLFP(lfps(glfp,:), 1000);
% 
% %% Identify ripples
% % [vq] = rateVectorInterpolator(sess.lv, size(lfps,2));
% % tlfp = lfps(26,:); tlfp(vq>3) = NaN;
% 
% [swr.ind, swr.times, swr.pos, swr.bounds, ~]=...
%             rippleID(lfps(26,:), fLFP(2,:), lfpt, [], 1000, []);
% 
% lfpdat.lfps = lfps; 
% lfpdat.psd = lPSD;
% lfpdat.fLFP = fLFP;
% lfpdat.ts = lfpt;
% lfpdat.swr = swr;

% save(fullfile(savepath,'lfps'),"lfpdat")



% figure(1)
% subplot(1,2,1); hold on
% lPSD2 = lPSD;
% lPSD2(:, [59:62 119:122 179:182 239:242]) = NaN;
% mpsd = nanmean(log(lPSD2(:,1:250))); mpsd = smoothdata(mpsd,"movmean",3,"includemissing");
% spsd = nanstd(log(lPSD2(:,1:250))); spsd = smoothdata(spsd,"movmean",3,"includemissing");
% boundedline(1:250, mpsd, spsd,'k'); axis tight; axis square;
% 
% figure(1)
% subplot(1,2,2); hold on
% mpsd = nanmean(log(lPSD2(:,1:45))); mpsd = smoothdata(mpsd,"movmean",3,"includemissing");
% spsd = nanstd(log(lPSD2(:,1:45))); spsd = smoothdata(spsd,"movmean",3,"includemissing");
% boundedline(1:45, mpsd, spsd,'k'); axis tight; axis square;

% %% Load and parse spike data
% kspath = uigetdir([],'Select KS output folder') %'D:\041625_A\rawnode';
% cif = fullfile(kspath,"cluster_info.tsv")
% clusterinf = readtable(cif, "FileType","text",'Delimiter', '\t');
% spikets = readNPY(fullfile(kspath,"spike_times.npy"));
% spikeclusters = readNPY(fullfile(kspath,"spike_clusters.npy"));
% spiketemps = readNPY(fullfile(kspath,"spike_templates.npy"));
% 
% gcells = strmatch('good',clusterinf.KSLabel);
% for n = 1 : length(gcells)
%     cn = gcells(n);
%     neu(n).info = clusterinf(cn,:);
%     neu(n).spkinds = double(spikets(spikeclusters==cn));
% end

%% Extract and clean POSITION data + other behavioral variables of interest




































%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% x(x==0) = NaN; y(y==0)=NaN;
% x(x<prctile(x,1))=NaN; x(x>prctile(x,99))=NaN;
% y(y<prctile(y,1))=NaN; y(y>prctile(y,99))=NaN;

% spJump = prctile(sp,90);
% accJump = prctile(acc,90);
% x(sp>spJump | acc>accJump) = NaN;
% y(sp>spJump | acc>accJump) = NaN;
% 
% clear root;
% root = CMBHOME.Session('b_x', x, 'b_y', y, ...
%     'b_ts', t, 'b_headdir', hd, ...
%     'fs_video', fs, ...
%     'spatial_scale', 62.5/nanmean([[mxx-minx] [mxy-miny]]));
% root = root.FixDir;
% root.b_x(root.b_vel.*root.spatial_scale>75) = NaN;
% root.b_y(root.b_vel.*root.spatial_scale>75) = NaN;
% root.b_headdir(root.b_vel.*root.spatial_scale>75) = NaN;
% root.raw_headdir = 1;
% root = root.FixDir;
% root = root.FixPos;
% 
% sp = hypot([root.b_x(4:end)-root.b_x(1:end-3)],...
%     [root.b_y(4:end)-root.b_y(1:end-3)]).*converSpToHz;
% sp = sp.*root.spatial_scale;
% root.b_x(sp>65) = NaN; root.b_y(sp>65) = NaN;
% root.raw_pos = [];
% root.FixPos;
% 
% xcln = smoothdata(root.b_x,'Gaussian',3,"includenan");
% ycln = smoothdata(root.b_y,'Gaussian',3,"includenan");
% hdcln = smoothdata(root.b_headdir,'Gaussian',3,"includenan");
% velcln = smoothdata(root.b_vel,'Gaussian',3,"includenan");

% MoveDir
% xdiff = x(4:end)-y(1:end-3);
% ydiff = x(4:end)-y(1:end-3);
% mdcln = smoothdata(wrapTo2Pi(atan2(ydiff,xdiff)),'Gaussian',3,"includenan");
% mdcln = [nan; nan; mdcln; nan];

% xclnt = xcln; xclnt(isnan(xcln)) = 0;
% yclnt = ycln; yclnt(isnan(ycln)) = 0;
% kOut = CMBHOME.Utils.speed_kalman(xclnt, yclnt, fs);
% mdcln = kOut.vd;

% figure; plot(x,y);
% hold on; plot(xcln,ycln)
% 
% figure; plot(x); hold on; plot(xcln);
% figure; plot(y); hold on; plot(ycln);

        % subplot(2,2,2); hold on; plot(deg2rad(hd)); plot(wrapTo2Pi(hdcln))
        % subplot(2,2,3); hold on; plot(sp); plot(velcln)


    % %% Process behavioral data differently if CHZ versus FE
    % runIndicesAll = [];
    % 
    % % if exist('bScore','var') % If there is CHZ scoring
    % 
    %     runIndicesAll(:,1) = bScore.ImageIndex(strmatch('START',bScore.BehaviorType));
    %     runIndicesAll(:,2) = bScore.ImageIndex(strmatch('STOP',bScore.BehaviorType));
    % 
    %     rc = 0;
    %     for n = 1 : size(bScore,1)
    %         if strmatch('START',bScore.BehaviorType(n,1)) & strmatch('context a trial', bScore.Behavior(n,1))
    %             rc = rc + 1;
    %             runIndicesAll(rc,3) = 0;
    %         elseif strmatch('START',bScore.BehaviorType(n,1)) & strmatch('context c trial',bScore.Behavior(n,1))
    %             rc = rc + 1;
    %             runIndicesAll(rc,3) = 2;
    %         end
    %     end
    % 
    %     allInds = []; aInds = []; cInds = [];
    %     for r = 1 : size(runIndicesAll,1)
    %         allInds = [allInds, runIndicesAll(r,1):runIndicesAll(r,2)];
    % 
    %         if runIndicesAll(r,3)==0
    %             aInds = [aInds, runIndicesAll(r,1):runIndicesAll(r,2)];
    %         elseif runIndicesAll(r,3)==2
    %             cInds = [cInds, runIndicesAll(r,1):runIndicesAll(r,2)];
    %         end
    % 
    %     end
    % 
    % 
    % 
    % 
    %     % leftover from when we tried 'hard' thresholds for arena bounds
    %     % mux(mux>118)=NaN;
    %     % muy(muy>110)=NaN;
    % 
    % 
    %     % Store variables in behSummary structure
    %     % Pos
    %     behSummary(s).pos.fullSession = [mux,muy];
    %     [temp, xe, ye] = histcounts2(mux,muy,floor(arenaSize/5));
    %     temp = temp./30; % hard-coded position sampling rate
    %     behSummary(s).pos.occMap.z = temp;
    %     behSummary(s).pos.occEdges = [xe', ye'];
    % 
    %     % Linear Speed
    %     behSummary(s).speed.fullSession = sp;
    %     behSummary(s).speed.meanSpeed = nanmean(sp);
    %     behSummary(s).speed.medSpeed = prctile(sp,50);
    % 
    %     % Acceleration
    %     behSummary(s).acc.fullSession = [NaN; diff(sp)];
    % 
    % 
    %     % HD
    %     behSummary(s).hd.fullSession = hd;
    %     behSummary(s).hd.meanHD = circ_mean(hd);
    %     behSummary(s).hd.stdHD = circ_std(hd);
    %     behSummary(s).hd.medHD = circ_median(hd,50);
    % 
    %     % Angular Speed
    %     behSummary(s).angSpeed.fullSession = diff(hd).*30;


    % % else % IF just FE
    % 
    %     % Extract and clean position data + other behavioral variables of interest
    %     pos = readtable(cell2mat(fullfile(cp,sessList.PositionData{s})));
    % 
    %     % NaN out position estimatees with low likelihoods
    %     lkThresh = 0.4;
    %     cleanPos = [pos(:,[14:19])];
    %     cleanPos{cleanPos{:,[3]}<lkThresh,1:2} = NaN;
    %     cleanPos{cleanPos{:,[6]}<lkThresh,4:5} = NaN;
    % 
    %     % Average position over tracked left and right ears + threshold out
    %     % extreme values using 1st and 99th percentile
    %     mux = nanmean([cleanPos.R_head_x, cleanPos.L_head_x], 2);
    %     muy = nanmean([cleanPos.R_head_y, cleanPos.L_head_y], 2);
    %     mux(mux<prctile(mux,1))=NaN; mux(mux>prctile(mux,99))=NaN;
    %     muy(muy<prctile(muy,1))=NaN; muy(muy>prctile(muy,99))=NaN;
    % 
    %     % Find the maximum and minimum values of x,y coordinates and use to
    %     % scale data to centimeters using known 'arenaSize' (changes from arena
    %     % to arena but not on same arena) bring to origin by subtracting
    %     % minimum x,y
    %     mxx = nanmax(mux); mxy = nanmax(muy);
    %     minx = nanmin(mux); miny = nanmin(muy);
    % 
    %     arenaSize = 122;
    %     scale = arenaSize./nanmean([[mxx-minx] [mxy-miny]]);
    %     mux = mux-minx; muy = muy-miny;
    %     mux = mux.*scale; muy = muy.*scale;
    % 
    %     % leftover from when we tried 'hard' thresholds for arena bounds
    %     % mux(mux>118)=NaN;
    %     % muy(muy>110)=NaN;
    % 
    %     % Caluclate speed acceleration and use abrupt 'jumps' in each to
    %     % further remove poor tracking
    %     converSpToHz = 10;
    %     sp = hypot([mux(4:end)-mux(1:end-3)],[muy(4:end)-muy(1:end-3)]).*converSpToHz;
    %     sp = [NaN; NaN; sp; NaN;];
    %     acc = [NaN; abs(diff(sp))];
    % 
    %     spJump = 75;
    %     accJump = 20;
    %     mux(sp>spJump | acc>accJump) = NaN;
    %     muy(sp>spJump | acc>accJump) = NaN;
    %     sp(sp>spJump | acc>accJump) = NaN;
    %     acc(sp>spJump | acc>accJump) = NaN;
    % 
    %     % Calculate head direction based off of the difference in angle between
    %     % left and right ear
    %     xdf = cleanPos.L_head_x - cleanPos.R_head_x;
    %     ydf = cleanPos.L_head_y - cleanPos.R_head_y;
    %     hd = atan2(xdf,ydf);
    % 
    %     % Plot all of these variables
    %     figure(1); clf(1); hold on; subplot(2,2,1); plot(mux,muy);
    %     subplot(2,2,2); plot(sp); subplot(2,2,3); plot(acc);
    %     subplot(2,2,4); polarhistogram(hd);
    % 
    %     % Store variables in behSummary structure
    %     % Pos
    %     behSummary(s).pos.fullSession = [mux,muy];
    %     [temp, xe, ye] = histcounts2(mux,muy,floor(arenaSize/5));
    %     temp = temp./30; % hard-coded position sampling rate
    %     behSummary(s).pos.occMap.z = temp;
    %     behSummary(s).pos.occEdges = [xe', ye'];
    % 
    %     % Linear Speed
    %     behSummary(s).speed.fullSession = sp;
    %     behSummary(s).speed.meanSpeed = nanmean(sp);
    %     behSummary(s).speed.medSpeed = prctile(sp,50);
    % 
    %     % Acceleration
    %     behSummary(s).acc.fullSession = [NaN; diff(sp)];
    % 
    % 
    %     % HD
    %     behSummary(s).hd.fullSession = hd;
    %     behSummary(s).hd.meanHD = circ_mean(hd);
    %     behSummary(s).hd.stdHD = circ_std(hd);
    %     behSummary(s).hd.medHD = circ_median(hd,50);
    % 
    %     % Angular Speed
    %     behSummary(s).angSpeed.fullSession = diff(hd).*30;
    % 
    % end



    % DO STUFF


    % end