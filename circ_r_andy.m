function r = circ_r_andy(alpha, w, d, dim)
% r = circ_r_andy(alpha, w, d, dim)
%   Computes maximum-normalized mean resultant vector length.
%
%   Input:
%     alpha  angular bin centers in radians
%     w      activity averaged over distance for each angular bin
%            Use NaN for angular bins with no observations.
%     [d     retained for compatibility; no bin-width correction is applied]
%     [dim   dimension along which to compute, default: first non-singleton]
%
%   Output:
%     r      Andy MRL:
%            abs(sum(w .* exp(1i*alpha))) / (n_valid * max(w))
%
%   Average the ratemap over distance before calling this function.
%   Silent or entirely unvisited cells return zero.
%   No mean-centering, Laplace smoothing, or bin-width correction.

if nargin < 4 || isempty(dim)
    dim = find(size(alpha) > 1, 1, 'first');
    if isempty(dim)
        dim = 1;
    end
end

if nargin < 2 || isempty(w)
    w = ones(size(alpha));
else
    if ~isequal(size(w), size(alpha))
        error('Input dimensions do not match');
    end
end

if nargin < 3 || isempty(d)
    d = 0;
end

if d ~= 0
    error('Andy MRL does not use a bin-width correction; set d = 0 or [].');
end

% exclude unvisited or invalid angular bins
valid = isfinite(w) & isfinite(alpha);

if any(w(valid) < 0)
    error('Activity weights must be nonnegative');
end

w(~valid) = 0;
alpha(~valid) = 0;

% compute weighted sum of cos and sin of angles
resultant = sum(w .* exp(1i * alpha), dim);

% normalize by maximum activity and number of valid angular bins
denominator = max(w, [], dim) .* sum(valid, dim);

r = zeros(size(denominator));
active = denominator > 0;
r(active) = abs(resultant(active)) ./ denominator(active);

end
