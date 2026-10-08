function video_roi_gui()
    % Create the main figure
    fig = uifigure('Name', 'Video ROI Intensity Analyzer', 'Position', [100 100 800 600]);
    
    % Layout components
    btnLoad = uibutton(fig, 'Text', 'Load .avi File', 'Position', [20, 550, 120, 30], 'ButtonPushedFcn', @(~,~) loadVideo());
    btnROI  = uibutton(fig, 'Text', 'Draw ROI', 'Position', [150, 550, 100, 30], 'Enable', 'off', 'ButtonPushedFcn', @(~,~) addROI());
    btnRun  = uibutton(fig, 'Text', 'Process Video', 'Position', [260, 550, 120, 30], 'Enable', 'off', 'ButtonPushedFcn', @(~,~) processVideo());
    btnSave = uibutton(fig, 'Text', 'Save Data', 'Position', [390, 550, 100, 30], 'Enable', 'off', 'ButtonPushedFcn', @(~,~) saveData());
    
    ax = uiaxes(fig, 'Position', [50, 100, 700, 400]);
    lblStatus = uilabel(fig, 'Text', 'Status: Waiting for file...', 'Position', [20, 20, 400, 30]);

    % Internal State
    v = [];
    rois = {};
    results = [];

    % --- Callback Functions ---
    
    function loadVideo()
        [file, path] = uigetfile('*.avi', 'Select a Video File');
        if isequal(file, 0), return; end
        
        v = VideoReader(fullfile(path, file));
        frame = readFrame(v); % Read first frame
        imshow(frame, 'Parent', ax);
        
        lblStatus.Text = ['Loaded: ' file];
        btnROI.Enable = 'on';
    end

    function addROI()
        lblStatus.Text = 'Click and drag to draw an ROI. Double-click to finish.';
        h = drawfreehand(ax); % Modern ROI tool
        if ~isempty(h)
            rois{end+1} = h;
            lblStatus.Text = sprintf('ROI %d added.', length(rois));
            btnRun.Enable = 'on';
        end
    end

    function processVideo()
        if isempty(v), return; end
        lblStatus.Text = 'Processing frames... please wait.';
        drawnow;
        
        % Reset video to start
        v.CurrentTime = 0;
        numFrames = floor(v.FrameRate * v.Duration);
        results = zeros(numFrames, length(rois));
        
        frameIdx = 1;
        while hasFrame(v)
            img = readFrame(v);
            % Convert to grayscale if necessary
            if size(img, 3) == 3
                grayImg = rgb2gray(img);
            else
                grayImg = img;
            end
            
            % Extract mean for each ROI
            for i = 1:length(rois)
                mask = createMask(rois{i});
                results(frameIdx, i) = mean(grayImg(mask), 'all');
            end
            frameIdx = frameIdx + 1;
        end
        
        lblStatus.Text = 'Processing complete!';
        btnSave.Enable = 'on';
        
        % Plot results in a new window for quick preview
        figure;
        plot(results);
        title('Mean Intensity over Time');
        xlabel('Frame Number'); ylabel('Intensity');
        legend(arrayfun(@(x) sprintf('ROI %d', x), 1:length(rois), 'UniformOutput', false));
    end

    function saveData()
        [file, path] = uiputfile('*.mat', 'Save ROI Data');
        if isequal(file, 0), return; end
        
        % Save as a struct or matrix
        roi_data = results;
        save(fullfile(path, file), 'roi_data');
        lblStatus.Text = 'Data saved successfully.';
    end
end