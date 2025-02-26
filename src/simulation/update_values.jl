#=
function update_values!(integrator)
    (nvars, ncells) = size(integrator.u)

    nandetected = false
    infdetected = false

    # Update the timestep
    if integrator.p.adaptive
        SciMLBase.set_proposed_dt!(integrator, integrator.p.CFL * integrator.p.max_timestep[1])
    end

    @inbounds for j in 1:ncells, i in 1:nvars
        if isnan(integrator.u[i, j])
            println("NaN detected in variable $i in cell $j at time $(integrator.t)")
            nandetected = true
            terminate!(integrator, :NaNDetected)
            break
        elseif isinf(integrator.u[i, j])
            println("Inf detected in variable $i in cell $j at time $(integrator.t)")
            infdetected = true
            terminate!(integrator, :InfDetected)
            break
        end
    end

    if !nandetected && !infdetected
        update_values!(integrator.u, integrator.p, integrator.t)
    end
end
=#

# update useful quantities relevant for potential, electron energy and fluid solve
function update_values!(U, params, t = 0)
    (;z_cell, index, A_ch) = params
    (;
        B, ue, Tev, ∇ϕ, ϕ, pe, ne, μ, ∇pe, νan, νc, νen, νei, νew,
        Z_eff, νiz, νex, νe, ji, Id, νew, νiw, ni, ui, Vs, nn, nn_tot, niui,
    ) = params.cache

    # Update the current iteration
    params.iteration[1] += 1

    # Apply fluid boundary conditions
    @views left_boundary_state!(U[:, 1], U, params)
    @views right_boundary_state!(U[:, end], U, params)

    ncells = size(U, 2)

    # Update electron quantities
    @inbounds for i in 1:ncells

        # Compute neutral number densities for each neutral fluid
        nn_tot[i] = 0.0
        for j in 1:params.num_neutral_fluids
            nn[j, i] = U[index.ρn[j], i] / params.config.propellant.m
            nn_tot[i] += nn[j, i]
        end

        # Compute ion densities and velocities
        for Z in 1:params.config.ncharge
            ni[Z, i] = U[index.ρi[Z], i] / params.config.propellant.m
            ui[Z, i] = U[index.ρiui[Z], i] / U[index.ρi[Z], i]
            niui[Z, i] = U[index.ρiui[Z], i] / params.config.propellant.m
        end

        # Compute electron number density, making sure it is above floor
        ne[i] = max(params.config.min_number_density, electron_density(U, params, i))

        # Same with electron temperature
        Tev[i] = 2/3 * max(params.config.min_electron_temperature, U[index.nϵ, i]/ne[i])

        pe[i] = if params.config.LANDMARK
            # The LANDMARK benchmark uses nϵ instead of pe in the potential solver, but we use pe, so
            # we need to define pe = 3/2 ne Tev
            3/2 * ne[i] * Tev[i]
        else
            # Otherwise, just use typical ideal gas law.
            ne[i] * Tev[i]
        end
        # Compute electron-neutral and electron-ion collision frequencies
        νen[i] = freq_electron_neutral(U, params, i)
        νei[i] = freq_electron_ion(U, params, i)

        # Compute total classical collision frequency
        νc[i] = νen[i] + νei[i]
        if !params.config.LANDMARK
            # Add momentum transfer due to ionization and excitation
            νc[i] += νiz[i] + νex[i]
        end
        # Compute anomalous collision frequency and wall collision frequencies
        νew[i] = freq_electron_wall(params.config.wall_loss_model, U, params, i)
        νan[i] = freq_electron_anom(U, params, i)

        # Compute total collision frequency and electron mobility
        νe[i] = νc[i] + νan[i] + νew[i]
        μ[i] = electron_mobility(νe[i], B[i])

        # Effective ion charge state (density-weighted average charge state)
        Z_eff[i] = compute_Z_eff(U, params, i)

        # Ion current
        ji[i] = ion_current_density(U, params, i)
    end

    # Compute anode sheath potential
    Vs[] = anode_sheath_potential(U, params)

    # Compute the discharge current by integrating the momentum equation over the whole domain
    Id[] = discharge_current(U, params)

    # Compute the electron velocity and electron kinetic energy
    @inbounds for i in 1:ncells
        # je + ji = Id / A_ch
        ue[i] = (ji[i] - Id[] / A_ch) / e / ne[i]

        # Kinetic energy in both axial and azimuthal directions is accounted for
        params.cache.K[i] = electron_kinetic_energy(U, params, i)
    end

    # Compute potential gradient and pressure gradient
    compute_pressure_gradient!(∇pe, params)

    # Compute electric field
    compute_electric_field!(∇ϕ, params)

    # update electrostatic potential and potential gradient on edges
    solve_potential_cell!(ϕ, params)

    # Update the electron temperature and pressure
    update_electron_energy!(U, params)
end

function compute_electric_field!(∇ϕ, params)
    (;A_ch, cache) = params
    (;ji, Id, ne, μ, ∇pe) = cache

    for i in eachindex(∇ϕ)
        ∇ϕ[i] = -((Id[] / A_ch - ji[i]) / e / μ[i] - ∇pe[i]) / ne[i]
    end

    return ∇ϕ
end

function compute_pressure_gradient!(∇pe, params)
    (; pe) = params.cache
    (;z_cell) = params

    ncells = length(z_cell)

    # Pressure gradient (forward)
    ∇pe[1] = forward_difference(pe[1], pe[2], pe[3], z_cell[1], z_cell[2], z_cell[3])

    # Centered difference in interior cells
    @inbounds for j in 2:ncells-1

        # Compute pressure gradient
        ∇pe[j] = central_difference(pe[j-1], pe[j], pe[j+1], z_cell[j-1], z_cell[j], z_cell[j+1])
    end

    # pressure gradient (backward)
    ∇pe[end] = backward_difference(pe[end-2], pe[end-1], pe[end], z_cell[end-2], z_cell[end-1], z_cell[end])

    return nothing
end
