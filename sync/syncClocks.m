function A = align_video_to_ephys(led_intensity, ttl, varargin)
% ALIGN_VIDEO_TO_EPHYS  Map ~30 Hz LED-video frames onto a ~30 kHz ephys clock
% using a shared TTL pulse train that both drives the LED and is recorded by
% the ephys system.
%
% The two devices run on independent clocks, so the mapping has both an OFFSET
% (they start at different times) and a SLOPE slightly off 1 (the clocks tick
% at slightly different true rates = drift). We recover both by matching pulse
% edges and fitting a line, then apply it to every frame.
%
% The LED is binarized with a DRIFT-TRACKING threshold: low/high percentile
% envelopes are followed in a sliding window and the threshold sits at their
% local midpoint, so a wandering baseline is handled automatically.
%
% USAGE
%   A = align_video_to_ephys(led_intensity, ttl);
%   A = align_video_to_ephys(led_intensity, ttl, 'BaselineWinS', 8, ...);
%
% INPUTS
%   led_intensity : vector, one LED pixel-intensity value per video frame.
%   ttl           : reconstructed TTL on the EPHYS clock. Either
%                     (a) a logical/numeric vector sampled at FsTtl, or
%                     (b) rising-edge sample indices -> set 'TtlIsEdges',true.
%
% NAME-VALUE OPTIONS
%   'FsTtl'        ephys sample rate (Hz)                      [30000]
%   'FsVid'        nominal video frame rate (Hz)               [30]
%   'FrameTimes'   actual per-frame timestamps (s), if logged. []=uniform 1/FsVid
%   'TtlIsEdges'   true if `ttl` is rising-edge sample indices [false]
%   'LedThresh'    [lo hi] FIXED hysteresis levels; overrides the adaptive
%                  threshold. []=adaptive (recommended for drifting baseline).
%   'BaselineWinS' sliding-window length (s) for the envelopes. []=auto from
%                  the TTL pulse period (~8 periods, clamped 2-60 s).
%   'MaxLagS'      bound (s) on the coarse lag search. []=whole record.
%                  *** For a REGULAR train, set this < one pulse period. ***
%   'NEphys'       length of the ephys signal (samples), used to size the dense
%                  per-sample frame vector. []=numel(ttl) when ttl is a vector;
%                  REQUIRED if 'TtlIsEdges' is true.
%   'MaxSampleGapS' max |time| between an ephys sample and its nearest frame
%                  before that sample is set to NaN in .ephysSampleToFrame.
%                  []=one video frame period (1/FsVid). Catches gaps: samples
%                  before the first frame, after the last, or in dropped-frame
%                  holes get NaN rather than a distant frame index.
%   'CsvPath'      if nonempty, write the per-frame table to this .csv path. ['']
%   'Plot'         show diagnostic + overlay figures            [true]
%
% OUTPUT struct A
%   .a, .b            ephys_t = a*video_t + b   (a = clock ratio, b = offset s)
%   FRAME -> EPHYS (one entry per video frame):
%     .frameEphysTime   ephys-clock time (s) for EVERY video frame (may be <0
%                       if the LED/video started before the ephys recording)
%     .frameEphysSample nearest ephys sample index for every frame (may be <1
%                       or >NEphys for frames outside the recording window)
%     .frameInRecording logical; false for frames that fall before the ephys
%                       start or after its end. FILTER ON THIS before indexing
%                       ephys, e.g.  s = A.frameEphysSample(A.frameInRecording);
%   EPHYS -> FRAME:
%     .ephysSampleToFrame  double vector, LENGTH OF THE EPHYS SIGNAL; element n
%                          is the frame index closest in time to ephys sample n,
%                          or NaN if the nearest frame is more than one frame
%                          period away (sample falls in a gap / outside video).
%     .ephysTimeToFrame(t) function handle: ephys time (s) -> fractional frame #
%   TABLE:
%     .frameTable       [frame | videoTime_s | ephysTime_s | ephysSample]
%                       written to CSV if 'CsvPath' is set.
%   .nMatched         edge pairs used in the fit
%   .residualStd      std of match residuals (s); expect ~1/(FsVid*sqrt(12))
%   .ledBinary        the binarized LED (after drift-tracking threshold)
%   .videoEdgeTime, .ephysEdgeTime  detected rising-edge times (own clocks)

% ---------- parse -----------------------------------------------------------
p = inputParser;
p.addParameter('FsTtl', 30000);
p.addParameter('FsVid', 30);
p.addParameter('FrameTimes', []);
p.addParameter('TtlIsEdges', false);
p.addParameter('LedThresh', []);
p.addParameter('BaselineWinS', []);
p.addParameter('MaxLagS', []);
p.addParameter('NEphys', []);
p.addParameter('MaxSampleGapS', []);
p.addParameter('CsvPath', '');
p.addParameter('Plot', true);
p.parse(varargin{:});
o = p.Results;

