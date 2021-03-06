%% Main method movingpivot

% Copyright 2015-2016 David Ochsenbein
% Copyright 2012-2014 David Ochsenbein, Martin Iggland
% 
% This file is part of CAT.
% 
% CAT is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation version 3 of the License.
% 
% CAT is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
% 
% You should have received a copy of the GNU General Public License
% along with this program.  If not, see <http://www.gnu.org/licenses/>.


function [mbflag] = solver_movingpivot(O)

% movingpivot
%
% Solves the PBE according to the Moving Pivot method (cf. e.g.  Kumar, S.; Ramkrishna, D. Chemical Engineering Science 1997, 52, 4659�4679.)
% Needs to solve ODE's for number of particles (N), pivot length (y), boundaries (boundaries) and concentration,
% i.e. the number of ODE's to be solved is 3*ngrid-2+1 and has an event listener.
% In general, the moving pivot method yields the most accurate results but
% has the highest computational cost. The method is particularly well
% suited for problems with discontinuous distributions and geometric grids.
% If you are unhappy with the result consider the following options:
% - Increase the number of grid points
% - Decrease reltol {1e-6} and abstol {1e-6} [sol_options]
% - Reduce dL (criterion for bin addition) {10} [sol_options]
% - Use another method

if ~isempty(O.sol_options) && ~isempty(find(strcmpi(O.sol_options,'dL'),1))
    dL = O.sol_options(find(strcmpi(O.sol_options,'dL'),1)+1);
elseif strcmp(func2str(O.nucleationrate),'@(S,T,m)0') || strcmp(func2str(O.nucleationrate),'@(S,T)0')
    dL = inf;
else
    dL = 10; % critical bin size for event listener
end

if ~isempty(O.sol_options) && ~isempty(find(strcmpi(O.sol_options,'massbalTol'),1))
    massbalTol = O.sol_options(find(strcmpi(O.sol_options,'massbalTol'),1)+1);
else
    massbalTol = 0.05; % massbalance error tolerance
end

X0 = [O.init_dist.F.*diff(O.init_dist.boundaries) ...
    O.init_dist.y O.init_dist.boundaries O.init_conc];
tstart = O.sol_time(1); % local start time
tend = O.sol_time(end); % overall end time

% if nucleation is present, bins are addded when the first bin
% becomes too big, if dissolution is present, remove bins when
% necessary
options = O.sol_options;
if isempty(O.sol_options) || isempty(O.sol_options{1})
    options = odeset('Events',@(t,x) EventBin(t,x,dL,massbalTol,O),'reltol',1e-6,...
        'OutputFcn',@solveroutput_wrapper);
else
    options = odeset('Events',@(t,x) EventBin(t,x,dL,massbalTol,O),...
        'OutputFcn',@solveroutput_wrapper);
end


SolutionTimes = []; SolutionConc = [];
s=0;

% Call solveroutput function - initialise
O.solveroutput([tstart tend],[],'init');

