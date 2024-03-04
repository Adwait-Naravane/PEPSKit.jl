# Computation of F in SVD adjoint, including Lorentzian broadening
function invert_S²(S::AbstractMatrix{T}, tol::Real; εbroad=0) where {T<:Real}
    F = similar(S)
    @inbounds for i in axes(F, 1), j in axes(F, 2)
        F[i, j] = if i == j
            zero(T)
        else
            sᵢ, sⱼ = S[i, i], S[j, j]
            Δs = abs(sⱼ - sᵢ) < tol ? tol : sⱼ^2 - sᵢ^2
            εbroad > 0 && (Δs = lorentz_broaden(Δs, εbroad))
            1 / Δs
        end
    end
    return F
end

# Lorentzian broadening for SVD adjoint singularities
function lorentz_broaden(x::Real, ε=1e-12)
    x′ = 1 / x
    return x′ / (x′^2 + ε)
end

# Proper truncated SVD using iterative solver
function itersvd(
    t::AbstractTensorMap,
    χ::Int;
    εbroad=0,
    solverkwargs=(; krylovdim=χ + 5, tol=1e2eps(real(scalartype(t)))),
)
    vals, lvecs, rvecs, info = svdsolve(t.data, dim(codomain(t)), χ; solverkwargs...)
    truncspace = field(t)^χ
    if info.converged < χ  # Fall back to dense SVD
        @warn "falling back to dense SVD solver since length(S) < χ"
        return tsvd(t; trunc=truncdim(χ), alg=TensorKit.SVD())
    else
        vals = @view(vals[1:χ])
        lvecs = @view(lvecs[1:χ])
        rvecs = @view(rvecs[1:χ])
    end
    U = TensorMap(hcat(lvecs...), codomain(t) ← truncspace)
    S = TensorMap(diagm(vals), truncspace ← truncspace)
    V = TensorMap(copy(hcat(rvecs...)'), truncspace ← domain(t))
    return U, S, V
end

# Reverse rule adopted from tsvd! rrule as found in TensorKit.jl
function ChainRulesCore.rrule(
    ::typeof(itersvd), t::AbstractTensorMap, χ::Int; εbroad=0, kwargs...
)
    U, S, V = itersvd(t, χ; kwargs...)

    function itersvd_pullback((ΔU, ΔS, ΔV))
        ∂t = similar(t)
        for (c, b) in blocks(∂t)
            copyto!(
                b,
                itersvd_rev(
                    block(t, c),
                    block(U, c),
                    block(S, c),
                    block(V, c),
                    block(ΔU, c),
                    block(ΔS, c),
                    block(ΔV, c);
                    εbroad,
                ),
            )
        end
        return NoTangent(), ∂t, NoTangent()
    end

    return (U, S, V), itersvd_pullback
end

# SVD adjoint with proper truncation
function itersvd_rev(
    A::AbstractMatrix,
    U::AbstractMatrix,
    S::AbstractMatrix,
    V::AbstractMatrix,
    ΔU,
    ΔS,
    ΔV;
    εbroad=0,
    atol::Real=0,
    rtol::Real=atol > 0 ? 0 : eps(scalartype(S))^(3 / 4),
)
    Ad = copy(A')
    tol = atol > 0 ? atol : rtol * S[1, 1]
    F = invert_S²(S, tol; εbroad)  # Includes Lorentzian broadening
    S⁻¹ = pinv(S; atol=tol)

    # dS contribution
    term = ΔS isa ZeroTangent ? ΔS : Diagonal(real.(ΔS))  # Implicitly performs 𝕀 ∘ dS

    # dU₁ and dV₁ off-diagonal contribution
    J = F .* (U' * ΔU)
    term += (J + J') * S
    VΔV = (V * ΔV')
    K = F .* VΔV
    term += S * (K + K')

    # dV₁ diagonal contribution (diagonal of dU₁ is gauged away)
    if scalartype(U) <: Complex && !(ΔV isa ZeroTangent) && !(ΔU isa ZeroTangent)
        L = Diagonal(VΔV)  # Implicitly performs 𝕀 ∘ dV
        term += 0.5 * S⁻¹ * (L' - L)
    end
    ΔA = U * term * V

    # Projector contribution for non-square A and dU₂ and dV₂
    UUd = U * U'
    VdV = V' * V
    Uproj = one(UUd) - UUd
    Vproj = one(VdV) - VdV
    m, k, n = size(U, 1), size(U, 2), size(V, 2)
    dimγ = k * m  # Vectorized dimension of γ-matrix

    # Truncation contribution from dU₂ and dV₂
    # TODO: Use KrylovKit instead of IterativeSolvers
    Sop = LinearMap(k * m + k * n) do v  # Left-preconditioned linear problem
        γ = reshape(@view(v[1:dimγ]), (k, m))
        γd = reshape(@view(v[(dimγ + 1):end]), (k, n))
        Γ1 = γ - S⁻¹ * γd * Vproj * Ad
        Γ2 = γd - S⁻¹ * γ * Uproj * A
        vcat(reshape(Γ1, :), reshape(Γ2, :))
    end
    if ΔU isa ZeroTangent && ΔV isa ZeroTangent
        γ = gmres(Sop, zeros(eltype(A), k * m + k * n))
    else
        # Explicit left-preconditioning
        # Set relative tolerance to machine precision to converge SVD gradient error properly
        γ = gmres(
            Sop,
            vcat(reshape(S⁻¹ * ΔU' * Uproj, :), reshape(S⁻¹ * ΔV * Vproj, :));
            reltol=eps(real(eltype(A))),
        )
    end
    γA = reshape(@view(γ[1:dimγ]), k, m)
    γAd = reshape(@view(γ[(dimγ + 1):end]), k, n)
    ΔA += Uproj * γA' * V + U * γAd * Vproj

    return ΔA
end
