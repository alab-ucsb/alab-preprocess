function SegmentScannerVideo(inputData, videoPath)
% SegmentScannerVideo
%
% Interactive behavioral segmentation tool with synchronized video.
%
% INPUTS
%   inputData : Nx2 matrix
%               Column 1 = X coordinate
%               Column 2 = Y coordinate
%               NaNs are allowed.
%
%   videoPath : path to corresponding behavioral video
%
%
% IMPORTANT FRAME MAPPING
% -----------------------
% Your Python code creates:
%
%   frame00000 -> first row of inputData
%   frame00001 -> second row
%   frame00002 -> third row
%
% MATLAB video frames are 1-based:
%
%   video frame 1 -> first video frame
%   video frame 2 -> second video frame
%
% Therefore:
%
%   data row 1 <-> video frame 1
%   data row 2 <-> video frame 2
%
% If your pickle/data file and video are offset, change
% VIDEO_FRAME_OFFSET below.
%
%
% CONTROLS
% --------
% << Back       Previous window
% Next >>       Next window
% < Frame       Previous video frame
% Frame >       Next video frame
% Play          Play/pause synchronized video
% Window Len    Number of trajectory frames shown
%
% MARK START    Select behavioral start
% MARK END      Select behavioral end
%
% 1-10          Behavioral marker/code
% Delete        Delete selected segment
% Export        Export segment matrix
%
% Keyboard:
%   Left Arrow   previous frame
%   Right Arrow  next frame
%   Space        play/pause
%