x = double(led_intensity(:));
nFrames = numel(x);
if isempty(o.FrameTimes)
    vt_all = (0:nFrames-1)' / o.FsVid;
else
    vt_all = o.FrameTimes(:);
    assert(numel(vt_all)==nFrames, 'FrameTimes length must match led_intensity.');
end

% ---------- 1. rising edges on the EPHYS side -------------------------------
if o.TtlIsEdges
    et = ttl(:) / o.FsTtl;
    ttlDurS = max(et);
    pPulse  = median(diff(et));
    bt = [];                                        % no state vector available
else
    bt = double(ttl(:)) > 0.5;
    etIdx = find(diff([0;bt]) == 1);
    ftIdx = find(diff([bt;0]) == -1);
    et = etIdx / o.FsTtl;
    ttlDurS = numel(bt) / o.FsTtl;
    pPulse  = median(diff(etIdx)) / o.FsTtl;
    wPulse  = median(ftIdx - etIdx) / o.FsTtl;
    if wPulse < 1/o.FsVid || pPulse < 2/o.FsVid
        warning(['TTL pulse width (%.4f s) or period (%.4f s) is near/below ' ...
            'the frame time (%.4f s); the 30 Hz LED may miss or alias pulses.'], ...
            wPulse, pPulse, 1/o.FsVid);
    end
end

% ---------- 2. binarize the LED with a DRIFT-TRACKING threshold -------------
if isempty(o.BaselineWinS)
    winS = min(max(8*pPulse, 2), 60);               % ~8 pulse periods, clamped
else
    winS = o.BaselineWinS;
end
W = max(3, round(winS * o.FsVid));                  % window in frames

if isempty(o.LedThresh)
    loEnv = moving_prctile(x, 15, W);               % tracks the OFF floor
    hiEnv = moving_prctile(x, 85, W);               % tracks the ON level
    mid   = (loEnv + hiEnv)/2;
    span  = hiEnv - loEnv;
    band  = 0.20 * span;                            % hysteresis half-width
    loT   = mid - band;
    hiT   = mid + band;
    % In stretches where on/off separation collapses to noise, disable the
    % trigger so a flat/dark segment can't emit phantom edges.
    noise     = 1.4826 * median(abs(x - movmedian(x, 5)));
    spanFloor = 6 * max(noise, eps);
    flat      = span < spanFloor;
    loT(flat) = inf;  hiT(flat) = inf;
else
    loT = repmat(o.LedThresh(1), nFrames, 1);
    hiT = repmat(o.LedThresh(2), nFrames, 1);
    loEnv = loT; hiEnv = hiT; span = hiT - loT;     % for plotting only
end

b = false(nFrames,1); s = false;                    % Schmitt trigger
for i = 1:nFrames
    if s,  if x(i) < loT(i), s = false; end
    else,  if x(i) > hiT(i), s = true;  end
    end
    b(i) = s;
end
vEdgeIdx = find(diff([0;b]) == 1);
vt = vt_all(vEdgeIdx);

if numel(vt) < 2 || numel(et) < 2
    error(['Too few edges (video=%d, ephys=%d). Check BaselineWinS/LedThresh ' ...
        'and the TTL input.'], numel(vt), numel(et));
end

% ---------- 3. coarse lag (binned edge trains, xcorr) -----------------------
dt = 1/o.FsVid;
edges = 0 : dt : max([vt;et;ttlDurS]) + dt;
hv = histcounts(vt, edges);  hv = hv - mean(hv);
he = histcounts(et, edges);  he = he - mean(he);
if isempty(o.MaxLagS)
    [c,lg] = xcorr(he, hv);
else
    [c,lg] = xcorr(he, hv, round(o.MaxLagS/dt));
end
[~,k] = max(c);
lag0 = lg(k) * dt;

% ---------- 4. match video edges to nearest ephys edge ----------------------
tol = 1.5 / o.FsVid;
mt = nan(size(vt));
for i = 1:numel(vt)
    [d,j] = min(abs(et - (vt(i) + lag0)));
    if d < tol, mt(i) = et(j); end
end
keep = ~isnan(mt);
vt_m = vt(keep);  et_m = mt(keep);

% ---------- 5. robust linear fit  ephys_t = a*video_t + b -------------------
idx = true(size(vt_m));
for it = 1:6
    pp  = polyfit(vt_m(idx), et_m(idx), 1);
    res = et_m - polyval(pp, vt_m);
    sig = 1.4826 * mad(res(idx),1);
    ni  = abs(res) < 4*max(sig, eps);
    if isequal(ni, idx), break; end
    idx = ni;
