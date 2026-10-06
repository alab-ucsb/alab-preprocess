function info = checkVideoFPS(videoFile, doFullScan)
% checkVideoFPS  Report the header frame rate and the measured frame rate of a video.
%   info = checkVideoFPS('video.avi')        % header info only (fast)
%   info = checkVideoFPS('video.avi', true)  % also reads every frame's timestamp

if nargin < 2, doFullScan = false; end

v = VideoReader(videoFile);

info.file        = videoFile;
info.nominalFPS  = v.FrameRate;
info.duration    = v.Duration;                 % seconds
info.nFramesHdr  = v.NumFrames;                % frame count from the header
info.resolution  = [v.Width v.Height];

fprintf('File:          %s\n', videoFile);
fprintf('Nominal FPS:   %.4f\n', info.nominalFPS);
fprintf('Duration:      %.3f s\n', info.duration);
fprintf('Frames (hdr):  %d\n', info.nFramesHdr);
fprintf('Duration*FPS:  %.1f\n', info.duration * info.nominalFPS);

if doFullScan
    % Read every frame's timestamp to measure the real rate
    t = nan(info.nFramesHdr + 100, 1);
    k = 0;
    v.CurrentTime = 0;
    while hasFrame(v)
        k = k + 1;
        t(k) = v.CurrentTime;   % timestamp before the read = this frame's time
        readFrame(v);
    end
    t = t(1:k);
    dt = diff(t);

    info.timestamps   = t;
    info.nFramesRead  = k;
    info.measuredFPS  = 1 / median(dt);
    info.meanFPS      = (k - 1) / (t(end) - t(1));
    info.dtRange      = [min(dt) max(dt)];
    info.nLongGaps    = sum(dt > 1.5 * median(dt));   % possible dropped frames

    fprintf('Frames (read): %d\n', k);
    fprintf('Measured FPS (median dt): %.4f\n', info.measuredFPS);
    fprintf('Mean FPS:      %.4f\n', info.meanFPS);
    fprintf('dt range:      %.4f - %.4f s\n', info.dtRange);
    fprintf('Gaps >1.5x median dt: %d\n', info.nLongGaps);

    figure; plot(dt * 1000, '.');
    xlabel('Frame'); ylabel('Inter-frame interval (ms)');
    title(sprintf('%s  (median %.2f fps)', videoFile, info.measuredFPS), 'Interpreter', 'none');
end
end