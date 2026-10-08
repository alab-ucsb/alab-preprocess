% List of binary files to concatenate
clear all; clc


[files, path] = uigetfile('*.dat', 'Select files to concatenate IN REVERSE ORDER', 'MultiSelect', 'on');
if isequal(files, 0)
    disp('No files selected.');
else
    if iscell(files) % Multiple files selected
        numFiles = numel(files);
        disp(['Number of files selected: ', num2str(numFiles)]);
        disp('Selected files:');
        for i = 1:numFiles
            disp(fullfile(path, files{i}));
        end
    else % Single file selected
        disp('One file selected:');
        disp(fullfile(path, files));
    end
end

% Output file name
outputFile = 'concatenated_data.dat';

% Open the output file for writing
fidOut = fopen(outputFile, 'w');

% Loop through each file and append its data to the output file
for i = 1:length(files)
    % Open the current file for reading
    fidIn = fopen(fullfile(path,files{i}), 'r');
    
    % Read the data from the current file
    data = fread(fidIn, inf, 'int16'); % Adjust data type if necessary
    
    % Write the data to the output file
    fwrite(fidOut, data, 'int16'); % Ensure the data type matches your recordings
    
    % Close the current input file
    fclose(fidIn);
end

% Close the output file
fclose(fidOut);
