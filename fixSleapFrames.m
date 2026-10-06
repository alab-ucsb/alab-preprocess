function [p2,d2] = fixSleapFrames(nf,ti,p,dlcind)
    p2 = nan(nf, size(p,2)); % create empty array that is correct length
    d2 = nan(nf, 1);
    p2(ti,:) = p;
    d2(ti,:) = dlcind;