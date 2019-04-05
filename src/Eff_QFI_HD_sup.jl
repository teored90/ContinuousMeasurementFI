using ZChop # For chopping small imaginary parts in ρ
using Distributed

"""
    (t, FI, QFI) = Eff_QFI_HD(Nj, Ntraj, Tfinal, dt; kwargs... )

Evaluate the continuous-time FI and QFI of a final strong measurement for the
estimation of the frequency ω with continuous homodyne monitoring of each half-spin
particle affected by noise at an angle θ, with efficiency η using SME
(stochastic master equation).

The function returns a tuple `(t, FI, QFI)` containing the time vector and the vectors containing the FI and average QFI

# Arguments

* `Nj`: number of spins
* `Ntraj`: number of trajectories for the SSE
* `Tfinal`: final time of evolution
* `dt`: timestep of the evolution
* `κ = 1`: the noise coupling
* `θ = 0`: noise angle (0 parallel, π/2 transverse)
* `ω = 0`: local value of the frequency
* `η = 1`: measurement efficiency
"""
function Eff_QFI_HD_sup(Ntraj::Int64,       # Number of trajectories
    Tfinal::Number,                     # Final time
    dt::Number,                         # Time step
    H, dH,                              # Hamiltonian and its derivative wrt ω
    non_monitored_noise_op,             # Non monitored noise operators
    monitored_noise_op;                 # Monitored noise operators
    initial_state = ghz_state,          # Initial state
    η = 1.)                             # Measurement efficiency

    dimJ = size(H, 1)       # Dimension of the corresponding Hilbert space
    Nj = Int(log2(dimJ))    # Number of spins

    Ntime = Int(floor(Tfinal/dt)) # Number of timesteps

    # Non-monitored noise operators
    # cj = [] if all the noise is monitored
    cj = non_monitored_noise_op
    Nnm = length(cj)

    if Nnm == 0
        cj = spzeros(dimJ, dimJ)
    end

    cjprepost = sup_pre_post.(cj)
    scjprepost = sum(cjprepost)

    # Monitored noise operators
    Cj = monitored_noise_op
    Nm = length(Cj)
    @assert Nm > 0 "monitored_noise_op can't be empty"


    Cjprepost = sup_pre_post.(Cj)
    sCjprepost =  sum(Cjprepost)
 
    # We store the operators sums for efficiency
    CjSumpre = [sup_pre(c + c') for c in Cj]

    # We store the operators products for efficiency
    CjProd = [Cj[i]*Cj[j] for i in eachindex(Cj), j in eachindex(Cj)]

    dW() = sqrt(dt) * randn(Nm) # Define the Wiener increment vector

    # Kraus-like operator, trajectory-independent part

    M0 = sparse(I - 1im * H * dt -
                0.5 * dt * sum([c' * c for c in cj]) - 
                0.5 * dt * sum([c' * c for c in Cj]))

    # Derivative of the Kraus-like operator wrt to ω
    dM = -1im * dH * dt

    dMpre = sup_pre(dM)
    dMpost = sup_post(dM')

    # Initial state of the system
    ψ0 = initial_state(Nj)
    ρ0 = (ψ0 * ψ0')[:]

    t = (1 : Ntime) * dt

    # Run evolution for each trajectory, and build up the average
    # for FI and final strong measurement QFI
    result = @distributed (+) for ktraj = 1 : Ntraj
        ρ = ρ0 # Assign initial state to each trajectory

        # Derivative of ρ wrt the parameter
        # Initial state does not depend on the paramter
        dρ = zero(ρ)
        τ = dρ

        # Vectors for the FI and QFI for each trajectory
        FisherT = zero(t)
        QFisherT = zero(t)

        for jt = 1 : Ntime

            # Homodyne current (Eq. 35)
            dy = dt * sqrt(η) * [trace(c*ρ) for c in CjSumpre] + dW()

            # Kraus operator Eq. (36)
            M = M0 +
                sqrt(η) * sum([Cj[j] * dy[j] for j = 1:Nm]) +
                η/2 * sum([CjProd[i,j] *(dy[i] * dy[j] - (i == j ? dt : 0)) for i = 1:Nm, j = 1:Nm])

            Mpre = sup_pre(M)
            Mpost = sup_post(M')

            # Evolve the density operator
            new_ρ = (Mpre * Mpost * ρ +
                     (1 - η) * dt * sCjprepost * ρ +
                     dt * scjprepost * ρ)

            zchop!(new_ρ) # Round off elements smaller than 1e-14

            tr_ρ = trace(new_ρ)

            # Evolve the unnormalized derivative wrt ω            
            τ = (Mpre * (Mpost * τ  +  dMpost * ρ) + dMpre * Mpost * ρ +
                  (1 - η)* dt * sCjprepost * τ +
                  dt * scjprepost * τ )/ tr_ρ;

            zchop!(τ) # Round off elements smaller than 1e-14

            tr_τ = trace(τ)

            # Now we can renormalize ρ and its derivative wrt ω
            ρ = new_ρ / tr_ρ
            dρ = τ - tr_τ * ρ

            # We evaluate the classical FI for the continuous measurement
            FisherT[jt] = real(tr_τ^2)

            # We evaluate the QFI for a final strong measurement done at time t
            QFisherT[jt] = QFI(reshape(ρ,(dimJ, dimJ)), reshape(dρ,(dimJ, dimJ)))
        end

        # Use the reduction feature of @distributed for
        # (at the end of each cicle, sum the result to result)
        hcat(FisherT, QFisherT)
    end

    return (t, result[:,1] / Ntraj, result[:,2] / Ntraj)
end