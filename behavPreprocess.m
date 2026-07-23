function [tempsess] = behavPreprocess(pos, recList, n)

% Define some global vars that may need to change from comp to comp
% or depending on what thresholds you want.
naspath = 'Z:\'; % Directory on local PC of the NAS
velThresh = 120; % Maximum speed of the animal

% Extract position data and clean
clear dlcpos dlcind
% if dlcLikelihood == 1
% Extract position data and remove bad likelihoods
dlcpos = [pos.rear_x pos.rear_y pos.rear_score pos.lear_x pos.lear_y pos.lear_score];
lkThresh = 0.2;
dlcpos(dlcpos(:,3) < lkThresh, 1:2) = NaN;
dlcpos(dlcpos(:,6) < lkThresh, 4:5) = NaN;
dlcind = pos.frame_idx+1;
dlcpos = dlcpos(:,[1 2 4 5]);
% end

%% Fix if true frame count does not match rows in tracking output file
% Here we load the Bonsai frame grabber xlsx
% This section of code tries to make sure that the markerless tracking
% algorithm output matches the true number of frames written and
% identifies the true indices of the frames so that potential frame
% jumps (i.e. when a frame is not written correctly you will have non
% sequential indices) can be identified and fixed as they are likely
% locations where there will be extra TTLs.
clear bTs
if ismember('bonsaiTs', recList.Properties.VariableNames)
    bTs = readtable(fullfile(naspath,recList.path{n},recList.bonsaiTs{n}));
    numFrames = size(bTs,1)
else
    videoFile = fullfile(naspath,recList.path{n},recList.video{n});
    v = VideoReader(videoFile);
    numFrames = v.NumFrames;
end

goodInd = (pos.frame_idx)+1;
if goodInd(1) ~= 1
    goodInd = (goodInd-min(goodInd))+1;
end

if numFrames~=length(dlcpos)
    'Frame Mismatch'
    [dlcpos, dlcind] = fixSleapFrames(numFrames,goodInd,dlcpos,dlcind);
end

%% Calculate HD
deltax = dlcpos(:,3)'-dlcpos(:,1)';
deltay = dlcpos(:,4)'-dlcpos(:,2)';
hd = circ_rad2ang(wrapTo2Pi(atan2(deltay,deltax)+pi/2));

%% Calculate mean x,y position and range
x = nanmean([dlcpos(:,1),dlcpos(:,3)],2);
y = nanmean([dlcpos(:,2),dlcpos(:,4)],2);
x(x<prctile(x,0.5) | x>prctile(x,99.5)) = NaN;
y(y<prctile(y,0.5) | y>prctile(y,99.5)) = NaN;

mxx = nanmax(x); mxy = nanmax(y);
minx = nanmin(x); miny = nanmin(y);

%% Scale from pxls to cms
if ismember('arenaSizeX', recList.Properties.VariableNames)
    arenaSizeX = recList.arenaSizeX(n);
    arenaSizeY = recList.arenaSizeY(n);
else
    arenaSizeX = defaultArena;
    arenaSizeY = defaultArena;
end

scalex = arenaSizeX./[mxx-minx];
scaley = arenaSizeY./[mxy-miny];

%% Bring all data to 0,0 and scale to cms;
x = x-minx; y = y-miny;
x = x.*scalex; y = y.*scaley;

%% Calculate speed acceleration.
vel = hypot([x(4:end)-x(1:end-3)],[y(4:end)-y(1:end-3)]);
vel = [NaN; NaN; vel; NaN;];
acc = [NaN; abs(diff(vel))];
% x(find(x<15 & y<15)) = NaN;
% y(find(x<15 & y<15)) = NaN;
% x(find(x<15 & y>100)) = NaN;
% y(find(x<15 & y>100)) = NaN;
x(vel>velThresh) = NaN;
y(vel>velThresh) = NaN;
vel(vel>velThresh) = NaN;
figure(1); subplot(1,2,1); plot(x,y)

%% Package behavioral data into session file.
tempsess.x = smoothdata(x,6);
tempsess.y = smoothdata(y,6);
tempsess.y = abs(tempsess.y-max(tempsess.y)+1);
figure(1); subplot(1,2,2); plot(tempsess.x,tempsess.y)
axis([0 max(recList.arenaSizeX) 0 max(recList.arenaSizeY)])
tempsess.hd = hd';
tempsess.lv = vel;
tempsess.acc = acc;

[tempsess.t, ~, ~] = loadFrameTimes();
tempsess.bsF = 1/median(diff(tempsess.t));