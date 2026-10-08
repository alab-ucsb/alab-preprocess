function A = syncClocksCamLED(led_intensity, ledTtl, camTtl, varargin)
% SYNCCLOCKSCAMLED  Map video frames onto the ephys clock two ways
% (LED-in-frame sync and camera frame-TTL sync), compare them, and return the
% better mapping in the same format as ALIGN_VIDEO_TO_EPHYS.
%
% METHOD 1 - LED: a TTL train drives an LED in the camera's view and is also
%   recorded by ephys. LED rising edges (video clock) are matched to TTL rising
%   edges (ephys clock) and a line  ephys_t = a*video_t + b  is fit. Per-frame
%   precision is limited by the model: it assumes frame times are known
%   (uniform 1/FsVid, or 'FrameTimes'), so dropped frames / frame jitter that
%   are not in FrameTimes become errors.
%
% METHOD 2 - CAMERA: the camera emits one TTL per frame (exposure strobe or
%   hardware trigger), recorded by ephys. Each saved frame k is assigned camera
%   pulse k+m, giving its time directly at ephys resolution. The pulse-index
%   offset m is NOT assumed to be 0: cameras often emit extra pulses before/after
%   saving, and frames/pulses can be dropped mid-session. m is solved for at each
%   LED edge (the LED tells us which pulse a given frame belongs to), smoothed,
%   and changes in m are localized to the dropped frame / missing pulse.
%
% COMPARISON: (i) per-frame difference between the two mappings; (ii) an
%   LED-edge "bracketing" test: for a correct per-frame mapping, each ephys LED
%   edge lands within one frame period of the frame where the LED first appears,
%   with a constant offset. Violations mean that mapping is off by >= ~1/2 frame
%   there. (iii) camera pulse-train health (count vs frames, gaps, glitches).
%   With 'Method','auto' the camera mapping is used when it is valid and passes
%   the bracketing test at least as well as the LED fit; otherwise the LED fit.
%
% USAGE  (pass [] for whichever sync a session does not have)
%   A = syncClocksCamLED(led_intensity, ledTtl, camTtl);   % both
%   A = syncClocksCamLED(led_intensity, ledTtl, []);       % LED only
%   A = syncClocksCamLED([], [], camTtl, 'NFrames', nFrames); % camera only
%
% INPUTS
%   led_intensity : one LED pixel-intensity value per SAVED video frame.
%   ledTtl        : LED TTL on the EPHYS clock: logical/numeric vector at FsTtl,
%                   or edge sample indices (see 'TtlIsEdges').
%   camTtl        : camera frame TTL on the EPHYS clock, same formats.
%   With LED only, the LED fit is returned. With camera only, frames are paired
%   with pulses by count ('CamAlign'), so mid-session dropped frames cannot be
%   located; with both, the LED resolves the pairing and cross-checks it.
%
% NAME-VALUE OPTIONS (all options from align_video_to_ephys, plus *new*)
%   'FsTtl'        ephys sample rate (Hz)                              [30000]
%   'FsVid'        nominal video frame rate (Hz)                       [30]
%   'FrameTimes'   per-frame timestamps (s) from the acquisition software, if
%                  logged. Used by the LED fit, and to locate dropped frames.
%   'TtlIsEdges'   true if TTL inputs are edge SAMPLE INDICES (1-based).
%                  Scalar applies to both; [led cam] sets each.     [false]
%   'LedThresh', 'BaselineWinS', 'MaxLagS'   as before (LED binarization/lag).
%   'NEphys'       ephys length in samples. []=numel of a TTL vector input.
%   'MaxSampleGapS' as before; []=one frame period.
%   'CsvPath'      write the per-frame table to this .csv              ['']
%   'Plot'         diagnostic figures                                  [true]
%  *'Method'       'auto' | 'led' | 'camera'  which mapping to return  ['auto']
%  *'CamEdge'      'rising' | 'falling'  camera TTL edge marking a frame
%                                                                  ['rising']
%  *'CamPulseAt'   'start' | 'end'  whether that edge marks the start or end of
%                  exposure. Resolves the one-frame ambiguity in pairing pulses
%                  with frames. Hardware trigger / "ExposureActive" rising edge
%                  = 'start'.                                       ['start']
%  *'CamLatencyS'  constant added to camera pulse times, e.g. +exposure/2 to
%                  time-stamp mid-exposure.                             [0]
%  *'CamOffsetFrames'  force pulse index = frame index + this integer for the
%                  whole session (skips LED-based pulse pairing).       []
%  *'EdgesIncludeFalling'  true if an edge list holds BOTH rising and falling
%                  edges, alternating (2 events per pulse). Scalar or [led cam].
%                  The function splits them; 'CamEdge' then picks which edge
%                  times a frame.                                    [false]
%  *'FirstEdge'    'rising' | 'falling': the first event in such a list.
%                  Char for both, or {led, cam}. Check the printed HIGH/LOW
%                  durations: camera HIGH should equal exposure.   ['rising']
%  *'NFrames'      number of saved video frames. Required for camera-only
%                  sync (otherwise taken from numel(led_intensity)).    []
%  *'LedPolarity'  'auto' | 'normal' | 'inverted'. 'inverted' = LED reads
%                  bright while the TTL is LOW (inverted TTL or inverted LED
%                  signal). 'auto' fits both and keeps the one whose LED on/off
%                  state matches the TTL high/low state (needs a TTL vector or
%                  'EdgesIncludeFalling'; with rising edges only it falls back to
%                  fit quality and warns if unclear).               ['auto']
%  *'CamAlign'     camera-only pairing when pulse count ~= frame count:
%                  'first' (pulse 1 = frame 1) | 'last' (last pulse = last
%                  frame).                                          ['first']
%  *'MaxRateErrPpm' search range for the video-vs-ephys clock-rate error in
%                  the LED lag search (true frame rate vs FsVid).    [3000]
%  *'CamMinMatchFrac'  fraction of frames that must get their own camera
%                  pulse for the camera mapping to count as valid.   [0.95]
%
% OUTPUT struct A  (same fields as align_video_to_ephys, from the CHOSEN method)
%   .a, .b, .frameEphysTime, .frameEphysSample, .frameInRecording,
%   .ephysSampleToFrame, .ephysTimeToFrame, .frameTable, .nMatched,
%   .residualStd, .ledBinary, .videoEdgeTime, .ephysEdgeTime, .coarseLag
%   For the camera method, .a/.b are a line fit to the per-frame pulse times
%   (for reference only - frameEphysTime is NOT forced onto that line),
%   .nMatched = frames with their own pulse, .residualStd = std of pulse times
%   about that line (= camera frame-timing jitter + drift curvature).
% *.method       'led' or 'camera' (the one returned)
% *.methodReason  why it was chosen
% *.led, .cam    full results for each method (each has .frameEphysTime etc.)
%                 .led.polarityName = 'normal' | 'inverted'; .ledBinary is the
%                 LED state AFTER polarity correction (true = TTL-high state)
% *.comparison   agreement and bracketing metrics (printed to the console)

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
p.addParameter('Method', 'auto');
p.addParameter('CamEdge', 'rising');
p.addParameter('CamPulseAt', 'start');
p.addParameter('CamLatencyS', 0);
p.addParameter('CamOffsetFrames', []);
p.addParameter('CamMinMatchFrac', 0.95);
p.addParameter('EdgesIncludeFalling', false);
p.addParameter('FirstEdge', 'rising');
p.addParameter('NFrames', []);
p.addParameter('LedPolarity', 'auto');
p.addParameter('CamAlign', 'first');
p.addParameter('MaxRateErrPpm', 3000);
p.parse(varargin{:});
o = p.Results;
o.Method = lower(o.Method);

