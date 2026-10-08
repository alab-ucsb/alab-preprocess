function info = concatCont_v2(outFile, inFiles, nChan)
% CONCATCONT_V2  Concatenate Open Ephys continuous.dat files IN ORDER for
% Kilosort/Phy, streaming in chunks (low memory), with checks and a record of
% where each session starts and ends in the concatenated file.
%
% USAGE
%   concatCont_v2                      % GUI: pick output, then each session's
%                                      % continuous.dat ONE AT A TIME, in order
%   concatCont_v2(outFile, {f1,f2,f3}) % files given explicitly, in order
%   concatCont_v2(outFile, files, 75)  % channel count given explicitly
%   concatCont_v2([], [], 75)          % GUI picking, channel count given
%
% nChan is read from each recording's structure.oebin when not given (and all
% files must agree). If structure.oebin isn't next to the file (e.g. only
% continuous.dat was copied from the server), GUI mode asks for it; otherwise
% pass nChan. Keeping structure.oebin with the copy (29 KB) is recommended. Data are int16, channel-interleaved, so files are joined
% byte-for-byte; nothing is rescaled.
%
% OUTPUT (also saved next to outFile as <name>_info.mat and <name>_info.csv)
%   info.files            input files, in concatenation order
%   info.nChan            channels per sample
%   info.nSamples         samples per file
%   info.firstSample      1-based first sample of each file in the output
%   info.lastSample       1-based last sample
%   info.firstSample0     0-based first sample (= Kilosort spike_times units)
%   Spikes with Kilosort spike_times s (0-based) belong to session k when
%   info.firstSample0(k) <= s <= info.firstSample0(k)+info.nSamples(k)-1.

if nargin < 1 || isempty(outFile)
    [f, p] = uiputfile('*.dat', 'Save concatenated file as', 'concatenated_data.dat');
    if isequal(f, 0), disp('Cancelled.'); info = []; return; end
    outFile = fullfile(p, f);
end
pickedByGui = nargin < 2 || isempty(inFiles);
if pickedByGui
    inFiles = {};
    startDir = fileparts(outFile);
    while true
        [f, p] = uigetfile('*.dat', sprintf(['Select SESSION %d continuous.dat ' ...
            '(Cancel when done)'], numel(inFiles)+1), startDir);
        if isequal(f, 0), break; end
        inFiles{end+1} = fullfile(p, f); %#ok<AGROW>
        startDir = fileparts(fileparts(p));          % next session is usually nearby
    end
end
if ischar(inFiles) || isstring(inFiles), inFiles = cellstr(inFiles); end
nF = numel(inFiles);
if nF == 0, error('No input files.'); end

% ---- channel count ---------------------------------------------------------
if nargin < 3 || isempty(nChan)
    nc = nan(1, nF);
    for i = 1:nF, nc(i) = oebin_nchan(inFiles{i}); end
    if any(isnan(nc)) && pickedByGui && usejava('desktop')
        % no structure.oebin next to some files (e.g. continuous.dat copied
        % on its own): ask once, and apply to those files
        known = nc(~isnan(nc));
        if isempty(known), def = '75'; else, def = num2str(known(1)); end
        a = inputdlg(sprintf(['structure.oebin not found for %d of %d files.\n' ...
            'Number of channels in each continuous.dat:'], sum(isnan(nc)), nF), ...
            'Channel count', 1, {def});
        if isempty(a), disp('Cancelled.'); info = []; return; end
        nc(isnan(nc)) = str2double(a{1});
    end
    if any(isnan(nc))
        error(['Could not read the channel count from structure.oebin for:\n  %s\n' ...
            'Pass it explicitly: concatCont_v2(outFile, files, nChan)'], ...
            strjoin(inFiles(isnan(nc)), '\n  '));
    end
    if any(nc ~= nc(1))
        error('Channel counts differ between files: %s', mat2str(nc));
    end
    nChan = nc(1);
end

% ---- sizes / sanity --------------------------------------------------------
bytesPerSamp = 2 * nChan;
nBytes = zeros(nF,1);
for i = 1:nF
    d = dir(inFiles{i});
    if isempty(d), error('File not found: %s', inFiles{i}); end
    nBytes(i) = d.bytes;
    if mod(nBytes(i), bytesPerSamp) ~= 0
        error(['%s is %d bytes, not a whole number of %d-channel int16 samples. ' ...
            'Wrong channel count, or a truncated file.'], inFiles{i}, nBytes(i), nChan);
    end
end
nSamples = nBytes / bytesPerSamp;
firstSample = [1; 1 + cumsum(nSamples(1:end-1))];
lastSample  = firstSample + nSamples - 1;