%% Example calling this function
% A = readmatrix("Processed_Coordinates/AC01_010126_ring_0001DLC_Resnet50_circular_trackSep16shuffle1_snapshot_best-370_fullprocessed_coordinates.csv");
% video = "AC01_010126_ring_0001.mp4";
% SegmentScannerVideo(A,video);


    %% ---------------------------------------------------------------
    %  INPUT VALIDATION
    %  ---------------------------------------------------------------

    if nargin < 2
        error('Usage: SegmentScannerVideo(inputData, videoPath)');
    end

    if size(inputData,2) < 2
        error('inputData must have at least two columns.');
    end

    data = inputData(:,1:2);
    numRows = size(data,1);




    %% ---------------------------------------------------------------
    %  VIDEO
    %  ---------------------------------------------------------------

    videoObj = VideoReader(videoPath);

    videoFPS = videoObj.FrameRate;
    videoDuration = videoObj.Duration;

    % ---------------------------------------------------------------
    % IMPORTANT:
    %
    % If data row 1 corresponds to video frame 1:
    %
    %     VIDEO_FRAME_OFFSET = 0
    %
    % If data begins 5 frames after the video:
    %
    %     VIDEO_FRAME_OFFSET = 5
    %
    % ---------------------------------------------------------------

    VIDEO_FRAME_OFFSET = 0;

    estimatedVideoFrames = floor(videoDuration * videoFPS);

    fprintf('\n');
    fprintf('Video: %s\n', videoPath);
    fprintf('Video FPS: %.3f\n', videoFPS);
    fprintf('Estimated video frames: %d\n', estimatedVideoFrames);
    fprintf('Data rows: %d\n', numRows);
    fprintf('\n');

    if abs(estimatedVideoFrames - numRows) > 2
        warning(['Number of video frames and data rows differ. ' ...
                 'Check frame synchronization.']);
    end

    %% ---------------------------------------------------------------
    %  STATE VARIABLES
    %  ---------------------------------------------------------------

    winSize = min(500, numRows);

    currStart = 1;

    % Current frame being viewed
    currentFrame = 1;

    activeCode = 1;

    pendingStartIdx = [];

    segments = zeros(0,3);

    colors = lines(10);

    markerButtons = gobjects(1,10);

    isPlaying = false;

    playbackTimer = [];

    %% ---------------------------------------------------------------
    %  GLOBAL AXIS LIMITS
    %  ---------------------------------------------------------------

    validX = data(:,1);
    validY = data(:,2);

    validX = validX(isfinite(validX));
    validY = validY(isfinite(validY));

    if isempty(validX) || isempty(validY)
        error('No finite X/Y coordinates exist in inputData.');
    end

    xLimitsGlobal = prctile(validX,[0.25 99.75]);
    yLimitsGlobal = prctile(validY,[0.25 99.75]);

    dx = diff(xLimitsGlobal)*0.1;
    dy = diff(yLimitsGlobal)*0.1;

    if dx == 0
        dx = 1;
    end

    if dy == 0
        dy = 1;
    end

    globalXRange = [
        xLimitsGlobal(1)-dx ...
        xLimitsGlobal(2)+dx
    ];

    globalYRange = [
        yLimitsGlobal(1)-dy ...
        yLimitsGlobal(2)+dy
    ];

    %% ---------------------------------------------------------------
    %  UI
    %  ---------------------------------------------------------------

    fig = uifigure( ...
        'Name','Behavioral Segment Scanner + Video', ...
        'Position',[50 50 1450 850]);

    % Main layout:
    %
    %       trajectory | video
    %       trajectory | video
    %       controls   | controls
    %

    mainGrid = uigridlayout(fig,[2 3]);
    
    mainGrid.RowHeight = {'1x',260};
    mainGrid.ColumnWidth = {'1.2x','1.2x',320};

    %% ---------------------------------------------------------------
    %  TRAJECTORY AXES
    %  ---------------------------------------------------------------

    ax = uiaxes(mainGrid);

    ax.Layout.Row = 1;
    ax.Layout.Column = 1;

    grid(ax,'on');
    hold(ax,'on');

    xlim(ax,globalXRange);
    ylim(ax,globalYRange);

    ax.XLabel.String = 'X coordinate';
    ax.YLabel.String = 'Y coordinate';

    disableDefaultInteractivity(ax);

    %% ---------------------------------------------------------------
    %  VIDEO AXES
    %  ---------------------------------------------------------------

    videoAx = uiaxes(mainGrid);

    videoAx.Layout.Row = 1;
    videoAx.Layout.Column = 2;

    videoAx.XTick = [];
    videoAx.YTick = [];

    videoAx.Box = 'on';

    disableDefaultInteractivity(videoAx);

    %% ---------------------------------------------------------------
    %  CONTROL AREA
    %  ---------------------------------------------------------------

    ctrlGrid = uigridlayout(mainGrid,[5 1]);

    ctrlGrid.Layout.Row = 2;
    ctrlGrid.Layout.Column = [1 3];


    ctrlGrid.RowHeight = {30,40,45,45,45};

    %% Progress label

    lblProgress = uilabel(ctrlGrid);

    lblProgress.Text = 'Frame 1';
    lblProgress.HorizontalAlignment = 'center';
    lblProgress.FontWeight = 'bold';

    %% ---------------------------------------------------------------
    %  MARKER BUTTONS
    %  ---------------------------------------------------------------

    mGrid = uigridlayout(ctrlGrid,[1 10]);

    for i = 1:10

        markerButtons(i) = uibutton( ...
            mGrid, ...
            'Text',num2str(i), ...
            'BackgroundColor',colors(i,:), ...
            'FontColor','w', ...
            'ButtonPushedFcn', ...
            @(btn,event) updateActiveMarker(i));

    end

    %% ---------------------------------------------------------------
    %  NAVIGATION CONTROLS
    %  ---------------------------------------------------------------

    navGrid = uigridlayout(ctrlGrid,[1 9]);

    uibutton( ...
    navGrid, ...
    'Text','Next >>', ...
    'ButtonPushedFcn', ...
    @(~,~) buttonAction(@() movePage(1)));


    uibutton( ...
        navGrid, ...
        'Text','< Frame', ...
        'ButtonPushedFcn', ...
        @(~,~) moveFrame(-1));

    btnPlay = uibutton( ...
        navGrid, ...
        'Text','Play', ...
        'ButtonPushedFcn', ...
        @togglePlay);

    uibutton( ...
        navGrid, ...
        'Text','Frame >', ...
        'ButtonPushedFcn', ...
        @(~,~) moveFrame(1));

    uilabel( ...
        navGrid, ...
        'Text','Window Len:', ...
        'HorizontalAlignment','right');

    winField = uieditfield( ...
        navGrid, ...
        'numeric', ...
        'Value',winSize, ...
        'Limits',[10 Inf], ...
        'ValueChangedFcn', ...
        @(n,e) updateWinSize(n.Value));

    uibutton( ...
        navGrid, ...
        'Text','Next >>', ...
        'ButtonPushedFcn', ...
        @(~,~) movePage(1));
