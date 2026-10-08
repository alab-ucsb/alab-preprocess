function [temp,LEDind] = reconLEDTtlNeuralClock(LEDttl, nIndices, timeneu)

LEDind = LEDttl.sample_number;
LEDind = LEDind - nIndices(1);

temp = ones(length(nIndices),1);

for n = 1 : 2 : length(LEDind)-1
    clear cind
    cind = LEDind(n) : LEDind(n+1);
    temp(cind) = 0;
end
