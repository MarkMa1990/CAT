function [O] = ProfileManager(O)

%% Solve
O.calc_dist = Distribution;
O.init_dist.mass = [O.init_seed O.kv O.rhoc O.init_massmedium];
sol_time = O.sol_time;
if ~isempty(O.tNodes)
    for i = 2:length(O.tNodes) % make sure you hit the different nodes of the non-smooth profiles
        
        O.sol_time = [O.tNodes(i-1) sol_time(sol_time>O.tNodes(i-1) & sol_time<O.tNodes(i)) O.tNodes(i)];  
        
        [a b c] = PBESolver(O);
        O.calc_time(end+1:end+length(a)) = a;
        O.calc_dist(end+1:end+length(b)) = b;    
        O.calc_conc(end+1:end+length(a)) = c; 

        O.init_dist = O.calc_dist(end);
        O.init_conc = O.calc_conc(end);

    end % for

        O.calc_dist = O.calc_dist(2:end);
        O.sol_time = sol_time;
        O.init_dist = O.calc_dist(1);
else    
    
    try
        
        [O.calc_time, O.calc_dist, O.calc_conc] = PBESolver(O);
    catch ME
        keyboard
        error('ProfileManager:tryconsttemp:PBESolverfail',...
            'PBESolver failed to integrate your problem.')
    end
end

O.init_conc = O.calc_conc(1);
O.init_dist = O.calc_dist(1);

if length(O.sol_time)>2
    [~,I] = intersect(O.calc_time,O.sol_time);
    O.calc_time = O.calc_time(I);
    O.calc_dist = O.calc_dist(I);
    O.calc_conc = O.calc_conc(I);
end

%% Check Mass balance
if any(O.massbal > 5)
   warning('ProfileManager:massbalcheck:largeerror',...
                    'Your mass balance error is unusually large (%4.2f%%). Check validity of equations and consider increasing the number of bins.',max(O.massbal)); 
end