end
a = pp(1);  bb = pp(2);
resFinal = et_m(idx) - polyval(pp, vt_m(idx));

% ---------- 6. apply to every frame ----------------------------------------
frameEphysTime   = a*vt_all + bb;
frameEphysSample = round(frameEphysTime * o.FsTtl) + 1;   % may be <1 or >Nephys

% ephys length, so we can flag frames that fall outside the recording window
if ~isempty(o.NEphys)
    Nephys = o.NEphys;
elseif ~o.TtlIsEdges
    Nephys = numel(bt);
else
    Nephys = [];                                    % unknown (edges-only input)
end

% A NEGATIVE offset (b<0) means the LED/video started BEFORE the ephys
% recording, so early frames have no ephys counterpart (frameEphysSample<1).
% A video that outlasts the ephys leaves late frames past the end. Flag both
% instead of returning invalid indices.
hiN = Nephys; if isempty(hiN), hiN = max(frameEphysSample); end
frameInRecording = frameEphysSample >= 1 & frameEphysSample <= hiN;
nBefore = sum(frameEphysSample < 1);
nAfter  = sum(frameEphysSample > hiN);

% inverse mapper (ephys time -> fractional frame). interp1 on the monotonic
% frameEphysTime works for uniform AND non-uniform (dropped-frame) time bases.
frameIdx = (1:nFrames)';
ephysTimeToFrame = @(t) interp1(frameEphysTime, frameIdx, t, 'linear','extrap');

% dense ephys-sample -> nearest frame index: a vector the LENGTH OF THE EPHYS
% signal, element n = frame whose time is closest to ephys sample n. Frame
% boundaries sit at the midpoint (in samples) between consecutive frames.
% Any sample whose nearest frame is more than one frame period away (it falls
% in a gap: before the first frame, after the last, or a dropped-frame hole)
% is set to NaN instead of being snapped to a distant frame. NaN requires
% floating point, so this vector is DOUBLE (not uint32).
if ~isempty(Nephys)
    if isempty(o.MaxSampleGapS), gapTol = 1/o.FsVid; else, gapTol = o.MaxSampleGapS; end
    mids  = (frameEphysSample(1:end-1) + frameEphysSample(2:end)) / 2;
    edges = [-inf; mids(:); inf];
    ephysSampleToFrame = nan(Nephys, 1);            % gaps remain NaN
    chunk = 5e6;                                     % keep peak memory modest
    for s0 = 1:chunk:Nephys
        s1  = min(Nephys, s0+chunk-1);
        nn  = (s0:s1)';
        f   = discretize(nn, edges);                % nearest frame, 1..nFrames
        far = abs((nn-1)/o.FsTtl - frameEphysTime(f)) > gapTol;
        f(far) = NaN;
        ephysSampleToFrame(s0:s1) = f;
    end
else
    ephysSampleToFrame = [];
    warning(['Ephys length unknown (TtlIsEdges=true and no ''NEphys'' given); ' ...
        'per-sample frame vector not built. Pass ''NEphys'',numel(ephys_signal).']);
end

% per-frame table: one row per video frame
frameTable = table(frameIdx, vt_all, frameEphysTime, frameEphysSample, frameInRecording, ...
    'VariableNames', {'frame','videoTime_s','ephysTime_s','ephysSample','inRecording'});

A = struct('a',a,'b',bb, ...
    'frameEphysTime',frameEphysTime, 'frameEphysSample',frameEphysSample, ...
    'frameInRecording',frameInRecording, ...
    'ephysTimeToFrame',ephysTimeToFrame, 'ephysSampleToFrame',ephysSampleToFrame, ...
    'frameTable',frameTable, ...
    'nMatched',sum(idx), 'residualStd',std(resFinal), ...
    'ledBinary',b, 'videoEdgeTime',vt, 'ephysEdgeTime',et, 'coarseLag',lag0);

if ~isempty(o.CsvPath)
    writetable(frameTable, o.CsvPath);
    fprintf('wrote %s (%d rows)\n', o.CsvPath, height(frameTable));
end

fprintf('\n--- alignment ---\n');
fprintf('LED baseline window: %.1f s\n', W/o.FsVid);
fprintf('matched edges      : %d of %d video / %d ephys\n', sum(idx), numel(vt), numel(et));
fprintf('clock ratio (a)    : %.7f  (%+.1f ppm drift)\n', a, (a-1)*1e6);
fprintf('offset (b)         : %.4f s\n', bb);
fprintf('residual std       : %.4f s   (quantization floor ~%.4f s)\n', ...
        std(resFinal), 1/(o.FsVid*sqrt(12)));
if bb < 0
    fprintf('offset is NEGATIVE : LED/video began ~%.3f s before ephys recording.\n', -bb);
end
if nBefore > 0
    fprintf('  %d frames precede the ephys start (ephysSample<1, flagged inRecording=false).\n', nBefore);
