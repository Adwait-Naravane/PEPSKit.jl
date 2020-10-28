#=
    This method is a bit deceptive. Not only do we find the fp0 fixpoints,
    but we also immediatly change the boundary mpses to ensure a |1| norm
    maybe we should do that later on in renormalize!
    but then that would also complicate the logic there ...
=#
function fp0!(nfps,sfps,east,west;verbose=false)
    (ncols,nrows) = size(east);

    for i in 1:ncols

        #re-use the initial guess if possible
        initl = nfps[1,i];
        if _firstspace(initl) != _lastspace(west.AL[i,end])' || _lastspace(initl) != _firstspace(east.AL[end-i+2,1])'
            initl = TensorMap(rand,ComplexF64,_lastspace(west.AL[i,end])',_firstspace(east.AL[end-i+2,1]))
        end

        initr = sfps[1,end-i+2];
        if _firstspace(initr) != _lastspace(east.AL[end-i+2,end])' || _lastspace(initr) != _firstspace(west.AL[i,1])'
            initr = TensorMap(rand,ComplexF64,space(east.AL[end-i+2,end],4)',space(west.AL[i,1],1))
        end

        (lva,lve,convhist) = eigsolve(x->crosstransfer(x,east.AL[end-i+2,:],reverse(west.AR[i,:])),initl,1,:LM,Arnoldi());
        convhist.converged == 0 && @warn "lfp0 failed to converge $(convhist.normres)"
        (rva,rve,convhist) = eigsolve(x->crosstransfer(x,west.AL[i,:],reverse(east.AR[end-i+2,:])),initr,1,:LM,Arnoldi());
        convhist.converged == 0 && @warn "rfp0 failed to converge $(convhist.normres)"

        verbose && @info "leading lfp0 val $((lva[1]))"
        verbose && @info "leading rfp0 val $((rva[1]))"
        rva[1] ≈ lva[1] || @warn "leading eigenvalues don't match up $(rva[1]) $(lva[1])"

        pref = (1.0/lva[1])^(1/(2*nrows));

        # first we change the phase AND AMPLITUDE of up.AL to make lva real
        # it's a bit annoying because mpskit assumes things to be orthonormalized
        for temp in 1:nrows
            rmul!(east.AL[end-i+2,temp],pref)
            rmul!(east.AC[end-i+2,temp],pref)
            rmul!(east.AR[end-i+2,temp],pref)

            rmul!(west.AL[i,temp],pref)
            rmul!(west.AC[i,temp],pref)
            rmul!(west.AR[i,temp],pref)
        end

        #=
            We already imposed that transferring over one unit cell has eigenvalue 1
            We also need that 2 contracted fixpoints have norm 1
        =#
        val = @tensor lve[1][1,2]*east.CR[end-i+2,0][2,3]*rve[1][3,4]*west.CR[i,end][4,1];
        nfps[1,i] = lve[1]/sqrt(val);
        sfps[1,end-i+2] = rve[1]/sqrt(val);

        #the other fixpoints are determined by doing the transfer
        for j in 2:nrows
            nfps[j,i] = crosstransfer(nfps[j-1,i],east.AL[end-i+2,j-1],west.AR[i,end-j+2])
            sfps[j,end-i+2] = crosstransfer(sfps[j-1,end-i+2],west.AL[i,j-1],east.AR[end-i+2,end-j+2])
        end

        for j in 1:nrows
            val = @tensor nfps[j,i][1,2]*east.CR[end-i+2,j-1][2,3]*sfps[end-j+2,end-i+2][3,4]*west.CR[i,end-j+1][4,1];
            verbose && @info "fp0 inconsistency $(abs(val-1))"
        end

    end

    return nfps,sfps
end

#---- I don't know how to clean the following up

#gets leading fix points in the north direction
function north_fp1!(nfps#=dst=#,west,peps,east;verbose = false)

    (nrows,ncols) = size(peps);

    for i in 1:ncols

        initl = nfps[1,i];
        if _firstspace(initl) != space(west.AL[i,end],4)' || _lastspace(initl) != _firstspace(east.AL[end-i+1,1])'
            initl = TensorMap(rand,ComplexF64,space(west.AL[i,nrows],4)'*space(peps[1,i],North)'*space(peps[1,i],North),space(east.AL[end-i+1,1],1))
        end

        (lva,lve,convhist) = eigsolve(x->crosstransfer(x,peps[:,i],east.AL[end-i+1,:],reverse(west.AR[i,:])),initl,1,:LM,Arnoldi());
        convhist.converged == 0 && @warn "fp1 failed to converge $(convhist.normres)"
        verbose && @info "leading fp1 val $(lva[1]))"
        nfps[1,i] = lve[1];

        for j in 2:nrows
            nfps[j,i] = crosstransfer(nfps[j-1,i],peps[j-1,i],east.AL[end-i+1,j-1],west.AR[i,end-j+2])
        end
    end

    return nfps
end

function north_fp2(west,peps,east;verbose = false)
    (nrows,ncols) = size(peps);

    nfps = Array{Any,2}(undef,nrows,ncols);

    for i in 1:ncols
        initl = TensorMap(rand,ComplexF64,space(west.AL[i,nrows],4)'*space(peps[1,i],North)'*space(peps[1,i],North)*space(peps[1,i+1],North)'*space(peps[1,i+1],North),space(east.AL[end-i,1],1))

        (lva,lve,convhist) = eigsolve(x->crosstransfer(x,peps[:,i],peps[:,i+1],east.AL[end-i,:],reverse(west.AR[i,:])),initl,1,:LM,Arnoldi());
        convhist.converged == 0 && @info "fp2 failed to converge"
        verbose && println("leading fp2 val $(lva[1])")
        nfps[1,i] = lve[1];

        for j in 2:nrows
            nfps[j,i] = crosstransfer(nfps[j-1,i],peps[j-1,i],peps[j-1,i+1],east.AL[end-i,j-1],west.AR[i,nrows-j+2])
        end
    end

    return PeriodicArray(convert(Array{typeof(nfps[1,1]),2},nfps))
end
