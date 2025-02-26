
function update_heavy_species!(dU, U, params, t)
    ####################################################################
    #extract some useful stuff from params

    (;index, Δz_cell, config, cache) = params
    (;
        source_neutrals, source_ion_continuity, source_ion_momentum,
        ncharge, ion_wall_losses
    ) = config

    (;F, UL, UR) = cache

    ncells = size(U, 2)

    compute_fluxes!(F, UL, UR, U, params)

    @inbounds for i in 2:ncells-1
        left = left_edge(i)
        right = right_edge(i)

        Δz = Δz_cell[i]

        # Handle neutrals
        for j in 1:params.num_neutral_fluids
            # Neutral fluxes
            dU[index.ρn[j], i] = (F[index.ρn[j], left] - F[index.ρn[j], right]) / Δz

            # User-provided neutral source term
            dU[index.ρn[j], i] += source_neutrals[j](U, params, i)
        end

        # Handle ions
        for Z in 1:ncharge
            # Ion fluxes
            dU[index.ρi[Z]  , i] = (F[index.ρi[Z],   left] - F[index.ρi[Z],   right]) / Δz
            dU[index.ρiui[Z], i] = (F[index.ρiui[Z], left] - F[index.ρiui[Z], right]) / Δz

            # User-provided ion source terms
            dU[index.ρi[Z],   i] += source_ion_continuity[Z](U, params, i)
            dU[index.ρiui[Z], i] += source_ion_momentum[Z  ](U, params, i)
        end

        apply_ion_acceleration!(dU, U, params, i)
        apply_reactions!(dU, U, params, i)

        if ion_wall_losses
            apply_ion_wall_losses!(dU, U, params, i)
        end

        dU[index.nϵ, i] = 0.0
    end

    @. @views dU[:, 1] = 0.0
    @. @views dU[:, end] = 0.0

    return nothing
end
