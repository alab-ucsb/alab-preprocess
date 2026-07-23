function [] = syncClocks(true_ttl, noisy_ttl, fs_true, fs_noisy)

%% ---- your data -----------------------------------------------------------
% true_ttl, noisy_ttl : the two readouts (vectors)
% fs_true, fs_noisy    : their sample rates in Hz (each on its own clock)

%% ---- 1. clean + binarize -------------------------------------------------
bt = binarize(true_ttl);
bn = binarize(noisy_ttl);

%% ---- 2. resample both onto one common clock ------------------------------
fs = max(fs_true, fs_noisy);                     % upsample to the faster clock

tt = (0:numel(bt)-1)/fs_true;   qt = 0:1/fs:tt(end);
tn = (0:numel(bn)-1)/fs_noisy;  qn = 0:1/fs:tn(end);

rt = interp1(tt, double(bt), qt, 'previous', 0); % 'previous' preserves square edges
rn = interp1(tn, double(bn), qn, 'previous', 0);

%% ---- 3. cross-correlate --------------------------------------------------
[c, lags] = xcorr(rn - mean(rn), rt - mean(rt)); % mean-subtract so duty cycle
[~, k] = max(c);                                 %   doesn't dominate
lag_s = lags(k)/fs;                              % >0  => noisy lags true

fprintf('Best lag: %.4f s (noisy turns on %.4f s after true)\n', lag_s, lag_s);

%% ---- 4. verify by overlaying (always do this) ---------------------------
figure;
plot(qt, rt, 'LineWidth', 1.5); hold on;
plot(qn - lag_s, rn, 'LineWidth', 1.5);          % shift noisy back by the lag
legend('true','noisy (aligned)'); xlabel('true-clock time (s)');

function b = binarize(v)
    v = double(v(:));
    b = v > (max(v)+min(v))/2;                    % midpoint threshold
end

end