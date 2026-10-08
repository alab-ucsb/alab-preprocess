function SegmentScanner(inputData)
    if nargin < 1 || size(inputData, 2) < 2
        error('Input must be a matrix with at least 2 columns.');
    end

    % --- State Variables ---
    data = inputData;
    numRows = size(data, 1);
    winSize = min(500, numRows);
    currStart = 1;
    activeCode = 1; 
    pendingStartIdx = []; % Stores the start index if user hasn't clicked end yet
    segments = zeros(0, 3); 
    colors = lines(10); 
    markerButtons = gobjects(1, 10);

    % --- Global Fixed Axes Limits (99.5% Coverage) ---
    xLimitsGlobal = prctile(data(:,1), [0.25, 99.75]);
    yLimitsGlobal = prctile(data(:,2), [0.25, 99.75]);
    dx = diff(xLimitsGlobal) * 0.1; dy = diff(yLimitsGlobal) * 0.1;
    if dx == 0, dx = 1; end 
    if dy == 0, dy = 1; end
    globalXRange = [xLimitsGlobal(1)-dx, xLimitsGlobal(2)+dx];
    globalYRange = [yLimitsGlobal(1)-dy, yLimitsGlobal(2)+dy];

    % --- UI Layout ---
    fig = uifigure('Name', 'Multi-Page Segment Marker', 'Position', [50 50 1150 850]);
    mainGrid = uigridlayout(fig, [2, 2]);
    mainGrid.RowHeight = {'1x', 260};
    mainGrid.ColumnWidth = {'1x', 320};

    ax = uiaxes(mainGrid);
    ax.Layout.Row = 1; ax.Layout.Column = 1;
    grid(ax, 'on'); hold(ax, 'on');
    xlim(ax, globalXRange); ylim(ax, globalYRange);
    disableDefaultInteractivity(ax);

    uit = uitable(mainGrid, 'Data', segments, 'ColumnName', {'Start', 'End', 'Code'}, 'SelectionType', 'row');
    uit.Layout.Row = 1; uit.Layout.Column = 2;

    ctrlGrid = uigridlayout(mainGrid, [4, 1]);
    ctrlGrid.Layout.Row = 2; ctrlGrid.Layout.Column = 1;
    ctrlGrid.RowHeight = {30, '1x', '1x', '1x'};

    lblProgress = uilabel(ctrlGrid, 'Text', 'Progress: 0%', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');

    mGrid = uigridlayout(ctrlGrid, [1, 10]);
    for i = 1:10
        markerButtons(i) = uibutton(mGrid, 'Text', num2str(i), 'BackgroundColor', colors(i,:), ...
            'FontColor', 'w', 'ButtonPushedFcn', @(btn, e) updateActiveMarker(i));
    end
    
    navGrid = uigridlayout(ctrlGrid, [1, 4]);
    uibutton(navGrid, 'Text', '<< Back', 'ButtonPushedFcn', @(~,~) movePage(-1));
    uilabel(navGrid, 'Text', 'Window Len:', 'HorizontalAlignment', 'right');
    uieditfield(navGrid, 'numeric', 'Value', winSize, 'ValueChangedFcn', @(n,e) updateWinSize(n.Value));
    uibutton(navGrid, 'Text', 'Next >>', 'ButtonPushedFcn', @(~,~) movePage(1));

    btnGrid = uigridlayout(ctrlGrid, [1, 4]);
    btnStart = uibutton(btnGrid, 'Text', 'MARK START', 'ButtonPushedFcn', @setStart, 'BackgroundColor', [.2 .6 .2], 'FontColor', 'w');
    btnEnd = uibutton(btnGrid, 'Text', 'MARK END', 'ButtonPushedFcn', @setEnd, 'BackgroundColor', [.6 .2 .2], 'FontColor', 'w', 'Enable', 'off');
    uibutton(btnGrid, 'Text', 'Delete Selected', 'ButtonPushedFcn', @deleteRow);
    uibutton(btnGrid, 'Text', 'Export Matrix', 'ButtonPushedFcn', @exportData);

    % --- Logic ---

    function updateActiveMarker(val)
        activeCode = val;
        for i = 1:10
            markerButtons(i).FontWeight = 'normal';
            markerButtons(i).Text = num2str(i);
        end
        markerButtons(activeCode).FontWeight = 'bold';
        markerButtons(activeCode).Text = ['[' num2str(activeCode) ']'];
    end

    function movePage(direction)
        currStart = max(1, min(currStart + (direction * winSize), numRows - 1));
        refreshPlot();
    end

    function updateWinSize(val)
        winSize = round(val); refreshPlot();
    end

    function refreshPlot()
        delete(ax.Children); 
        endIdx = min(currStart + winSize, numRows);
        viewRange = currStart:endIdx;
        
        lblProgress.Text = sprintf('Progress: %d%% (Row %d of %d)', round((currStart/numRows)*100), currStart, numRows);
        plot(ax, data(viewRange, 1), data(viewRange, 2), 'Color', [0.8 0.8 0.8]);
        
        % Visual feedback if a start is pending but end is not yet clicked
        if ~isempty(pendingStartIdx)
            title(ax, sprintf('PENDING START AT INDEX %d | FIND END POINT', pendingStartIdx), 'Color', 'r');
            if ismember(pendingStartIdx, viewRange)
                plot(ax, data(pendingStartIdx,1), data(pendingStartIdx,2), 'ro', 'MarkerSize', 10, 'LineWidth', 2);
            end
        else
            title(ax, sprintf('Rows %d to %d | Marker %d Active', currStart, endIdx, activeCode));
        end

        for i = 1:size(segments, 1)
            s = segments(i, 1); e = segments(i, 2); c = segments(i, 3);
            overlap = intersect(s:e, viewRange);
            if ~isempty(overlap)
                plot(ax, data(overlap, 1), data(overlap, 2), 'LineWidth', 3, 'Color', colors(c, :));
            end
        end
    end

    function setStart(~, ~)
        p = drawpoint(ax, 'Color', colors(activeCode,:));
        pendingStartIdx = findNearest(p.Position);
        delete(p);
        btnStart.Enable = 'off';
        btnEnd.Enable = 'on';
        refreshPlot();
    end

    function setEnd(~, ~)
        p = drawpoint(ax, 'Color', colors(activeCode,:));
        idx2 = findNearest(p.Position);
        delete(p);
        
        % Finalize segment
        newSeg = [min(pendingStartIdx, idx2), max(pendingStartIdx, idx2), activeCode];
        segments = [segments; newSeg];
        segments = sortrows(segments, 1);
        uit.Data = segments;
        
        % Reset State
        pendingStartIdx = [];
        btnStart.Enable = 'on';
        btnEnd.Enable = 'off';
        refreshPlot();
    end

    function deleteRow(~, ~)
        s = uit.Selection;
        if ~isempty(s)
            segments(s, :) = [];
            uit.Data = segments;
            refreshPlot();
        end
    end

    function idx = findNearest(pos)
        endIdx = min(currStart + winSize, numRows);
        vr = currStart:endIdx;
        distSq = (data(vr, 1) - pos(1)).^2 + (data(vr, 2) - pos(2)).^2;
        [~, m] = min(distSq);
        idx = vr(m);
    end

    function exportData(~, ~)
        output = [];
        for i = 1:size(segments,1)
            output = [output; segments(i, 1), segments(i, 3); segments(i, 2), -segments(i, 3)];
        end
        assignin('base', 'segment_output', sortrows(output, 1));
        uialert(fig, 'Exported to Workspace.', 'Success');
    end

    updateActiveMarker(1);
    refreshPlot();
end