%% ---------------------------------------------------------------
%  BUTTON ACTION
%  ---------------------------------------------------------------

function buttonAction(action)

    action();

    drawnow;

    try
        focus(fig);
    catch
    end

end


        %% ---------------------------------------------------------------
    %  HELP BUTTON
    %  ---------------------------------------------------------------

    uibutton( ...
        navGrid, ...
        'Text','Help', ...
        'ButtonPushedFcn',@showHelp);


    %% ---------------------------------------------------------------
    %  START/END BUTTONS
    %  ---------------------------------------------------------------

    btnGrid = uigridlayout(ctrlGrid,[1 4]);

    btnStart = uibutton( ...
        btnGrid, ...
        'Text','MARK START', ...
        'ButtonPushedFcn',@setStart, ...
        'BackgroundColor',[.2 .6 .2], ...
        'FontColor','w');

    btnEnd = uibutton( ...
        btnGrid, ...
        'Text','MARK END', ...
        'ButtonPushedFcn',@setEnd, ...
        'BackgroundColor',[.6 .2 .2], ...
        'FontColor','w', ...
        'Enable','off');

    uibutton( ...
        btnGrid, ...
        'Text','Delete Selected', ...
        'ButtonPushedFcn',@deleteRow);

    uibutton( ...
        btnGrid, ...
        'Text','Export Matrix', ...
        'ButtonPushedFcn',@exportData);

   %% ---------------------------------------------------------------
%  FRAME TRACKER
%  ---------------------------------------------------------------

sliderGrid = uigridlayout(ctrlGrid,[1 3]);

sliderGrid.ColumnWidth = {70,'1x',110};

uilabel( ...
    sliderGrid, ...
    'Text','Frame:', ...
    'HorizontalAlignment','right', ...
    'FontWeight','bold');

frameSlider = uislider( ...
    sliderGrid, ...
    'Limits',[1 max(1,numRows)], ...
    'Value',1, ...
    'MajorTicks',[], ...
    'MinorTicks',[], ...
    'ValueChangedFcn', ...
    @(s,e) sliderMoved(s.Value));

