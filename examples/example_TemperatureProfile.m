%% Clean up

clear all
clc
close all

addALLthepaths

%% Set up problem

% Basic object
PD = ProblemDefinition;

% Define grid
nBins = 500;
gridL = linspace(0,5e2,nBins+1);
meanL = (gridL(1:end-1)+gridL(2:end))/2;
PD.init_dist.y = meanL;
PD.init_dist.boundaries = gridL;
PD.init_conc = 6.5e-3;

% Define growth rate
PD.growthrate = @(S,T,y) 1e-1*(S-1)*ones(size(y));
PD.solubility = @(T) (0.0056*(T-273).^2+0.0436.*(T-273)+3.7646)/1000;

% Define operating conditions
PD.init_seed = 1;
PD.init_massmedium = 2000; % mass of solvent in the beginning
PD.sol_time = [0 60*60];
PD.Tprofile = [0 5*60 10*60 60*60;
    290 285 285 280];

%define a simple gaussian as initial distribution
mu = 1e2;
sigma = 0.3*mu;
gauss = @(x) exp(-((x-mu).^2/(2*sigma^2)));

PD.init_dist.F = gauss(meanL);


% Set solver method to moving pivot
% PD.sol_method = 'movingpivot';
PD.sol_method = 'centraldifference';
PD = ProfileManager(PD);



%% Plot results
plot(PD,'detailed_results');