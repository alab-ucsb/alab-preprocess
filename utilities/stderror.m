function [ste]= stderror(vector)
vector(isinf(vector))=NaN;
n = length(vector);
ste = nanstd(vector)./sqrt(n-1);