frameNumberField = uieditfield( ...
    sliderGrid, ...
    'text', ...
    'Value','1', ...
    'HorizontalAlignment','center', ...
    'FontWeight','bold', ...
    'ValueChangedFcn', ...
    @(f,e) frameFieldMoved(f.Value));



    %% ---------------------------------------------------------------
    %  MARKINGS TABLE
    %  ---------------------------------------------------------------
    
    uit = uitable(mainGrid);
    
    uit.Layout.Row = 1;
    uit.Layout.Column = 3;
    
    uit.Data = segments;
    
    uit.ColumnName = {'Start Frame','End Frame','Code'};
    
    uit.ColumnWidth = {'1x','1x','1x'};
    
    uit.RowName = {};
    
    uit.FontSize = 14;


    % NOTE:
    %
    % If you want both video and table visible simultaneously,
    % the layout can be expanded later.
    %
    % For now the table is not displayed here because video occupies
    % the right-hand panel.
    %
    % Segment information is still stored internally.


    %% ---------------------------------------------------------------
    %  KEYBOARD CONTROLS
    %  ---------------------------------------------------------------

    fig.WindowKeyPressFcn = @keyPress;




    %% ---------------------------------------------------------------
    %  INITIALIZE
    %  ---------------------------------------------------------------

    updateActiveMarker(1);

    refreshAll();

    %% ===============================================================
    %  NESTED FUNCTIONS
    %  ===============================================================

    function updateActiveMarker(val)

        activeCode = val;

        for j = 1:10

            markerButtons(j).FontWeight = 'normal';
            markerButtons(j).Text = num2str(j);

        end

        markerButtons(activeCode).FontWeight = 'bold';

        markerButtons(activeCode).Text = ...
            ['[' num2str(activeCode) ']'];

        refreshTrajectory();
        set(ax,'YDir','reverse');


    end


    %% ---------------------------------------------------------------
    %  PAGE NAVIGATION
    %  ---------------------------------------------------------------

    function movePage(direction)

        stopPlayback();

        currStart = currStart + direction*winSize;

        currStart = max(1,currStart);

        currStart = min( ...
            currStart, ...
            max(1,numRows-winSize+1));

        currentFrame = currStart;

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  FRAME NAVIGATION
    %  ---------------------------------------------------------------

    function moveFrame(direction)

        currentFrame = currentFrame + direction;

        currentFrame = max(1,currentFrame);
        currentFrame = min(numRows,currentFrame);

        % Keep trajectory window centered approximately around frame

        halfWindow = floor(winSize/2);

        currStart = currentFrame-halfWindow;

        currStart = max(1,currStart);

        currStart = min( ...
            currStart, ...
            max(1,numRows-winSize+1));

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  WINDOW SIZE
    %  ---------------------------------------------------------------

    function updateWinSize(val)

        stopPlayback();

        winSize = max(10,round(val));

        winSize = min(winSize,numRows);

        currStart = max( ...
            1, ...
            min(currStart,numRows-winSize+1));

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  SLIDER
    %  ---------------------------------------------------------------

    function sliderMoved(val)

        currentFrame = round(val);

        currentFrame = max(1,currentFrame);
        currentFrame = min(numRows,currentFrame);

        halfWindow = floor(winSize/2);

        currStart = currentFrame-halfWindow;

        currStart = max(1,currStart);

        currStart = min( ...
            currStart, ...
            max(1,numRows-winSize+1));

        refreshAll();

    end


%% ---------------------------------------------------------------
%  FRAME NUMBER FIELD
%  ---------------------------------------------------------------

function frameFieldMoved(val)

    % Convert typed text to a number
    newFrame = str2double(val);

    % If invalid input, restore the current frame
    if isnan(newFrame)

        frameNumberField.Value = sprintf('%d',currentFrame);

        return;

    end

    % Round and constrain
    currentFrame = round(newFrame);

    currentFrame = max(1,currentFrame);
    currentFrame = min(numRows,currentFrame);

    % Display as normal integer
    frameNumberField.Value = sprintf('%d',currentFrame);

    % Center trajectory window around selected frame
    halfWindow = floor(winSize/2);

    currStart = currentFrame-halfWindow;

    currStart = max(1,currStart);

    currStart = min( ...
        currStart, ...
        max(1,numRows-winSize+1));

    refreshAll();

end



    %% ---------------------------------------------------------------
%  REFRESH EVERYTHING
%  ---------------------------------------------------------------

function refreshAll()

    refreshTrajectory();

    refreshVideo();

    % Update slider
    frameSlider.Value = currentFrame;

    % Update frame number display
    frameNumberField.Value = sprintf('%d',currentFrame);

    updateProgressLabel();

