function [output] = hires(finput,PD)
%% n-dimensional High Resolution Flux limited PBE Solver
% This algorithm solves the PDE arising from the population balance
% equation in 1, 2 or 3 dimensions. The correct computation method is
% chosen depending on the shape of the finput. The finput structure 'finput'
% contains information on the experimental and numerical setup (including
% kinetic data, initial distribution and concentration, etc.). 
%
% This code is a modified version of the HRFL_ndim function I programmed
% for the controller.
%
% Dave Ochsenbein, 12.01.2011


%% Setup and Preparation
if exist('arrayDivision','file')==0 && exist('Phifinder','file')==0
    error('You lack some necessary functions...')
end

if ~isempty(PD.sol_options)
    phistr=find(strcmp('Phi',PD.sol_options));
        if ~isempty(phistr)
            finput.setup.Phi = PD.sol_options{phistr+1};
        end
else
    finput.setup.Phi='vanleer';
end

if isscalar(PD.sol_time);
    finput.exp.ttot  =   PD.sol_time;
elseif isvector(PD.sol_time)
    finput.exp.ttot  =   PD.sol_time(end);
    finput.exp.tline =   PD.sol_time;
end

% Information on the PSD
PSD     =   struct('xb',[],'Dx',[],'xp',[]);



size_tot        =   [];
% Grid stuff (pivot lengths, Delta x and include ghost points)
if isfield(finput.num,'boundaries')
% Find out dimensionality
    fields  =   fieldnames(finput.num.boundaries);
    ndim    =   numel(fields);
    size_tot=   zeros(ndim,1);
    for i=1:ndim
        xb_loc              =   finput.num.boundaries.(fields{i});
        PSD.Dx.(fields{i})  =   xb_loc(2)-xb_loc(1); % no support for geogrid
        PSD.xp.(fields{i})  =   (xb_loc(2:end)+xb_loc(1:end-1))/2;
        PSD.xb.(fields{i})  =   xb_loc;
        size_loc            =   size(PSD.xp.(fields{i}));
        size_tot(i)         =   size_loc(2)+3;
    end
elseif isfield(finput.num,'y')
    fields  =   fieldnames(finput.num.y);
    ndim    =   numel(fields);
    size_tot=   zeros(ndim,1);
    for i=1:ndim
        xp_loc              =   [finput.num.y.(fields{i})]; 
        PSD.Dx.(fields{i})  =   xp_loc(2)-xp_loc(1); % no support for geogrid
        PSD.xb.(fields{i})  =   cumsum([0 repmat(PSD.Dx.(fields{i}),1,length(xp_loc))]);
        PSD.xp.(fields{i})  =   xp_loc;
        size_loc            =   size(PSD.xp.(fields{i}));
        size_tot(i)         =   size_loc(2)+3;
    end
end

if sum(~structfun(@isscalar,PSD.Dx))>0
    error('Only uniform gridspacing supported')
end

% Copy f0 into (ndim+1)-dimensional array f (extension into time domain)
f                       =   zeros([size_tot 1]);  % extend into time domain
if ndim==1
    f(3:end-1,1)                    =   PD.init_dist.F;
elseif ndim==2
    f(3:end-1,3:end-1,1)            =   finput.exp.f0;
elseif ndim==3
    f(3:end-1,3:end-1,3:end-1,1)    =   finput.exp.f0;
end