while tstart<tend
    ts = O.sol_time(O.sol_time > tstart & O.sol_time < tend);
    
    % Solve until the next event where the nucleation bin becomes to big (as defined by dL)
    solvefun = @(t,x) movingpivot_ode(t,x,O);
    [TIME,X_out,TE] = ode15s(solvefun, [tstart;ts;tend]',X0, options);
    
    X_out(X_out<0) = 0;
    
    nBins = (size(X_out,2)-2)/3;
    
    if X_out(end,2*nBins+1)>0
        X0 = addBin(X_out(end,:)');
    elseif X_out(end,nBins+1)<=0
        X0 = removeBin(X_out(end,:)');
    end
    
    F = X_out(:,1:nBins)./diff(X_out(:,2*nBins+1:3*nBins+1),1,2); F(isnan(F)) = 0;
    
    SolutionTimes = [SolutionTimes;TIME(:)]; %#ok<AGROW>
    SolutionConc = [SolutionConc;X_out(:,end)]; %#ok<AGROW>
    for i = 1:length(TIME)
        SolutionDists(s+i) = Distribution( X_out(i,nBins+1:2*nBins),...
            F(i,:),...
            X_out(i,2*nBins+1:3*nBins+1) ); %#ok<AGROW>
    end
    s = s+length(TIME);
    tstart = TIME(end);
    
    if ~isempty(TE)
        mbflag = 1;
    else
        mbflag = 0;
    end
    
end %while

% Call solveroutput function - final
O.solveroutput([],[],'done');

O.calc_time = SolutionTimes;
O.calc_dist = SolutionDists;
O.calc_conc = SolutionConc;

    function status = solveroutput_wrapper(t,~,flag)
        
        % This function is used as outputfcn in the ODEs - the init and
        % final steps are called manually before and after solution, to
        % avoid calling them many times as the solver is restarted
        
        if isempty(flag)
            % Only call solveroutput via ODE for intermediate values
            O.solveroutput(t,[],[]);
        end % if
        
        status = 0;
        
    end % function

end % function movingpivot

function [dxdt] = movingpivot_ode(t, x, O)
% [dxdt] = movingpivot(t, x, O) Moving Pivot method for Nucleation and Growth
%
% ODE function

nBins = (length(x)-2)/3; % number of bins

% Current concentration
c = x(end); %

% Current solvent + antisolvent mass
m = O.init_massmedium+(O.ASprofile(t)-O.ASprofile(0));

% Current mass fraction antisolvent
xm = O.ASprofile(t)/m;

% Current temperature
T = O.Tprofile(t);

% Current supersaturation
S = c/evalanonfunc(O.solubility,T,xm);

% Current mass flow rate antisolvent (evaluated using simplistic FD)
Q = (O.ASprofile(t+1e-6)-O.ASprofile(t))/1e-6;
if isnan(Q)
    Q = (O.ASprofile(t)-O.ASprofile(t-1e-6))/1e-6;
end


N = x(1:nBins); N = N(:); %particle numbers
y = x(nBins+1:2*nBins); %pivot sizes
boundaries = x(2*nBins+1:3*nBins+1); %boundaries
Dy = diff(boundaries);Dy = Dy(:);

if strcmp(func2str(O.nucleationrate),'@(S,T,m)0') || strcmp(func2str(O.nucleationrate),'@(S,T)0')
    dist = [];
else
    dist = Distribution(y,N./Dy,boundaries);
end

J = evalanonfunc(O.nucleationrate, S, T, dist, t );

Gy = evalanonfunc(O.growthrate, S, T, y, t ); % growth rate for pivots
Gboundaries = evalanonfunc(O.growthrate, S, T, boundaries, t ); % growth rate for boundaries

Gboundaries(boundaries<0) = 0;

% Check size of Gy and Gboundaries
if isscalar(Gy)
    Gy = Gy*ones(size(y));
end % if
if isscalar(Gboundaries)
    Gboundaries = Gboundaries*ones(size(boundaries));
end % if

dNdt = [J; zeros(nBins-1,1)]-N(1:nBins)/m*Q; % change in number (per mass medium): nucleation - dilution
dcdt = -3*O.rhoc*O.kv*sum(y.^2.*Gy.*N)-c/m*Q-J*y(1)^3*O.kv*O.rhoc;

dxdt = [dNdt; Gy; Gboundaries; dcdt;];

end

%% Function addBin

function [xout] = addBin(xin)
% Adds a new bin to the distribution, so that we can continue integrating
% without producing too much of an error in the mass balance.

nBins = (length(xin)-2)/3; % number of bins in distribution

N = xin(1:nBins); %particle numbers
y = xin(nBins+1:2*nBins); % pivot sizes
boundaries = xin(2*nBins+1:3*nBins+1); %boundaries
c = xin(3*nBins+2); % concentration

%insert new, empty bin at beginning (we only support nucleation)
N = [0; N];
y = [0; y];
boundaries = [0; boundaries];

% assemble new x
xout = [N; y; boundaries; c;];
end

%% Function EventBin

function [value,isterminal,direction] = EventBin(t,x,dL,massbalTol,O)
% Event function
nBins = (length(x)-2)/3;

m = O.init_massmedium+(O.ASprofile(t)-O.ASprofile(0));

N = x(1:nBins); %particle numbers
y = x(nBins+1:2*nBins); % pivot sizes
boundaries = x(2*nBins+1:2*nBins+2);

value(1) = dL - boundaries(1); % Detect when first bin becomes too broad (value <= 0)
value(2) = y(1); % Detects when first pivot becomes smaller than zero
value(3) = massbalTol-abs(((O.init_conc*O.init_massmedium+moments(O.init_dist,3)*O.kv*O.rhoc*O.init_massmedium)-(x(end)*m+sum(N(:).*y(:).^3)*O.kv*O.rhoc*m))/(O.init_conc*O.init_massmedium+moments(O.init_dist,3)*O.kv*O.rhoc*O.init_massmedium)); % current massbalance error

value = value(:);
isterminal = ones(3,1);   % Stop the integration
direction = -ones(3,1);   % Negative direction only
end

%% Ffunction removeBin

function [xout] = removeBin(xin)
% Removes a bin from the distribution when necessary (dissolution)

nBins = (length(xin)-2)/3; % number of bins in distribution

N = xin(1:nBins); %particle numbers
y = xin(nBins+1:2*nBins); % pivot sizes
boundaries = xin(2*nBins+1:3*nBins+1); %boundaries
c = xin(3*nBins+2); % concentration

% remove first bin
N = N(2:end);
y = y(2:end);
boundaries = boundaries(2:end);

% assemble new x
xout = [N; y; boundaries; c;];
end