end




    %% ---------------------------------------------------------------
    %  TRAJECTORY PLOT
    %  ---------------------------------------------------------------

    function refreshTrajectory()

        delete(ax.Children);

        endIdx = min( ...
            currStart+winSize-1, ...
            numRows);

        viewRange = currStart:endIdx;

        % Plot raw trajectory.
        %
        % NaNs are automatically interpreted by MATLAB as gaps.

        plot( ...
            ax, ...
            data(viewRange,1), ...
            data(viewRange,2), ...
            'Color',[0.75 0.75 0.75], ...
            'LineWidth',1);

        %% Plot labeled segments

        for j = 1:size(segments,1)

            s = segments(j,1);
            e = segments(j,2);
            c = segments(j,3);

            overlapStart = max(s,currStart);
            overlapEnd = min(e,endIdx);

            if overlapStart <= overlapEnd

                overlap = overlapStart:overlapEnd;

                plot( ...
                    ax, ...
                    data(overlap,1), ...
                    data(overlap,2), ...
                    'LineWidth',3, ...
                    'Color',colors(c,:));

            end

        end

        %% Pending start

        if ~isempty(pendingStartIdx)

            title( ...
                ax, ...
                sprintf( ...
                'PENDING START: Frame %d | Find END', ...
                pendingStartIdx), ...
                'Color','r');

            if pendingStartIdx >= currStart && ...
               pendingStartIdx <= endIdx

                if all(isfinite(data(pendingStartIdx,:)))

                    plot( ...
                        ax, ...
                        data(pendingStartIdx,1), ...
                        data(pendingStartIdx,2), ...
                        'ro', ...
                        'MarkerSize',10, ...
                        'LineWidth',2);

                end
            end

        else

            title( ...
                ax, ...
                sprintf( ...
                'Frames %d-%d | Current Frame: %d | Marker %d', ...
                currStart, ...
                endIdx, ...
                currentFrame, ...
                activeCode));

        end

        %% Current frame marker

        if currentFrame >= currStart && ...
           currentFrame <= endIdx

            if all(isfinite(data(currentFrame,:)))

                plot( ...
                    ax, ...
                    data(currentFrame,1), ...
                    data(currentFrame,2), ...
                    'ko', ...
                    'MarkerSize',12, ...
                    'LineWidth',2, ...
                    'MarkerFaceColor','yellow');

            else

                % If current coordinate is NaN,
                % explicitly show that on the plot.

                text( ...
                    ax, ...
                    mean(globalXRange), ...
                    mean(globalYRange), ...
                    sprintf('FRAME %d\nNaN COORDINATE',currentFrame), ...
                    'HorizontalAlignment','center', ...
                    'Color','r', ...
                    'FontSize',16, ...
                    'FontWeight','bold');

            end

        end

        xlim(ax,globalXRange);
        ylim(ax,globalYRange);

    end


   %% ---------------------------------------------------------------
%  VIDEO REFRESH
%  ---------------------------------------------------------------

function refreshVideo()

    videoFrameNumber = ...
        currentFrame + VIDEO_FRAME_OFFSET;

    % MATLAB VideoReader is 1-based.

    if videoFrameNumber < 1 || ...
       videoFrameNumber > estimatedVideoFrames

        cla(videoAx);

        title( ...
            videoAx, ...
            sprintf('Video frame unavailable: %d', ...
            videoFrameNumber));

        return;

    end

    try

        % Read video frame
        videoFrame = read(videoObj,videoFrameNumber);

        % Display video
        imshow(videoFrame,'Parent',videoAx);

        title( ...
            videoAx, ...
            sprintf( ...
            'VIDEO FRAME %d | DATA FRAME %d | %.3f sec', ...
            videoFrameNumber, ...
            currentFrame, ...
            (videoFrameNumber-1)/videoFPS));

        % -----------------------------------------------------------
        % SHOW NaN WARNING ON VIDEO
        % -----------------------------------------------------------

        if any(isnan(data(currentFrame,1:2)))

            text( ...
                videoAx, ...
                0.5, ...
                0.5, ...
                sprintf( ...
                'FRAME %d\nNaN COORDINATE', ...
                currentFrame), ...
                'Units','normalized', ...
                'HorizontalAlignment','center', ...
                'VerticalAlignment','middle', ...
                'Color','red', ...
                'FontSize',22, ...
                'FontWeight','bold', ...
                'BackgroundColor',[1 1 1 0.75]);

        end

    catch

        cla(videoAx);

        title( ...
            videoAx, ...
            sprintf( ...
            'Could not read video frame %d', ...
            videoFrameNumber));

    end

