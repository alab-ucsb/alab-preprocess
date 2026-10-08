function [t, dt, T] = loadFrameTimes(tsData, tsColumn)
% loadFrameTimes  Extract frame times in seconds, re-zeroed so the first
%                 frame is at t = 0.  Reads from a file you pick, or from a
%                 vector of timestamps you hand in directly.
%
%   [t, dt, T] = loadFrameTimes()                % prompt for a file
%   [t, dt, T] = loadFrameTimes(tsData)          % use timestamps passed in
%   [t, dt, T] = loadFrameTimes(tsData, tsColumn)
%   [t, dt, T] = loadFrameTimes([], tsColumn)    % prompt, custom column
%   [t, dt, T] = loadFrameTimes('Timestamp')     % prompt, custom column
%
%   tsData   : (optional) the frame timestamps to use, given as a datetime
%              vector, a string/char/cell vector of timestamp strings, or a
%              table.  If omitted or empty, a file dialog is shown instead.
%              A scalar column name or column index passed here is treated
%              as tsColumn, so old one-argument calls still work.
%   tsColumn : timestamp column name or index, used when reading from a file
%              or an input table.  Default: 'Timestamp'.
%
%   t  : column vector of elapsed seconds (t(1) == 0).
%   dt : the parsed datetime vector (absolute wall-clock times).
%   T  : the source table (built from tsData when a bare vector is given).

    % --- Sort out the arguments ----------------------------------------
    % Keep loadFrameTimes('Col') / loadFrameTimes(colIdx) meaning
    % "prompt, using this column", exactly as before.
    if nargin >= 1 && (ischar(tsData) ...
                       || (isstring(tsData) && isscalar(tsData)) ...
                       || (isnumeric(tsData) && isscalar(tsData)))
        if nargin < 2, tsColumn = tsData; end
        tsData = [];
    end
    if nargin < 2 || isempty(tsColumn), tsColumn = 'Timestamp'; end

    % --- Get the raw timestamps ----------------------------------------
    if nargin < 1 || isempty(tsData)
        % No timestamps supplied -> pick a file.
        [fileName, filePath] = uigetfile( ...
            {'*.csv;*.xlsx;*.xls;*.xlsm', 'CSV/Excel (*.csv,*.xlsx,*.xls,*.xlsm)'; ...
             '*.*', 'All files (*.*)'}, 'Select a timestamp file');
        if isequal(fileName, 0)
            error('loadFrameTimes:cancelled', 'No file selected.');
        end
        T   = readtable(fullfile(filePath, fileName), 'VariableNamingRule', 'preserve');
        raw = getColumn(T, tsColumn);
        srcName = fileName;

    elseif istable(tsData)
        % A table was handed in directly.
        T   = tsData;
        raw = getColumn(T, tsColumn);
        srcName = 'provided table';

    else
        % A bare vector of timestamps was handed in.
        raw = tsData;
        if ischar(tsColumn) || (isstring(tsColumn) && isscalar(tsColumn))
            colName = char(tsColumn);
        else
            colName = 'Timestamp';
        end
        T = table(raw(:), 'VariableNames', {colName});
        srcName = 'provided vector';
    end

    % --- Parse to datetime ---------------------------------------------
    if isdatetime(raw)
        dt = raw;                       % already datetime
    else
        s = string(raw);
        % Strip the trailing timezone offset (e.g. "-08:00"); it's constant
        % here and irrelevant to elapsed time, which sidesteps any
        % timezone-token fuss in the input format.
        s  = regexprep(s, '[+-]\d{2}:\d{2}$', '');
        dt = datetime(s, 'InputFormat', "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS");
    end

    % --- Re-zero to the first frame ------------------------------------
    dt = dt(:);                         % always a column, whatever came in
    t  = seconds(dt - dt(1));

    % --- Sanity report -------------------------------------------------
    fprintf('Source         : %s\n', srcName);
    fprintf('Frames         : %d\n', numel(t));
    fprintf('Starts at      : %.6g s   Ends at: %.6g s\n', t(1), t(end));
    fprintf('Median interval: %.6g s  (~%.2f fps)\n', ...
            median(diff(t)), 1/median(diff(t)));
end

% ---------------------------------------------------------------------
function raw = getColumn(T, tsColumn)
% Pull the timestamp column out of a table by name or index.
    if isnumeric(tsColumn)
        raw = T{:, tsColumn};
    else
        raw = T.(tsColumn);
    end
end