end
if nAfter > 0
    fprintf('  %d frames fall past the ephys end (flagged inRecording=false).\n', nAfter);
end

% ---------- 7. figures ------------------------------------------------------
if o.Plot
    % ----- diagnostics -----
    figure('Name','alignment diagnostics');
    seg = 1:min(nFrames, round(min(30, 12*pPulse)*o.FsVid));  % a readable slice
    subplot(2,2,1);
    plot(vt_all(seg), x(seg), 'Color',[.6 .6 .6]); hold on;
    plot(vt_all(seg), loEnv(seg), 'b', vt_all(seg), hiEnv(seg), 'b');
    plot(vt_all(seg), (loT(seg)+hiT(seg))/2, 'r--');
    ee = vEdgeIdx(ismember(vEdgeIdx, seg));
    plot(vt_all(ee), x(ee), 'r.', 'MarkerSize', 10);
    xlabel('video time (s)'); title('LED + tracked envelopes/threshold'); ylim padded;

    subplot(2,2,2);
    plot(vt_m, et_m, '.'); hold on; plot(vt_m, polyval(pp,vt_m), 'r');
    xlabel('video-clock edge (s)'); ylabel('ephys-clock edge (s)');
    title(sprintf('edge fit (%d pts)', sum(idx)));

    subplot(2,2,3);
    histogram(resFinal*1e3, 40); xlabel('residual (ms)'); title('match residuals');

    subplot(2,2,4);
    plot(a*vt+bb, 1:numel(vt)); hold on; plot(et, 1:numel(et));
    xlabel('ephys time (s)'); ylabel('cumulative edge #');
    legend('video (mapped)','ephys','Location','southeast');
    title('cumulative edges after alignment');

    % ----- the two input signals AFTER alignment -----
    figure('Name','input signals after alignment');
    ledNorm = min(max((x - loEnv)./max(span,eps), 0), 1);   % LED -> [0,1]

    % (top) full span, both at frame resolution on the ephys clock
    subplot(2,1,1);
    plot(frameEphysTime, ledNorm, 'Color',[.85 .33 .1]); hold on;
    if ~isempty(bt)
        ttlAtFrame = double(bt(min(max(frameEphysSample,1),numel(bt))));
        stairs(frameEphysTime, ttlAtFrame, 'Color',[0 .45 .74]);
        legend('LED (normalized)','TTL','Location','best');
    else
        stem(a*et+bb, ones(size(et)), 'Marker','none', 'Color',[0 .45 .74]);
        legend('LED (normalized)','TTL rising edges','Location','best');
    end
    xlabel('ephys-clock time (s)'); title('full record, aligned'); ylim([-0.1 1.1]);

    % (bottom) zoom to a window with pulses, TTL at TRUE 30 kHz resolution
    w0 = max(0, (a*et_m(1)+bb) - pPulse);
    w1 = w0 + min(max(10*pPulse, 2), 15);
    subplot(2,1,2); hold on;
    fmask = frameEphysTime >= w0 & frameEphysTime <= w1;
    stairs(frameEphysTime(fmask), ledNorm(fmask), 'Color',[.85 .33 .1], 'LineWidth',1.2);
    if ~isempty(bt)
        s0 = max(1, round(w0*o.FsTtl)); s1 = min(numel(bt), round(w1*o.FsTtl));
        tt = (s0:s1)/o.FsTtl;  ds = max(1, round(numel(tt)/50000));
        stairs(tt(1:ds:end), bt(s0:ds:s1), 'Color',[0 .45 .74], 'LineWidth',1.2);
    else
        ez = et(et>=w0 & et<=w1);
        stem(a*ez+bb, ones(size(ez)), 'Marker','none', 'Color',[0 .45 .74]);
    end
    plot(frameEphysTime(fmask), ledNorm(fmask), 'k.', 'MarkerSize', 8);  % actual frames
    xlabel('ephys-clock time (s)'); ylabel('normalized');
    title('zoom: LED frames vs TTL at true resolution'); ylim([-0.1 1.1]);
    legend('LED (frames)','TTL','frame samples','Location','best');
end
end

% ===========================================================================
function env = moving_prctile(x, pct, W)
% Sliding-window percentile via overlapping blocks + linear interpolation.
% Fast and toolbox-free; smooth enough to serve as a tracking envelope.
n    = numel(x);
half = round(W/2);
step = max(1, round(W/4));
ctr  = unique([1:step:n, n]);
val  = zeros(numel(ctr),1);
for i = 1:numel(ctr)
    a = max(1, ctr(i)-half);
    b = min(n, ctr(i)+half);
    val(i) = prctile(x(a:b), pct);
end
env = interp1(ctr, val, (1:n)', 'linear', 'extrap');
end