end



    %% ---------------------------------------------------------------
    %  PROGRESS LABEL
    %  ---------------------------------------------------------------

    function updateProgressLabel()

        if all(isfinite(data(currentFrame,:)))

            coordinateText = sprintf( ...
                'X = %.2f   Y = %.2f', ...
                data(currentFrame,1), ...
                data(currentFrame,2));

        else

            coordinateText = 'X = NaN   Y = NaN';

        end

        lblProgress.Text = sprintf( ...
            'Frame %d / %d    |    Time %.3f s    |    %s', ...
            currentFrame, ...
            numRows, ...
            (currentFrame-1)/videoFPS, ...
            coordinateText);

    end


    %% ---------------------------------------------------------------
    %  MARK START
    %  ---------------------------------------------------------------

    function setStart(~,~)

        stopPlayback();

        % If current frame has a valid coordinate,
        % use it directly.
        %
        % Otherwise allow the user to click a nearby valid
        % trajectory point.

        if all(isfinite(data(currentFrame,:)))

            answer = uiconfirm( ...
                fig, ...
                sprintf( ...
                'Use current frame %d as START?', ...
                currentFrame), ...
                'Confirm Start', ...
                'Options',{'Use Current Frame','Select on Plot','Cancel'}, ...
                'DefaultOption',1, ...
                'CancelOption',3);

            if strcmp(answer,'Cancel')
                return;
            elseif strcmp(answer,'Use Current Frame')

                pendingStartIdx = currentFrame;

            else

                pendingStartIdx = selectFrameOnPlot();

                if isempty(pendingStartIdx)
                    return;
                end

            end

        else

            pendingStartIdx = selectFrameOnPlot();

            if isempty(pendingStartIdx)
                return;
            end

        end

        btnStart.Enable = 'off';
        btnEnd.Enable = 'on';

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  MARK END
    %  ---------------------------------------------------------------

    function setEnd(~,~)

        if isempty(pendingStartIdx)
            return;
        end

        stopPlayback();

        if all(isfinite(data(currentFrame,:)))

            answer = uiconfirm( ...
                fig, ...
                sprintf( ...
                'Use current frame %d as END?', ...
                currentFrame), ...
                'Confirm End', ...
                'Options',{'Use Current Frame','Select on Plot','Cancel'}, ...
                'DefaultOption',1, ...
                'CancelOption',3);

            if strcmp(answer,'Cancel')
                return;

            elseif strcmp(answer,'Use Current Frame')

                idx2 = currentFrame;

            else

                idx2 = selectFrameOnPlot();

                if isempty(idx2)
                    return;
                end

            end

        else

            idx2 = selectFrameOnPlot();

            if isempty(idx2)
                return;
            end

        end

        %% Create segment

        newSeg = [ ...
            min(pendingStartIdx,idx2), ...
            max(pendingStartIdx,idx2), ...
            activeCode];

        segments = [segments;newSeg];

        segments = sortrows(segments,1);

        updateTable();

        %% Reset

        pendingStartIdx = [];

        btnStart.Enable = 'on';
        btnEnd.Enable = 'off';

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  SELECT FRAME FROM TRAJECTORY
    %  ---------------------------------------------------------------

    function idx = selectFrameOnPlot()

        idx = [];

        % Only finite coordinates can be clicked.

        validIndices = currStart:min( ...
            currStart+winSize-1, ...
            numRows);

        validIndices = validIndices( ...
            isfinite(data(validIndices,1)) & ...
            isfinite(data(validIndices,2)));

        if isempty(validIndices)

            uialert( ...
                fig, ...
                'There are no valid coordinates in this window.', ...
                'No valid points');

            return;

        end

        % drawpoint is convenient, but it can accidentally select
        % a NaN region. We explicitly restrict the nearest-point
        % calculation to finite coordinates.

        p = drawpoint( ...
            ax, ...
            'Color',colors(activeCode,:));

        if isempty(p)
            return;
        end

        idx = findNearest(p.Position);

        delete(p);

        % Jump video to selected frame.

        currentFrame = idx;

        halfWindow = floor(winSize/2);

        currStart = currentFrame-halfWindow;

        currStart = max(1,currStart);

        currStart = min( ...
            currStart, ...
            max(1,numRows-winSize+1));

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  FIND NEAREST VALID POINT
    %  ---------------------------------------------------------------

    function idx = findNearest(pos)

        viewRange = currStart:min( ...
            currStart+winSize-1, ...
            numRows);

        valid = ...
            isfinite(data(viewRange,1)) & ...
            isfinite(data(viewRange,2));

        validRange = viewRange(valid);

        if isempty(validRange)

            idx = currentFrame;
            return;

        end

        distSq = ...
            (data(validRange,1)-pos(1)).^2 + ...
            (data(validRange,2)-pos(2)).^2;

        [~,m] = min(distSq);

        idx = validRange(m);

    end


    %% ---------------------------------------------------------------
    %  PLAY / PAUSE
    %  ---------------------------------------------------------------

    function togglePlay(~,~)

        if isPlaying

            stopPlayback();

        else

            startPlayback();

        end

    end


    %% ---------------------------------------------------------------
    %  START PLAYBACK
    %  ---------------------------------------------------------------

    function startPlayback()

        if currentFrame >= numRows

            currentFrame = 1;

        end

        isPlaying = true;

        btnPlay.Text = 'Pause';

        % Approximately one callback per video frame.

        playbackTimer = timer( ...
            'ExecutionMode','fixedRate', ...
            'Period',1/videoFPS, ...
            'TimerFcn',@playOneFrame);

        start(playbackTimer);

    end


    %% ---------------------------------------------------------------
    %  PLAY ONE FRAME
    %  ---------------------------------------------------------------

    function playOneFrame(~,~)

        if ~isvalid(fig)

            stopPlayback();

            return;

        end

        if currentFrame >= numRows

            stopPlayback();

            return;

        end

        currentFrame = currentFrame + 1;

        % Keep the displayed trajectory window moving.

        if currentFrame > currStart + winSize - 1

            currStart = currStart + winSize;

            currStart = min( ...
                currStart, ...
                max(1,numRows-winSize+1));

        end

        refreshAll();

    end


    %% ---------------------------------------------------------------
    %  STOP PLAYBACK
    %  ---------------------------------------------------------------

    function stopPlayback()

        isPlaying = false;

        if exist('btnPlay','var') && isvalid(btnPlay)

            btnPlay.Text = 'Play';

        end

        if ~isempty(playbackTimer)

            try
                stop(playbackTimer);
            catch
            end

            try
                delete(playbackTimer);
            catch
            end

            playbackTimer = [];

        end

    end