% ---- confirm order ---------------------------------------------------------
fprintf('\nConcatenating %d files (%d channels) in THIS order:\n', nF, nChan);
for i = 1:nF
    fprintf('  %d. %s\n     %d samples (%.1f min at 30 kHz), output samples %d-%d\n', ...
        i, inFiles{i}, nSamples(i), nSamples(i)/30000/60, firstSample(i), lastSample(i));
end
fprintf('Output: %s (%.2f GB)\n', outFile, sum(nBytes)/1e9);
if usejava('desktop') && pickedByGui
    if ~strcmp(questdlg('Is this the correct session order?', 'Confirm order', ...
            'Yes', 'No', 'No'), 'Yes')
        disp('Cancelled.'); info = []; return;
    end
end
if exist(outFile, 'file')
    error('Output file already exists (not overwriting): %s', outFile);
end

% ---- stream copy -----------------------------------------------------------
chunkSamp = 30000 * 10;                              % 10 s of data per read
fo = fopen(outFile, 'w');
if fo < 0, error('Cannot open output file for writing: %s', outFile); end
cleanupOut = onCleanup(@() fclose_if_open(fo));
for i = 1:nF
    fi = fopen(inFiles{i}, 'r');
    if fi < 0, error('Cannot open %s', inFiles{i}); end
    nDone = 0;
    while true
        buf = fread(fi, chunkSamp * nChan, '*int16');
        if isempty(buf), break; end
        n = fwrite(fo, buf, 'int16');
        if n ~= numel(buf)
            fclose(fi);
            error('Write failed (disk full?) while copying %s.', inFiles{i});
        end
        nDone = nDone + numel(buf);
    end
    fclose(fi);
    if nDone ~= nBytes(i)/2
        error('Read %d int16 values from %s; expected %d.', nDone, inFiles{i}, nBytes(i)/2);
    end
    fprintf('  copied %d/%d\n', i, nF);
end
fclose(fo);

% ---- verify ----------------------------------------------------------------
d = dir(outFile);
if d.bytes ~= sum(nBytes)
    error('Output is %d bytes; expected %d.', d.bytes, sum(nBytes));
end
% spot-check the first and last 1000 samples of every segment against source
fo = fopen(outFile, 'r');
nChk = 1000 * nChan;
for i = 1:nF
    fi = fopen(inFiles{i}, 'r');
    for where = [0, max(0, nBytes(i) - 2*nChk)]
        fseek(fi, where, 'bof');
        a = fread(fi, nChk, '*int16');
        fseek(fo, (firstSample(i)-1)*bytesPerSamp + where, 'bof');
        b = fread(fo, numel(a), '*int16');
        if ~isequal(a, b)
            fclose(fi); fclose(fo);
            error('Verification failed: segment %d of the output does not match %s.', i, inFiles{i});
        end
    end
    fclose(fi);
end
fclose(fo);
fprintf('Verified: size matches and every segment boundary matches its source.\n');

% ---- record ----------------------------------------------------------------
info = struct('files', {inFiles(:)}, 'nChan', nChan, 'nSamples', nSamples, ...
    'firstSample', firstSample, 'lastSample', lastSample, ...
    'firstSample0', firstSample - 1, 'outFile', outFile, 'created', datestr(now));
[p, n] = fileparts(outFile);
save(fullfile(p, [n '_info.mat']), 'info');
fid = fopen(fullfile(p, [n '_info.csv']), 'w');
fprintf(fid, 'order,file,nSamples,firstSample1based,lastSample1based,firstSample0based\n');
for i = 1:nF
    fprintf(fid, '%d,"%s",%d,%d,%d,%d\n', i, inFiles{i}, nSamples(i), ...
        firstSample(i), lastSample(i), firstSample(i)-1);
end
fclose(fid);
fprintf('Session boundaries saved to %s_info.mat / .csv\n', fullfile(p, n));
end

% ===========================================================================
function n = oebin_nchan(datFile)
% continuous.dat lives in recordingX/continuous/<stream>/ ; structure.oebin in
% recordingX/. Return num_channels of the matching stream, or NaN.
n = NaN;
streamDir = fileparts(datFile);
[~, nm, ext] = fileparts(streamDir);  streamName = [nm ext];   % folder name has a dot
recDir = fileparts(fileparts(streamDir));
ob = fullfile(recDir, 'structure.oebin');
if ~exist(ob, 'file'), return; end
try
    s = jsondecode(fileread(ob));
    c = s.continuous;
    if ~iscell(c), c = num2cell(c); end
    for k = 1:numel(c)
        fn = strrep(strrep(c{k}.folder_name, '/', ''), '\', '');
        if strcmp(fn, streamName), n = double(c{k}.num_channels); return; end
    end
    if numel(c) == 1, n = double(c{1}.num_channels); end
catch
end
end

function fclose_if_open(fid)
try, fclose(fid); catch, end
end