% Replicate char. length vectors to form arrays of size(f)
xp1_arr                 =   repmat(PSD.xp.dim1(:),[1 finput.num.ngrid(2:end)]);
if ndim>1
    if length(finput.num.ngrid)==2
        finput.num.ngrid(3)=1;
    end
    xp2_arr             =   repmat(PSD.xp.dim2(:)',[finput.num.ngrid(1) 1 finput.num.ngrid(3)]);
end
if ndim>2
    xp3_arr             =   repmat(permute(PSD.xp.dim3(:),[3 2 1]),[finput.num.ngrid(1:2) 1]); 
end

tvec    =   PD.sol_time(1);

%% Integration
    t=PD.sol_time(1);tcount=1;c(1)=PD.init_conc;  
    
    T(1) = PD.init_temp; V(1) = PD.init_volume;
 
    flagdt=0;
    
    % Various memory preallocating
    Dtsub = zeros(numel(fields),1);
    infin = zeros(numel(fields),1);
    while t<finput.exp.ttot

        % Find Growth Rates along all dimensions
        for i=1:numel(fields)
            G.(fields{i}) = PD.growthrate(c(tcount),T(tcount),PSD.xp.(fields{i}));
        end

        % Autotimestepsizer based on CFL condition (eq. 24 in Gunawan 2004)
        if flagdt==0
            
            for i=1:numel(fields)
                [~,I]       =   max(abs(G.(fields{i}))./PSD.Dx.(fields{i}));
                Dtsub(i)    =   abs(1*PSD.Dx.(fields{i})/G.(fields{i})(I));
            end
            
            if isfield(finput.exp,'tline')
                nexttline   =   finput.exp.tline(find(finput.exp.tline>t,1,'first'));
                Dttline =   nexttline-t;
            else
                Dttline     =   inf;
            end
            
            Dt      =   min([0.1*finput.exp.ttot Dtsub finput.exp.ttot-t Dttline]);   % choose minimum of expressions (not too coarse description for plotting purposes)

        end

        t           =   t+Dt; % update time step
%         tau         =   t/finput.exp.ttot
        
        % mini failsafe
        if finput.exp.ttot-t     <   1e-12
            t   =   finput.exp.ttot;
        end

        if ~isscalar(size_tot)
            fstarstar   =   reshape(f(end-prod(size_tot)+1:end),size_tot); % take last (wrt time) distribution
        else
            fstarstar   =   f(:,end);
        end
        
        fstar   =    fstarstar;
        
        % Speeding up the 3D calculations
        if ndim==3
            % find smallest box containing all nonzeros (+ buffer space)
            I   =   find(fstarstar~=0,1,'last');
            
            infin(3)    =   ceil(I/prod(size_tot(1:2)));
            infin(2)    =   ceil(rem(I,(infin(3)-1)*prod(size_tot(1:2)))/size_tot(1));
            infin(1)    =   I-(infin(2)-1)*size_tot(1)-(infin(3)-1)*prod(size_tot(1:2));
            
            infin(infin+3>size_tot)=size_tot(infin+3>size_tot)-3;

            fstar   =   fstarstar(1:infin(1)+3,1:infin(2)+3,1:infin(3)+3);
        
        end   
        
        for i   =   1:ndim
            % Shift PSD such that current dimension lies along the rows of the local matrix
            fstar   =   shiftdim(fstar,i-1);

            deltaf  =   diff(fstar,1,1);

            % Find Theta
            if max(G.(fields{i}))   >=  0
                Theta   =   arrayDivision(deltaf,1,1);
            else
                Theta   =   arrayDivision(deltaf,1,2);
                Theta   =   circshift(Theta,[-1 0]);
            end
      
            Theta(isinf(Theta))     =   2;
            Theta(isnan(Theta))     =   0;

            Phi                     =   Phifinder(Theta,finput.setup.Phi);    % Flux limiter
            
            if ndim==3
                Gvec                =   G.(fields{i})(1:infin(i));
            else
                Gvec                =   G.(fields{i});
            end
            Gmat                    =   repmat([0; 0; Gvec(:); 0],size(fstar(1,:,:)));

            % Calculate (potential) next distribution
            if length(unique(G.(fields{i})))>1 && min(G.(fields{i}))>=0

                f_dummy=fstar(3:end-1,:,:)-Dt./PSD.Dx.(fields{i}).*(Gmat(3:end-1,:,:).*fstar(3:end-1,:,:)-Gmat(2:end-2,:,:).*fstar(2:end-2,:,:))-...           % f(t=t+Dt) saved in a dummy variable for convenience
                        (Dt./(2*PSD.Dx.(fields{i})).*Gmat(3:end-1,:,:).*(1-(Dt./PSD.Dx.(fields{i}).*Gmat(3:end-1,:,:))).*(fstar(4:end,:,:)-fstar(3:end-1,:,:)).*Phi(2:end,:,:)-...
                        Dt./(2*PSD.Dx.(fields{i})).*Gmat(2:end-2,:,:).*(1-Dt./PSD.Dx.(fields{i}).*Gmat(2:end-2,:,:)).*(fstar(3:end-1,:,:)-fstar(2:end-2,:,:)).*Phi(1:end-1,:,:));

                elseif length(unique(G.(fields{i})))>1 && min(G.(fields{i}))<=0


                    f_dummy=fstar(3:end-1,:,:)-Dt./PSD.Dx.(fields{i}).*(Gmat(4:end,:,:).*fstar(4:end,:,:)-Gmat(3:end-1,:,:).*fstar(3:end-1,:,:))+...           % f(t=t+Dt) saved in a dummy variable for convenience
                        (Dt./(2*PSD.Dx.(fields{i})).*Gmat(3:end-1,:,:).*(1+(Dt./PSD.Dx.(fields{i}).*Gmat(3:end-1,:,:))).*(fstar(4:end,:,:)-fstar(3:end-1,:,:)).*Phi(2:end,:,:)-...
                        Dt./(2*PSD.Dx.(fields{i})).*Gmat(2:end-2,:,:).*(1+Dt./PSD.Dx.(fields{i}).*Gmat(2:end-2,:,:)).*(fstar(3:end-1,:,:)-fstar(2:end-2,:,:)).*Phi(1:end-1,:,:));

                elseif min(G.(fields{i}))>=0

                    f_dummy=fstar(3:end-1,:,:)-Dt*G.(fields{i})(1)./PSD.Dx.(fields{i}).*(fstar(3:end-1,:,:)-fstar(2:end-2,:,:))-Dt.*G.(fields{i})(1)./(2*PSD.Dx.(fields{i})).*(1-Dt.*G.(fields{i})(1)./PSD.Dx.(fields{i})).*...
                        ((fstar(4:end,:,:)-fstar(3:end-1,:,:)).*Phi(2:end,:,:)-(fstar(3:end-1,:,:)-fstar(2:end-2,:,:)).*Phi(1:end-1,:,:));

                elseif max(G.(fields{i}))<=0

                    f_dummy=fstar(3:end-1,:,:)-Dt*G.(fields{i})(1)./PSD.Dx.(fields{i}).*(fstar(4:end,:,:)-fstar(3:end-1,:,:))-Dt*G.(fields{i})(1)./(PSD.Dx.(fields{i})*2).*(1+Dt*G.(fields{i})(1)./PSD.Dx.(fields{i})).*...
                        ((fstar(3:end-1,:,:)-fstar(2:end-2,:,:)).*Phi(1:end-1,:,:)-(fstar(4:end,:,:)-fstar(3:end-1,:,:)).*Phi(2:end,:,:));     
            end
            
            % Possible Volume change
            f_dummy             =   f_dummy - PD.ASadditionrate(t)*fstar(3:end-1,:,:)/V(tcount)*Dt;
            % Copy back
            fstar(3:end-1,:,:)  =   f_dummy;

            if ~isvector(fstar)
                fstar   =   shiftdim(fstar,ndim-i+1);
            end
        
        end
         
        % Calculation of concentration at next timestep
        if ndim==1
            c_dummy     =    c(tcount)-3 *PD.rhoc*PD.kv*sum(G.dim1(:).*f(3:end-1,tcount).*PSD.Dx.dim1.*xp1_arr(:).^2)*Dt ...
                -PD.ASadditionrate(t)*c(tcount)/V(tcount)*Dt;
            
        elseif ndim==2
            
            c_dummy     =   c(tcount)-PD.rhoc*PD.kv*sum(sum((2*xp1_arr.*repmat(G.dim1',1,length(PSD.xp.dim2)).*xp2_arr+...
                repmat(G.dim2,length(PSD.xp.dim1),1).*xp1_arr.^2).*f(3:end-1,3:end-1,tcount).*PSD.Dx.dim1.*PSD.Dx.dim2))*Dt...
            -PD.ASadditionrate(t)*c(tcount)/V(tcount)*Dt;
            
        elseif ndim==3
            
            c_dummy     =   c(tcount)-PD.rhoc*PD.kv*sum(sum(sum((xp1_arr.*xp2_arr.*repmat(permute(G.dim3(:),[3 2 1]),[size_tot(1:2)-3 1])+...
                xp1_arr.*xp3_arr.*repmat(G.dim2(:)',[size_tot(1)-3 1 size_tot(3)-3])+...
                xp2_arr.*xp3_arr.*repmat(G.dim1(:),[1 size_tot(2:3)-3])).*...
                f(3:end-1,3:end-1,3:end-1,tcount).*PSD.Dx.dim1.*PSD.Dx.dim2.*PSD.Dx.dim3))).*Dt...
                -PD.ASadditionrate(t)*c(tcount)/V(tcount)*Dt;
            
        end
        
      
        % Addition of Nucleation term
        if ~isempty(PD.nucleationrate)
                B         =   PD.nucleationrate(c(tcount),T(tcount))*Dt;
                if ndim==1
                    fstar(3)    =   fstar(3)        +   B;
                elseif ndim==2
                    fstar(3,3)  =   fstar(3,3)      +   B;
                elseif ndim==3
                    fstar(3,3,3)=   fstar(3,3,3)    +   B;
                    c_dummy     =   c_dummy-B*PD.rhoc .* PSD.xp.dim1(1) .* PSD.Dx.dim1.*PSD.Dx.dim2.*PSD.Dx.dim3 .* PSD.xp.dim2(1) .* PSD.xp.dim3(1);
                end
        end
        
        
        if t<=finput.exp.ttot

            T_dummy = PD.init_temp+PD.coolingrate(t)*(t-PD.sol_time(1));
            V_dummy = PD.init_volume+PD.ASadditionrate(t)*(t-PD.sol_time(1));
            
            % Check if result is approximately reasonable
            if  sum(sum(sum(-fstar(fstar<0))))<sum(sum(sum(fstar(fstar>0))))*1e-2 && c_dummy>0 
                
                % Finalize Timestep
                if ndim==1
                    f(:,tcount+1)       =   fstar;
                elseif ndim==2
                    f(:,:,tcount+1)     =   fstar;
                elseif ndim==3
                    f(:,:,:,tcount+1)   =   fstar;
                end
                
                c(tcount+1)     =   c_dummy;

                T(tcount+1)     =   T_dummy; % Temperature
                V(tcount+1)     =   V_dummy;
                
                tvec    =   [tvec t];
                tcount  =   tcount+1;   
                flagdt  =   0;

            else
                % Use a smaller timestep and repeat everything
                t       =   t-Dt;
                flagdt  =   1;
                Dt      =   Dt/2;
            end

        end
       
        
    end

%% Finishing up

if ndim==1
    f=f(3:end-1,:);
elseif ndim==2
    f=f(3:end-1,3:end-1,:);
elseif ndim==3
    f=f(3:end-1,3:end-1,3:end-1,:);
end
PSD.F=f;

output  =   struct('PSD',PSD,'time',tvec(:),'Temp',T(:),'Volume',V(:),'c',c(:),'ndim',ndim,'fields',{fields});
end