%% ---------------------------------------------------------------
%  KEYBOARD
%  ---------------------------------------------------------------

function keyPress(~,event)

    switch event.Key

        % -----------------------------------------------------------
        % SPACE = PLAY / PAUSE
        % -----------------------------------------------------------

        case 'space'

            % Prevent space from being interpreted by a UI control
            % such as the frame-number edit field.
            togglePlay();


        % -----------------------------------------------------------
        % LEFT ARROW = PREVIOUS FRAME
        % -----------------------------------------------------------

        case 'leftarrow'

            moveFrame(-1);


        % -----------------------------------------------------------
        % RIGHT ARROW = NEXT FRAME
        % -----------------------------------------------------------

        case 'rightarrow'

            moveFrame(1);


        % -----------------------------------------------------------
        % MARKER SHORTCUTS
        % -----------------------------------------------------------

        case '1'
            updateActiveMarker(1);

        case '2'
            updateActiveMarker(2);

        case '3'
            updateActiveMarker(3);

        case '4'
            updateActiveMarker(4);

        case '5'
            updateActiveMarker(5);

        case '6'
            updateActiveMarker(6);

        case '7'
            updateActiveMarker(7);

        case '8'
            updateActiveMarker(8);

        case '9'
            updateActiveMarker(9);

        case '0'
            updateActiveMarker(10);


        % -----------------------------------------------------------
        % ESCAPE = STOP PLAYBACK
        % -----------------------------------------------------------

        case 'escape'

            stopPlayback();

    end