% accept tables/timetables (e.g. from readtable) as well as plain vectors
led_intensity = as_vector(led_intensity, 'led_intensity');
ledTtl        = as_vector(ledTtl,        'ledTtl');
camTtl        = as_vector(camTtl,        'camTtl');
o.FrameTimes  = as_vector(o.FrameTimes,  'FrameTimes');

% which syncs are present?  pass [] for a sync the session doesn't have
haveLed = ~isempty(ledTtl) && ~isempty(led_intensity);
haveCam = ~isempty(camTtl);
if xor(isempty(ledTtl), isempty(led_intensity))
    warning(['Only one of led_intensity / ledTtl was given; the LED method needs ' ...
        'both, so it is skipped.']);
end
if ~haveLed && ~haveCam
    error('No sync given: provide led_intensity + ledTtl, and/or camTtl.');
end
if haveLed
    x = double(led_intensity(:));
    nFrames = numel(x);
    if ~isempty(o.NFrames) && o.NFrames ~= nFrames
        error('NFrames (%d) does not match numel(led_intensity) (%d).', o.NFrames, nFrames);
    end
else
    x = [];
    if ~isempty(o.NFrames),         nFrames = o.NFrames;
    elseif ~isempty(o.FrameTimes),  nFrames = numel(o.FrameTimes);
    else
        error(['Camera-only sync needs the number of saved video frames: pass ' ...
            '''NFrames'' (or ''FrameTimes'').']);
    end
end
if isempty(o.FrameTimes)
    vt_all = (0:nFrames-1)' / o.FsVid;
else
    vt_all = o.FrameTimes(:);
    assert(numel(vt_all)==nFrames, 'FrameTimes length must match the number of frames.');
end
T = 1/o.FsVid;
tie = logical(o.TtlIsEdges);  if isscalar(tie), tie = [tie tie]; end
o.riseFall = logical(o.EdgesIncludeFalling);
if isscalar(o.riseFall), o.riseFall = [o.riseFall o.riseFall]; end
o.riseFall = o.riseFall & tie;                      % only meaningful for edge lists
if ischar(o.FirstEdge) || isstring(o.FirstEdge), o.firstEdge = {char(o.FirstEdge), char(o.FirstEdge)};
else, o.firstEdge = cellstr(o.FirstEdge); end

% ephys length (needed for the dense per-sample vector)
Nephys = o.NEphys;
if isempty(Nephys)
    if haveLed && ~tie(1),      Nephys = numel(ledTtl);
    elseif haveCam && ~tie(2),  Nephys = numel(camTtl);
    end
end
if haveLed && ~tie(1) && haveCam && ~tie(2) && numel(ledTtl) ~= numel(camTtl)
    warning('LED and camera TTL vectors differ in length (%d vs %d); using %d.', ...
        numel(ledTtl), numel(camTtl), Nephys);
end

% ---------- METHOD 1: LED fit ---------------------------------------------
if haveLed
    L = led_fit(x, vt_all, ledTtl, tie(1), o);
else
    L = struct('ok', false, 'msg', 'not provided');
end

% ---------- METHOD 2: camera frame TTL -------------------------------------
if haveCam
    C = cam_map(camTtl, tie(2), L, vt_all, o);
else
    C = struct('ok', false, 'msg', 'not provided');
end

% ---------- compare ---------------------------------------------------------
cmp = compare_methods(L, C, T, o);

% ---------- choose ----------------------------------------------------------
switch o.Method
    case 'led'
        assert(L.ok, 'LED method failed: %s', L.msg);
        method = 'led';    reason = 'forced (Method=''led'')';
    case 'camera'
        assert(C.ok, 'Camera method failed: %s', C.msg);
        method = 'camera'; reason = 'forced (Method=''camera'')';
    otherwise
        [method, reason] = choose_method(L, C, cmp, o);
end

if strcmp(method, 'camera')
    t = C.frameEphysTime;  a = C.a;  bb = C.b;
    nMatched = C.nMatched; resStd = C.residualStd;
else
    t = L.frameEphysTime;  a = L.a;  bb = L.b;
    nMatched = L.nMatched; resStd = L.residualStd;
end
M = build_mapping(t, vt_all, Nephys, o);

if isfield(L,'ledBinary'), ledB = L.ledBinary; else, ledB = []; end
A = struct('a',a, 'b',bb, ...
    'frameEphysTime',t, 'frameEphysSample',M.frameEphysSample, ...
    'frameInRecording',M.frameInRecording, ...
    'ephysTimeToFrame',M.ephysTimeToFrame, 'ephysSampleToFrame',M.ephysSampleToFrame, ...
    'frameTable',M.frameTable, ...
    'nMatched',nMatched, 'residualStd',resStd, ...
    'ledBinary',ledB, 'videoEdgeTime',getf(L,'vt'), 'ephysEdgeTime',getf(L,'et'), ...
    'coarseLag',getf(L,'lag0'), ...
    'method',method, 'methodReason',reason, 'led',L, 'cam',C, 'comparison',cmp);

if ~isempty(o.CsvPath)
    writetable(M.frameTable, o.CsvPath);
    fprintf('wrote %s (%d rows)\n', o.CsvPath, height(M.frameTable));
end

% ---------- report ----------------------------------------------------------
print_report(L, C, cmp, method, reason, M, a, bb, T, o);

% ---------- figures ---------------------------------------------------------
if o.Plot
    make_plots(x, vt_all, L, C, cmp, A, ledTtl, tie, T, o);
end
end

% ===========================================================================
%  METHOD 1: LED
% ===========================================================================
function L = led_fit(x, vt_all, ttl, isEdges, o)
% Fit the LED sync with the requested polarity, or with both polarities and
% keep the one whose LED on/off state agrees with the TTL high/low state.
[et, bt, pPulse, wPulse, dnT] = ttl_edges(ttl, isEdges, o.FsTtl, 'rising', ...
    o.riseFall(1), o.firstEdge{1}, 'LED TTL');
if ~isnan(wPulse) && (wPulse < 1/o.FsVid || pPulse < 2/o.FsVid)
    warning(['LED TTL pulse width (%.4f s) or period (%.4f s) is near/below ' ...
        'the frame time (%.4f s); the LED may miss or alias pulses.'], ...
        wPulse, pPulse, 1/o.FsVid);
end
if numel(et) < 2
    L = struct('ok', false, 'msg', 'fewer than 2 LED TTL edges'); return;
end
switch lower(o.LedPolarity)
    case 'normal',   pols = 1;
    case 'inverted', pols = -1;
    otherwise,       pols = [1 -1];
end
Ls = cell(1, numel(pols));
for i = 1:numel(pols)
    Ls{i} = led_fit_one(pols(i)*x, vt_all, et, bt, pPulse, dnT, o);
    Ls{i}.polarity = pols(i);
end
if numel(Ls) == 1
    L = Ls{1};  L.polarityHow = sprintf('forced (LedPolarity=''%s'')', o.LedPolarity);
else
    L = pick_polarity(Ls{1}, Ls{2});
end
if L.polarity > 0, L.polarityName = 'normal'; else, L.polarityName = 'inverted'; end
L.xp = L.polarity * x;                               % LED as used (on = high)
L.ttlBinary = bt;
if L.ok && ~isnan(L.stateAgree) && L.stateAgree < 0.8
    warning(['LED on/off state matches the TTL state on only %.0f%% of frames ' ...
        '(%s polarity). Check the LED ROI and TTL channel.'], 100*L.stateAgree, L.polarityName);
end
end

function L = pick_polarity(Ln, Li)
% Ln = normal fit, Li = inverted fit
sc = @(Lx) [Lx.ok, Lx.stateAgree, Lx.inlierFrac, Lx.residualStd];
if ~Ln.ok && ~Li.ok, L = Ln; L.polarityHow = 'both polarities failed'; return; end
if ~Li.ok, L = Ln; L.polarityHow = 'auto: inverted fit failed'; return; end
if ~Ln.ok, L = Li; L.polarityHow = 'auto: normal fit failed'; return; end
sn = sc(Ln); si = sc(Li);
if ~isnan(sn(2)) && ~isnan(si(2))
    % direct test: does LED-on coincide with TTL-high?
    if si(2) > sn(2), L = Li; else, L = Ln; end
    L.polarityHow = sprintf('auto: LED/TTL state agreement normal %.1f%%, inverted %.1f%%', ...
        100*sn(2), 100*si(2));
    if abs(si(2) - sn(2)) < 0.2
        warning('LED polarity unclear (%s). Set ''LedPolarity'' explicitly.', L.polarityHow);
    end
else
    % rising-edge list only (no TTL state): use edge-fit quality
    if si(3) > sn(3) + 0.05 || (abs(si(3)-sn(3)) <= 0.05 && si(4) < 0.8*sn(4))
        L = Li;
    else
        L = Ln;
    end
    L.polarityHow = sprintf(['auto (fit quality; no TTL state available): matched ' ...
        'normal %.0f%% / inverted %.0f%%, residual %.1f / %.1f ms'], ...
        100*sn(3), 100*si(3), 1e3*sn(4), 1e3*si(4));
    if abs(si(3)-sn(3)) <= 0.05 && max(si(4),sn(4)) < 1.25*min(si(4),sn(4))
        warning(['LED polarity ambiguous from rising edges alone (%s). Pass falling ' ...
            'edges too (''EdgesIncludeFalling'') or set ''LedPolarity''.'], L.polarityHow);
    end
end
L.polarityAlt = struct('normal', sn, 'inverted', si);
end

function L = led_fit_one(x, vt_all, et, bt, pPulse, dnT, o)
L = struct('ok', false, 'msg', '', 'stateAgree', NaN, 'inlierFrac', 0, 'residualStd', inf);
nFrames = numel(x);
if isempty(bt), ttlDurS = max([et; dnT]); else, ttlDurS = numel(bt)/o.FsTtl; end

% 2. binarize LED with a drift-tracking threshold
if isempty(o.BaselineWinS), winS = min(max(8*pPulse, 2), 60);
else,                       winS = o.BaselineWinS; end
W = max(3, round(winS * o.FsVid));
if isempty(o.LedThresh)
    loEnv = moving_prctile(x, 15, W);
    hiEnv = moving_prctile(x, 85, W);
    mid   = (loEnv + hiEnv)/2;
    span  = hiEnv - loEnv;
    band  = 0.20 * span;
    loT   = mid - band;   hiT = mid + band;
    noise = 1.4826 * median(abs(x - movmedian(x, 5)));
    flat  = span < 6*max(noise, eps);
    loT(flat) = inf;  hiT(flat) = inf;
else
    loT = repmat(o.LedThresh(1), nFrames, 1);
    hiT = repmat(o.LedThresh(2), nFrames, 1);
    loEnv = loT; hiEnv = hiT; span = hiT - loT;
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
L.ledBinary = b; L.loEnv = loEnv; L.hiEnv = hiEnv; L.loT = loT; L.hiT = hiT;
L.span = span; L.W = W; L.pPulse = pPulse; L.vEdgeIdx = vEdgeIdx;
L.vt = vt; L.et = et;
if numel(vt) < 2, L.msg = 'fewer than 2 LED edges in video'; return; end

% 3. coarse lag AND clock-rate ratio (binned edge trains, xcorr over a grid
%    of rates). The rate search matters when the true frame rate differs
%    from FsVid (e.g. 30.03 vs 30 Hz = 1000 ppm = 2 s over 30 min).
[lag0, r0] = rate_lag_search(vt, et, ttlDurS, o);
L.lag0 = lag0;  L.rate0 = r0;

% 4. match video edges to nearest ephys edge
tol = 1.5 / o.FsVid;
mt = nan(size(vt));
for i = 1:numel(vt)
    [d,j] = min(abs(et - (r0*vt(i) + lag0)));
    if d < tol, mt(i) = et(j); end
end
keep = ~isnan(mt);
vt_m = vt(keep);  et_m = mt(keep);
if numel(vt_m) < 2, L.msg = 'fewer than 2 matched LED edges'; return; end

% 5. robust linear fit  ephys_t = a*video_t + b
idx = true(size(vt_m));
for it = 1:6
    pp  = polyfit(vt_m(idx), et_m(idx), 1);
    res = et_m - polyval(pp, vt_m);
    sig = 1.4826 * median(abs(res(idx) - median(res(idx))));
    ni  = abs(res) < 4*max(sig, eps);
    if isequal(ni, idx), break; end
    idx = ni;
end
L.a = pp(1);  L.b = pp(2);  L.pp = pp;
L.frameEphysTime = L.a*vt_all + L.b;
L.matchFrame  = vEdgeIdx(keep);      % frame where LED first appears ON
L.matchEphys  = et_m;                % matching ephys LED-TTL edge (s)
L.matchVideo  = vt_m;
L.inlier      = idx;
L.resid       = et_m(idx) - polyval(pp, vt_m(idx));
L.nMatched    = sum(idx);
L.residualStd = std(L.resid);
L.inlierFrac  = L.nMatched / numel(vt);

% state agreement: is the TTL high on the frames where the LED reads ON?
tf = L.frameEphysTime;
if ~isempty(bt)
    sI = round(tf*o.FsTtl) + 1;  in = sI >= 1 & sI <= numel(bt);
    st = bt(sI(in));
elseif ~isempty(dnT)
    in = tf >= min(et(1), dnT(1)) & tf <= max(et(end), dnT(end));
    nu = discretize(tf(in), [-inf; et(:); inf]) - 1;     % rises at or before t
    nd = discretize(tf(in), [-inf; dnT(:); inf]) - 1;    % falls at or before t
    st = nu > nd;
else
    in = []; st = [];
end
if ~isempty(st), L.stateAgree = mean(st(:) == b(in)); end
L.ok = true;
end

% ===========================================================================
%  METHOD 2: CAMERA FRAME TTL
% ===========================================================================
function C = cam_map(ttl, isEdges, L, vt_all, o)
C = struct('ok', false, 'msg', '');
nFrames = numel(vt_all);
T = 1/o.FsVid;

ct = ttl_edges(ttl, isEdges, o.FsTtl, o.CamEdge, o.riseFall(2), o.firstEdge{2}, 'camera TTL');
ct = sort(ct(:));
nRaw = numel(ct);
if nRaw < 2, C.msg = 'fewer than 2 camera TTL edges'; return; end

% remove glitch pulses (< 0.5 period after the previous kept pulse)
Tc0  = median(diff(ct));
keepP = true(nRaw,1); last = ct(1);
for i = 2:nRaw
    if ct(i) - last < 0.5*Tc0, keepP(i) = false; else, last = ct(i); end
end
ct = ct(keepP);  Nc = numel(ct);
ipi = diff(ct);  Tc = median(ipi);
C.pulseTime = ct;  C.nPulses = Nc;  C.nGlitch = nRaw - Nc;
C.period = Tc;  C.ipi = ipi;
C.nLongIPI = sum(ipi > 1.5*Tc);                     % missing pulses
C.ipiJitterStd = std(ipi(ipi <= 1.5*Tc));
if abs(Tc - T)/T > 0.05
    warning('Camera TTL period %.4f s differs from 1/FsVid = %.4f s by >5%%.', Tc, T);
end

% ---- pulse-index offset m(k): pulse for frame k is k + m(k) -------------
C.anchorFrame = []; C.anchorM = []; C.anchorMraw = []; C.anchorTime = [];
C.uncertain = false(nFrames,1); C.mSource = '';
if ~isempty(o.CamOffsetFrames)
    m = repmat(round(o.CamOffsetFrames), nFrames, 1);
    C.mSource = 'CamOffsetFrames';
elseif isfield(L,'ok') && L.ok && numel(L.matchFrame) >= 3
    [m, C] = offsets_from_led(L, ct, C, vt_all, o);
else
    if strcmpi(o.CamAlign, 'last'), m0 = Nc - nFrames; else, m0 = 0; end
    m = repmat(m0, nFrames, 1);
    C.mSource = sprintf('no LED anchors; CamAlign=''%s'' -> offset %d', o.CamAlign, m0);
    if Nc ~= nFrames
        warning(['Camera pulses (%d) ~= frames (%d) and no LED to resolve which ' ...
            'pulses belong to saved frames; aligned by ''CamAlign''=''%s'' (pulse ' ...
            '%d = frame 1). Mid-session drops cannot be located without LED. Set ' ...
            '''CamAlign'' or ''CamOffsetFrames'' if wrong.'], Nc, nFrames, o.CamAlign, 1+m0);
    end
end

% ---- assign pulses; enforce one pulse per frame, increasing --------------
pj = (1:nFrames)' + m;
valid = pj >= 1 & pj <= Nc;
lastJ = -inf;
for k = 1:nFrames                                   % drop duplicate/backward
    if valid(k)
        if pj(k) <= lastJ, valid(k) = false; else, lastJ = pj(k); end
    end
end
pj(~valid) = NaN;
C.pulseIdx = pj;
C.matched  = valid;
C.nMatched = sum(valid);
C.matchedFrac = C.nMatched / nFrames;
if C.nMatched < 2, C.msg = 'fewer than 2 frames matched to camera pulses'; return; end

t = nan(nFrames,1);
t(valid) = ct(pj(valid)) + o.CamLatencyS;
kv = find(valid);
pp = polyfit(vt_all(kv), t(kv), 1);
C.a = pp(1);  C.b = pp(2);
C.residualStd = std(t(kv) - polyval(pp, vt_all(kv)));
% frames without their own pulse: interpolate inside, extrapolate outside
inside = ~valid & (1:nFrames)' > kv(1) & (1:nFrames)' < kv(end);
t(inside) = interp1(vt_all(kv), t(kv), vt_all(inside), 'linear');
outside = ~valid & ~inside;
t(outside) = polyval(pp, vt_all(outside));
C.frameEphysTime = t;
C.nInterpolated  = sum(inside);
C.nExtrapolated  = sum(outside);

if any(diff(t) <= 0)
    C.msg = 'camera frame times not strictly increasing (pairing failed)';
    return;
end
C.ok = true;
end

% ---------------------------------------------------------------------------
function [lag, r] = rate_lag_search(vt, et, ttlDurS, o)
% Grid search over clock-rate ratio r (ephys_t ~ r*video_t + lag): for each r,
% cross-correlate binned edge trains and keep the (r, lag) with the highest
% peak. Coarse pass (0.1 s bins, wide r range), then fine pass (1-frame bins).
dur = max(vt(end), 1);
span = o.MaxRateErrPpm * 1e-6;
rc = 1;  lag = 0;
for dt = [0.1, 1/o.FsVid]
    step = dt / (2*dur);                            % drift over record < bin/2
    rs = rc + (-span : step : span);
    if isempty(rs), rs = rc; end
    tEnd = max([vt*max(rs); et; ttlDurS]) + dt;
    edges = 0 : dt : tEnd;
    he = histcounts(et, edges);  he = he - mean(he);
    best = -inf;
    for r = rs
        hv = histcounts(vt*r, edges);  hv = hv - mean(hv);
        if isempty(o.MaxLagS), [c,lg] = xcorr(he, hv);
        else,                  [c,lg] = xcorr(he, hv, round(o.MaxLagS/dt)); end
        [cm, k] = max(c);
        if cm > best, best = cm; rc_new = r; lag = lg(k)*dt; end
    end
    rc = rc_new;  span = 2*step;                    % refine around best
end
r = rc;
end

function [m, C] = offsets_from_led(L, ct, C, vt_all, o)
% Each LED edge says "frame k is the first frame to see an LED onset at ephys
% time e". With the pulse marking exposure START, frame k's pulse lies within
% about one period after e (precisely: e - ct(pulse) in [cT - T, cT), c in
% (0,1], set by exposure length and LED threshold). With J(e) = fractional
% pulse index at time e and q = J(e) - k:  m = ceil(q - c).  c is unknown but
% constant, so we choose the c that makes m most consistent across edges.
nFrames = numel(vt_all);
Nc = numel(ct);
k = L.matchFrame(:);  e = L.matchEphys(:);
inR = e > ct(1) - 2*C.period & e < ct(end) + 2*C.period;
k = k(inR); e = e(inR);
if numel(k) < 3
    m = zeros(nFrames,1); C.mSource = 'assumed 0 (LED edges outside camera pulses)';
    return;
end
J = interp1(ct, (1:Nc)', e, 'linear', 'extrap');
q = J - k;

if strcmpi(o.CamPulseAt, 'end'), cs = linspace(-1, 0, 201); cs = cs(2:end);
else,                             cs = linspace( 0, 1, 201); cs = cs(2:end); end
nTrans = zeros(size(cs));
for i = 1:numel(cs)
    mi = ceil(q - cs(i) - 1e-9);
    nTrans(i) = sum(diff(mi) ~= 0);
end
best = find(nTrans == min(nTrans));
% centre of the longest run of minimal-transition c values
runs = [0; find(diff(best(:)) > 1); numel(best)];
[~, r] = max(diff(runs));
cBest = cs(best(round((runs(r)+1 + runs(r+1))/2)));
mRaw = ceil(q - cBest - 1e-9);
mS = round(movmedian(mRaw, 5));                     % suppress boundary flips

% phase spread check: if LED onsets all share one phase relative to the
% frame clock, pairing is ambiguous by one frame
ph = 2*pi*(q - floor(q));
R = abs(mean(exp(1i*ph)));
if R > 0.9
    warning(['LED onsets have nearly constant phase relative to camera frames ' ...
        '(R=%.2f); the camera pulse<->frame pairing may be off by one frame. ' ...
        'Check, or set ''CamOffsetFrames''.'], R);
end
C.anchorFrame = k; C.anchorTime = e; C.anchorMraw = mRaw; C.anchorM = mS;
C.cCut = cBest; C.phaseR = R;
C.mSource = 'LED anchors';

% expand anchor offsets to every frame, locating each change in m
m = zeros(nFrames,1);
m(1:k(1)) = mS(1);
m(k(end):end) = mS(end);
C.breaks = zeros(0,3);                              % [frame, deltaM, located?]
for i = 1:numel(k)-1
    k0 = k(i); k1 = k(i+1);
    if mS(i) == mS(i+1), m(k0:k1) = mS(i); continue; end
    dM = mS(i+1) - mS(i);
    located = false;  kb = round((k0 + k1)/2);       % default: midpoint
    if dM < 0                                        % missing pulse(s)
        j0 = max(1, k0 + mS(i));  j1 = min(Nc, k1 + mS(i+1));
        if j1 > j0
            [~, jj] = max(diff(ct(j0:j1)));
            kb = min(max(j0 + jj - mS(i), k0+1), k1);   % first frame after gap
            located = true;
        end
    elseif ~isempty(o.FrameTimes)                    % dropped video frame(s)
        [~, jj] = max(diff(vt_all(k0:k1)));
        kb = k0 + jj;  located = true;
    end
    m(k0:kb-1) = mS(i);  m(kb:k1) = mS(i+1);
    if ~located, C.uncertain(k0:k1) = true; end
    C.breaks(end+1,:) = [kb, dM, located];
end
end

% ===========================================================================
%  COMPARISON + CHOICE
% ===========================================================================
function cmp = compare_methods(L, C, T, o)
cmp = struct();
cmp.T = T;
haveL = isfield(L,'ok') && L.ok;
haveC = isfield(C,'ok') && C.ok;

% (i) frame-by-frame agreement
if haveL && haveC
    use = C.matched;
    d = C.frameEphysTime(use) - L.frameEphysTime(use);
    cmp.camMinusLedMedianS = median(d);
    dev = nan(size(C.matched));  dev(use) = d - median(d);
    cmp.dev = dev;
    cmp.devStdS   = std(dev(use));
    cmp.devMaxS   = max(abs(dev(use)));
    cmp.nDisagree = sum(abs(dev(use)) > T/2);       % frames off by >= 1/2 frame
    % trend: does the difference drift (residual clock-rate error in LED fit)?
    kk = find(use);
    pd = polyfit(L.frameEphysTime(kk), d, 1);
    cmp.devDriftPpm = pd(1)*1e6;
end

% (ii) LED-edge bracketing test
tol = 0.6*T;
if haveL
    e = L.matchEphys;  k = L.matchFrame;
    dL = e - L.frameEphysTime(k);
    cmp.led.edgeResid = dL - median(dL);
    cmp.led.violFrac  = mean(abs(cmp.led.edgeResid) > tol);
    cmp.led.spreadS   = prctile(dL,97.5) - prctile(dL,2.5);
    if haveC
        dC = e - C.frameEphysTime(k);
        cmp.cam.edgeResid = dC - median(dC);
        cmp.cam.violFrac  = mean(abs(cmp.cam.edgeResid) > tol);
        cmp.cam.spreadS   = prctile(dC,97.5) - prctile(dC,2.5);
        cmp.cam.ledToPulseMedianS = median(dC);     % LED onset vs frame pulse
    end
end
end

function [method, reason] = choose_method(L, C, cmp, o)
haveL = isfield(L,'ok') && L.ok;
haveC = isfield(C,'ok') && C.ok;
camGood = haveC && C.matchedFrac >= o.CamMinMatchFrac;
if camGood && isfield(cmp,'cam')
    camGood = cmp.cam.violFrac <= 0.05;
end
if camGood && haveL && isfield(cmp,'cam')
    if cmp.cam.violFrac <= cmp.led.violFrac + 0.01
        method = 'camera';
        reason = sprintf(['camera pulses matched %.1f%% of frames; LED-edge ' ...
            'bracketing violations camera %.2f%% vs LED fit %.2f%%'], ...
            100*C.matchedFrac, 100*cmp.cam.violFrac, 100*cmp.led.violFrac);
    else
        method = 'led';
        reason = sprintf(['LED fit brackets LED edges better (%.2f%% vs camera ' ...
            '%.2f%% violations) - camera pairing suspect'], ...
            100*cmp.led.violFrac, 100*cmp.cam.violFrac);
    end
elseif camGood
    method = 'camera';
    if strcmp(L.msg,'not provided'), reason = 'camera sync only (no LED sync provided)';
    else, reason = ['camera mapping valid; LED method failed: ' L.msg]; end
elseif haveL
    method = 'led';
    if haveC
        reason = sprintf(['camera mapping failed validity checks (matched %.1f%% ' ...
            'of frames, min %.0f%%%s)'], 100*C.matchedFrac, 100*o.CamMinMatchFrac, ...
            ternary(isfield(cmp,'cam'), sprintf('; %.2f%% bracketing violations', ...
            100*getsub(cmp,'cam','violFrac')), ''));
    else
        if strcmp(C.msg,'not provided'), reason = 'LED sync only (no camera TTL provided)';
        else, reason = ['camera mapping unavailable: ' C.msg]; end
    end
elseif haveC
    method = 'camera';
    reason = sprintf(['camera only (LED: %s); %.1f%% of frames have their own pulse - ' ...
        'NOT cross-checked'], L.msg, 100*C.matchedFrac);
else
    error('Both methods failed. LED: %s | camera: %s', L.msg, C.msg);
end
end

% ===========================================================================
%  SHARED OUTPUT CONSTRUCTION (identical for both methods)
% ===========================================================================
function M = build_mapping(frameEphysTime, vt_all, Nephys, o)
nFrames = numel(frameEphysTime);
frameEphysSample = round(frameEphysTime * o.FsTtl) + 1;
hiN = Nephys; if isempty(hiN), hiN = max(frameEphysSample); end
frameInRecording = frameEphysSample >= 1 & frameEphysSample <= hiN;
M.nBefore = sum(frameEphysSample < 1);
M.nAfter  = sum(frameEphysSample > hiN);

frameIdx = (1:nFrames)';
M.ephysTimeToFrame = @(t) interp1(frameEphysTime, frameIdx, t, 'linear','extrap');

if ~isempty(Nephys)
    if isempty(o.MaxSampleGapS), gapTol = 1/o.FsVid; else, gapTol = o.MaxSampleGapS; end
    mids  = (frameEphysSample(1:end-1) + frameEphysSample(2:end)) / 2;
    edges = [-inf; mids(:); inf];
    ephysSampleToFrame = nan(Nephys, 1);
    chunk = 5e6;
    for s0 = 1:chunk:Nephys
        s1  = min(Nephys, s0+chunk-1);
        nn  = (s0:s1)';
        f   = discretize(nn, edges);
        far = abs((nn-1)/o.FsTtl - frameEphysTime(f)) > gapTol;
        f(far) = NaN;
        ephysSampleToFrame(s0:s1) = f;
    end
else
    ephysSampleToFrame = [];
    warning(['Ephys length unknown (edge inputs and no ''NEphys''); ' ...
        'per-sample frame vector not built. Pass ''NEphys'',numel(ephys_signal).']);
end
M.ephysSampleToFrame = ephysSampleToFrame;
M.frameEphysSample = frameEphysSample;
M.frameInRecording = frameInRecording;
M.frameTable = table(frameIdx, vt_all, frameEphysTime, frameEphysSample, frameInRecording, ...
    'VariableNames', {'frame','videoTime_s','ephysTime_s','ephysSample','inRecording'});
end

% ===========================================================================
%  REPORT + PLOTS
% ===========================================================================
function print_report(L, C, cmp, method, reason, M, a, bb, T, o)
fprintf('\n=== LED sync ===\n');
if L.ok
    fprintf('LED polarity       : %s  [%s]\n', L.polarityName, L.polarityHow);
    fprintf('matched edges      : %d of %d video / %d ephys\n', L.nMatched, numel(L.vt), numel(L.et));
    fprintf('clock ratio (a)    : %.7f  (%+.1f ppm drift)\n', L.a, (L.a-1)*1e6);
    if isempty(o.FrameTimes)
        fprintf('effective frame rate on ephys clock: %.4f Hz (FsVid = %g)\n', o.FsVid/L.a, o.FsVid);
    end
    fprintf('offset (b)         : %.4f s\n', L.b);
    fprintf('residual std       : %.4f s   (quantization floor ~%.4f s)\n', ...
        L.residualStd, T/sqrt(12));
elseif strcmp(L.msg, 'not provided')
    fprintf('not provided\n');
else
    fprintf('FAILED: %s\n', L.msg);
end
fprintf('\n=== camera-TTL sync ===\n');
if isfield(C,'nPulses')
    fprintf('pulses             : %d (glitches removed: %d) for %d frames\n', ...
        C.nPulses, C.nGlitch, numel(C.pulseIdx));
    fprintf('pulse period       : %.5f s (%.3f Hz), IPI jitter std %.3f ms\n', ...
        C.period, 1/C.period, 1e3*C.ipiJitterStd);
    fprintf('long gaps (>1.5T)  : %d (missing pulses)\n', C.nLongIPI);
    fprintf('pulse/frame pairing: %s', C.mSource);
    if ~isempty(C.anchorM)
        u = unique(C.anchorM);
        fprintf(' -> offset(s) m = %s', mat2str(u(:)'));
    end
    fprintf('\n');
    if isfield(C,'breaks') && ~isempty(C.breaks)
        for i = 1:size(C.breaks,1)
            fprintf('  offset change %+d near frame %d%s\n', C.breaks(i,2), C.breaks(i,1), ...
                ternary(C.breaks(i,3), '', ' (location approximate; frames flagged in A.cam.uncertain)'));
        end
    end
end
if C.ok
    fprintf('frames w/ own pulse: %d of %d (%.2f%%); interpolated %d, extrapolated %d\n', ...
        C.nMatched, numel(C.pulseIdx), 100*C.matchedFrac, C.nInterpolated, C.nExtrapolated);
    fprintf('line fit (ref only): a = %.7f (%+.1f ppm), b = %.4f s, jitter about line %.3f ms\n', ...
        C.a, (C.a-1)*1e6, C.b, 1e3*C.residualStd);
elseif strcmp(C.msg, 'not provided')
    fprintf('not provided\n');
else
    fprintf('FAILED/unused: %s\n', C.msg);
end

fprintf('\n=== comparison ===\n');
if isfield(cmp,'devStdS')
    fprintf('camera - LED, median   : %+.2f ms (constant; reflects exposure/LED-threshold timing)\n', ...
        1e3*cmp.camMinusLedMedianS);
    fprintf('camera - LED, per-frame: std %.2f ms, max %.2f ms, %d frames differ by > T/2\n', ...
        1e3*cmp.devStdS, 1e3*cmp.devMaxS, cmp.nDisagree);
    fprintf('                         relative drift %+.2f ppm\n', cmp.devDriftPpm);
end
if isfield(cmp,'led')
    fprintf('LED-edge bracketing    : LED fit   %.2f%% violations, 95%% spread %.1f ms\n', ...
        100*cmp.led.violFrac, 1e3*cmp.led.spreadS);
end
if isfield(cmp,'cam')
    fprintf('                         camera    %.2f%% violations, 95%% spread %.1f ms\n', ...
        100*cmp.cam.violFrac, 1e3*cmp.cam.spreadS);
    fprintf('                         (ideal: 0%%, spread <= one frame = %.1f ms)\n', 1e3*T);
end
fprintf('\n>>> USING: %s  (%s)\n', upper(method), reason);
fprintf('    ephys_t ~ %.7f * video_t + %.4f s\n', a, bb);
if M.nBefore > 0
    fprintf('    %d frames precede the ephys start (inRecording=false).\n', M.nBefore);
end
if M.nAfter > 0
    fprintf('    %d frames fall past the ephys end (inRecording=false).\n', M.nAfter);
end
fprintf('\n');
end

function make_plots(x, vt_all, L, C, cmp, A, ledTtl, tie, T, o)
nFrames = numel(vt_all);
if L.ok, x = L.xp; end                              % LED with polarity applied
% ----- LED diagnostics -----
if L.ok
    figure('Name','LED sync diagnostics');
    seg = 1:min(nFrames, round(min(30, 12*L.pPulse)*o.FsVid));
    subplot(1,3,1);
    plot(vt_all(seg), x(seg), 'Color',[.6 .6 .6]); hold on;
    plot(vt_all(seg), L.loEnv(seg), 'b', vt_all(seg), L.hiEnv(seg), 'b');
    plot(vt_all(seg), (L.loT(seg)+L.hiT(seg))/2, 'r--');
    ee = L.vEdgeIdx(ismember(L.vEdgeIdx, seg));
    plot(vt_all(ee), x(ee), 'r.', 'MarkerSize', 10);
    xlabel('video time (s)'); title('LED + tracked threshold');
    subplot(1,3,2);
    plot(L.matchVideo, L.matchEphys, '.'); hold on;
    plot(L.matchVideo, polyval(L.pp, L.matchVideo), 'r');
    xlabel('video-clock edge (s)'); ylabel('ephys-clock edge (s)');
    title(sprintf('LED edge fit (%d pts)', L.nMatched));
    subplot(1,3,3);
    histogram(L.resid*1e3, 40); xlabel('residual (ms)'); title('LED fit residuals');
end

% ----- comparison -----
if L.ok && C.ok
    figure('Name','LED vs camera sync');
    subplot(2,2,1);
    plot(L.frameEphysTime, 1e3*cmp.dev, 'k.', 'MarkerSize', 3); hold on;
    yline(1e3*T/2, 'r--'); yline(-1e3*T/2, 'r--');
    xlabel('ephys time (s)'); ylabel('ms');
    title('camera - LED mapping (median removed)');

    subplot(2,2,2);
    bw = 2;  ed = -1.5e3*T : bw : 1.5e3*T;
    histogram(1e3*cmp.led.edgeResid, ed, 'FaceColor',[.85 .33 .1], 'FaceAlpha',.5); hold on;
    histogram(1e3*cmp.cam.edgeResid, ed, 'FaceColor',[0 .45 .74], 'FaceAlpha',.5);
    xline(-600*T, 'k:'); xline(600*T, 'k:');
    xlabel('LED-TTL edge - mapped frame time (ms, centred)');
    legend('LED fit','camera','Location','best');
    title('LED-edge bracketing (inside dotted = OK)');

    subplot(2,2,3);
    histogram(1e3*C.ipi, 100); set(gca,'YScale','log');
    xlabel('camera inter-pulse interval (ms)'); title('camera pulse train');

    subplot(2,2,4);
    if ~isempty(C.anchorM)
        plot(C.anchorTime, C.anchorMraw, '.', 'Color',[.7 .7 .7]); hold on;
        stairs(C.anchorTime, C.anchorM, 'b', 'LineWidth', 1.2);
        xlabel('ephys time (s)'); ylabel('pulse index - frame index');
        title('camera pulse/frame offset at LED edges');
    else
        text(.1,.5,sprintf('offset source: %s', C.mSource)); axis off;
    end
end

% ----- camera only -----
if C.ok && ~L.ok
    figure('Name','camera sync');
    subplot(1,2,1);
    histogram(1e3*C.ipi, 100); set(gca,'YScale','log');
    xlabel('camera inter-pulse interval (ms)'); title('camera pulse train');
    subplot(1,2,2);
    kv = find(C.matched);
    plot(vt_all(kv), 1e3*(C.frameEphysTime(kv) - polyval([C.a C.b], vt_all(kv))), 'k.', 'MarkerSize', 3);
    xlabel('video time (s)'); ylabel('ms'); title('frame times about linear fit');
end

% ----- aligned overlay with the chosen mapping -----
if L.ok
    figure('Name', sprintf('aligned signals (%s mapping)', A.method));
    ledNorm = min(max((x - L.loEnv)./max(L.span,eps), 0), 1);
    t = A.frameEphysTime;
    w0 = max(0, L.matchEphys(1) - L.pPulse);
    w1 = w0 + min(max(10*L.pPulse, 2), 15);
    hold on;
    fm = t >= w0 & t <= w1;
    stairs(t(fm), ledNorm(fm), 'Color',[.85 .33 .1], 'LineWidth',1.2);
    bt = L.ttlBinary;
    if ~isempty(bt)
        s0 = max(1, round(w0*o.FsTtl)+1); s1 = min(numel(bt), round(w1*o.FsTtl)+1);
        tt = ((s0:s1)-1)/o.FsTtl;  ds = max(1, round(numel(tt)/50000));
        stairs(tt(1:ds:end), bt(s0:ds:s1), 'Color',[0 .45 .74], 'LineWidth',1.2);
    end
    if C.ok
        cz = C.pulseTime(C.pulseTime >= w0 & C.pulseTime <= w1);
        plot([cz cz]', repmat([-0.08; -0.02], 1, numel(cz)), 'Color',[.3 .3 .3]);
    end
    plot(t(fm), ledNorm(fm), 'k.', 'MarkerSize', 8);
    xlabel('ephys-clock time (s)'); ylabel('normalized'); ylim([-0.1 1.1]);
    title(sprintf('LED frames vs LED TTL (ticks = camera pulses), %s mapping', A.method));
end
end

% ===========================================================================
%  HELPERS
% ===========================================================================
function [et, bt, pPulse, wPulse, dnT] = ttl_edges(ttl, isEdges, Fs, which, riseFall, firstEdge, label)
% Edge times in seconds; sample n (1-based) <-> time (n-1)/Fs.
% riseFall=true: the edge list holds rising AND falling edges, alternating,
% starting with firstEdge ('rising' or 'falling').
if nargin < 5, riseFall = false; end
if nargin < 6, firstEdge = 'rising'; end
if nargin < 7, label = 'TTL'; end
if isEdges
    v = double(ttl(:));
    if any(v ~= round(v))
        warning(['%s edge input has non-integer values (%g ...); expected 1-based ' ...
            'SAMPLE INDICES. If these are seconds, convert: round(t*FsTtl)+1.'], label, v(1));
    end
    if riseFall
        if strcmpi(firstEdge, 'falling'), v = v(2:end); end
        up = v(1:2:end);  dn = v(2:2:end);
        n = numel(dn);
        hiS = median(dn - up(1:n)) / Fs;                % high time
        loS = median(up(2:end) - dn(1:numel(up)-1)) / Fs;   % low time
        fprintf(['%s: %d events -> %d pulses; HIGH %.2f ms, LOW %.2f ms ' ...
            '(if swapped, set ''FirstEdge'' to the other edge)\n'], ...
            label, numel(ttl), numel(up), 1e3*hiS, 1e3*loS);
        if mod(numel(v),2)
            fprintf('  (%s: odd event count - last pulse has no falling edge)\n', label);
        end
        if strcmpi(which, 'falling'), e = dn; else, e = up; end
        et = (e - 1) / Fs;  bt = [];  dnT = (dn - 1) / Fs;
        if strcmpi(which, 'falling'), dnT = (up - 1) / Fs; end
        pPulse = median(diff(up)) / Fs;  wPulse = hiS;
        return;
    end
    d = diff(v);
    if numel(d) > 10 && (median(d(1:2:end)) < 0.6*median(d(2:2:end)) || ...
                         median(d(2:2:end)) < 0.6*median(d(1:2:end)))
        warning(['%s edge intervals alternate short/long - the list may contain BOTH ' ...
            'rising and falling edges. If so, set ''EdgesIncludeFalling'',true.'], label);
    end
    et = (v - 1) / Fs;  bt = [];  dnT = [];
    pPulse = median(diff(et));  wPulse = NaN;
else
    v = double(ttl(:));
    if numel(v) > 2 && all(diff(v) > 0)
        error(['TTL input (%d values, %g .. %g) is strictly increasing - it looks ' ...
            'like a list of event times/sample numbers, not a 0/1 signal. Pass ' ...
            'rising-edge SAMPLE INDICES (1-based) with ''TtlIsEdges'',true and ' ...
            '''NEphys''.'], numel(v), v(1), v(end));
    end
    bt = v > 0.5;
    up = find(diff([0;bt]) == 1);                  % first high sample
    dn = find(diff([bt;0]) == -1) + 1;             % first low sample after
    if strcmpi(which, 'falling'), e = dn; else, e = up; end
    et = (e - 1) / Fs;
    dnT = (dn - 1) / Fs;  if strcmpi(which, 'falling'), dnT = (up - 1) / Fs; end
    pPulse = median(diff(up)) / Fs;
    wPulse = median(dn - up) / Fs;
end
end

function env = moving_prctile(x, pct, W)
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

function v = as_vector(v, name)
% Table/timetable with one variable -> that column; otherwise demand a vector.
if isempty(v), return; end
if istable(v) || istimetable(v)
    names = v.Properties.VariableNames;
    if numel(names) ~= 1
        error(['%s is a table with %d columns (%s). Pass the single column ' ...
            'you want, e.g. T.%s'], name, numel(names), strjoin(names, ', '), names{1});
    end
    v = v.(names{1});
end
if iscell(v), error('%s is a cell array; pass a numeric/logical vector.', name); end
if ~isvector(v)
    error('%s must be a vector; got a %s array.', name, mat2str(size(v)));
end
end

function v = getf(s, f)
if isfield(s, f), v = s.(f); else, v = []; end
end

function v = getsub(s, f1, f2)
v = NaN; if isfield(s, f1) && isfield(s.(f1), f2), v = s.(f1).(f2); end
end

function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end