end

    %% ---------------------------------------------------------------
    %  HELP WINDOW
    %  ---------------------------------------------------------------

    function showHelp(~,~)

        helpText = sprintf([ ...
            'KEYBOARD SHORTCUTS\n' ...
            '\n' ...
            'Playback\n' ...
            '  SPACE        Play / Pause video\n' ...
            '\n' ...
            'Frame Navigation\n' ...
            '  LEFT ARROW   Previous frame\n' ...
            '  RIGHT ARROW  Next frame\n' ...
            '\n' ...
            'Marker Selection\n' ...
            '  1            Marker 1\n' ...
            '  2            Marker 2\n' ...
            '  3            Marker 3\n' ...
            '  4            Marker 4\n' ...
            '  5            Marker 5\n' ...
            '  6            Marker 6\n' ...
            '  7            Marker 7\n' ...
            '  8            Marker 8\n' ...
            '  9            Marker 9\n' ...
            '  0            Marker 10\n' ...
            '\n' ...
            'Other\n' ...
            '  ESCAPE       Stop playback\n' ...
            '\n' ...
            'Mouse / GUI\n' ...
            '  MARK START   Set behavioral start\n' ...
            '  MARK END     Set behavioral end\n' ...
            '  << BACK      Previous window\n' ...
            '  NEXT >>      Next window\n' ...
            '  DELETE       Delete a segment\n' ...
            '  EXPORT       Export segment matrix\n' ...
            ]);

        helpFig = uifigure( ...
            'Name','Keyboard Shortcuts', ...
            'Position',[500 300 430 600], ...
            'Resize','off');

        uitextarea(helpFig, ...
            'Value',splitlines(helpText), ...
            'Editable','off', ...
            'FontName','Consolas', ...
            'FontSize',14, ...
            'Position',[20 20 390 560]);

    end




    %% ---------------------------------------------------------------
    %  DELETE SEGMENT
    %  ---------------------------------------------------------------

    function deleteRow(~,~)

        % Since table is hidden in this version,
        % deletion is handled through a simple dialog.

        if isempty(segments)

            uialert( ...
                fig, ...
                'There are no segments to delete.', ...
                'Delete');

            return;

        end

        segmentText = strings(size(segments,1),1);

        for j = 1:size(segments,1)

            segmentText(j) = sprintf( ...
                '%d: Start %d | End %d | Code %d', ...
                j, ...
                segments(j,1), ...
                segments(j,2), ...
                segments(j,3));

        end

        [selection,ok] = listdlg( ...
            'PromptString','Select segment to delete:', ...
            'ListString',cellstr(segmentText), ...
            'SelectionMode','single');

        if ok

            segments(selection,:) = [];

            refreshAll();

        end

    end


    %% ---------------------------------------------------------------
    %  UPDATE TABLE
    %  ---------------------------------------------------------------

    function updateTable()

        uit.Data = segments;

    end


    %% ---------------------------------------------------------------
    %  EXPORT
    %  ---------------------------------------------------------------

    function exportData(~,~)

        output = [];

        for j = 1:size(segments,1)

            output = [ ...
                output; ...
                segments(j,1),segments(j,3); ...
                segments(j,2),-segments(j,3)];

        end

        output = sortrows(output,1);

        assignin( ...
            'base', ...
            'segment_output', ...
            output);

        uialert( ...
            fig, ...
            'Exported as "segment_output" to MATLAB Workspace.', ...
            'Success');

    end


    %% ---------------------------------------------------------------
    %  CLEANUP WHEN WINDOW CLOSES
    %  ---------------------------------------------------------------

    fig.CloseRequestFcn = @closeFigure;

    function closeFigure(~,~)

        stopPlayback();

        delete(fig);

    end

end
