function center_of_mass{X, M, C}(state::MechanismState{X, M, C}, itr)
    frame = root_body(state.mechanism).frame
    com = Point3D(frame, zeros(SVector{3, C}))
    mass = zero(C)
    for body in itr
        inertia = spatial_inertia(body)
        if inertia.mass > zero(C)
            bodyCom = center_of_mass(inertia)
            com += inertia.mass * FreeVector3D(transform(state, bodyCom, frame))
            mass += inertia.mass
        end
    end
    com /= mass
    com
end

center_of_mass(state::MechanismState) = center_of_mass(state, non_root_bodies(state.mechanism))

function geometric_jacobian{X, M, C}(state::MechanismState{X, M, C}, path::Path{RigidBody{M}, Joint{M}})
    copysign = (motionSubspace::GeometricJacobian, sign::Int64) -> sign < 0 ? -motionSubspace : motionSubspace
    motionSubspaces = [copysign(motion_subspace(state, joint), sign)::GeometricJacobian for (joint, sign) in zip(path.edgeData, path.directions)]
    hcat(motionSubspaces...)
end

function acceleration_wrt_ancestor{X, M, C, V}(state::MechanismState{X, M, C},
        descendant::TreeVertex{RigidBody{M}, Joint{M}},
        ancestor::TreeVertex{RigidBody{M}, Joint{M}},
        v̇::StridedVector{V})
    mechanism = state.mechanism
    T = promote_type(C, V)
    descendantFrame = default_frame(mechanism, vertex_data(descendant))
    accel = zero(SpatialAcceleration{T}, descendantFrame, descendantFrame, root_frame(mechanism))
    descendant == ancestor && return accel

    current = descendant
    while current != ancestor
        joint = edge_to_parent_data(current)
        v̇joint = UnsafeVectorView(v̇, mechanism.vRanges[joint])
        jointAccel = SpatialAcceleration(motion_subspace(state, joint), v̇joint)
        accel = jointAccel + accel
        current = parent(current)
    end
    -bias_acceleration(state, vertex_data(ancestor)) + bias_acceleration(state, vertex_data(descendant)) + accel
end

function relative_acceleration(state::MechanismState, body::RigidBody, base::RigidBody, v̇::AbstractVector)
    bodyVertex = findfirst(tree(state.mechanism), body)
    baseVertex = findfirst(tree(state.mechanism), base)
    lca = lowest_common_ancestor(baseVertex, bodyVertex)
    -acceleration_wrt_ancestor(state, baseVertex, lca, v̇) + acceleration_wrt_ancestor(state, bodyVertex, lca, v̇)
end

function potential_energy{X, M, C}(state::MechanismState{X, M, C})
    m = mass(state.mechanism)
    gravitationalForce = m * state.mechanism.gravitationalAcceleration
    centerOfMass = transform(state, center_of_mass(state), gravitationalForce.frame)
    -dot(gravitationalForce, FreeVector3D(centerOfMass))
 end

 function _mass_matrix_part!(out::Symmetric, rowstart::Int64, colstart::Int64, jac::GeometricJacobian, mat::MomentumMatrix)
    # more efficient version of
    # @view out[rowstart : rowstart + n - 1, colstart : colstart + n - 1] = jac.angular' * mat.angular + jac.linear' * mat.linear
    n = num_cols(jac)
    m = num_cols(mat)
    @boundscheck (rowstart > 0 && rowstart + n - 1 <= size(out, 1)) || error("size mismatch")
    @boundscheck (colstart > 0 && colstart + m - 1 <= size(out, 2)) || error("size mismatch")
    framecheck(jac.frame, mat.frame)

    for col = 1 : m
        outcol = colstart + col - 1
        for row = 1 : n
            outrow = rowstart + row - 1
            @inbounds out.data[outrow, outcol] = zero(eltype(out))
            for i = 1 : 3
                @inbounds out.data[outrow, outcol] += jac.angular[i, row] * mat.angular[i, col]
                @inbounds out.data[outrow, outcol] += jac.linear[i, row] * mat.linear[i, col]
            end
        end
    end
 end

function mass_matrix!{X, M, C}(out::Symmetric{C, Matrix{C}}, state::MechanismState{X, M, C}, updateCache::Bool = true)
    updateCache && update_cache!(state, Val{(:motionSubspaces, :crbInertias)})
    @boundscheck size(out, 1) == num_velocities(state) || error("mass matrix has wrong size")
    @boundscheck out.uplo == 'U' || error("expected an upper triangular symmetric matrix type as the mass matrix")
    fill!(out.data, zero(C))
    mechanism = state.mechanism

    for vi in non_root_vertices(state)
        # Hii
        jointStatei = edge_to_parent_data(vi)
        irange = velocity_range(jointStatei)
        Si = motion_subspace(vi)
        F = momentum_matrix(jointStatei.joint, crb_inertia(vi), transform_to_root(vi), configuration(jointStatei))
        istart = first(irange)
        _mass_matrix_part!(out, istart, istart, Si, F)

        # Hji, Hij
        vj = parent(vi)
        while (!isroot(vj))
            jrange = velocity_range(edge_to_parent_data(vj))
            Sj = motion_subspace(vj)
            jstart = first(jrange)
            _mass_matrix_part!(out, jstart, istart, Sj, F)
            vj = parent(vj)
        end
    end
end

function mass_matrix{X, M, C}(state::MechanismState{X, M, C})
    nv = num_velocities(state)
    ret = Symmetric(Matrix{C}(nv, nv))
    mass_matrix!(ret, state)
    ret
end

# TODO: make more efficient:
function momentum_matrix(state::MechanismState)
    hcat([crb_inertia(state, vertex_data(vertex)) * motion_subspace(state, edge_to_parent_data(vertex)) for vertex in non_root_vertices(state.mechanism)]...)
end

function bias_accelerations!{T, X, M}(out::Associative{RigidBody{M}, SpatialAcceleration{T}}, state::MechanismState{X, M})
    gravityBias = convert(SpatialAcceleration{T}, -gravitational_spatial_acceleration(state.mechanism))
    for vertex in non_root_vertices(state)
        body = vertex_data(vertex).body
        out[body] = gravityBias + bias_acceleration(vertex)
    end
    nothing
end

function spatial_accelerations!{T, X, M}(out::Associative{RigidBody{M}, SpatialAcceleration{T}}, state::MechanismState{X, M}, v̇::StridedVector)
    mechanism = state.mechanism

    # TODO: consider merging back into one loop
    # unbiased joint accelerations + gravity
    out[root_body(mechanism)] = convert(SpatialAcceleration{T}, -gravitational_spatial_acceleration(mechanism))
    for vertex in non_root_vertices(state)
        body = vertex_data(vertex).body
        S = motion_subspace(vertex)
        v̇joint = UnsafeVectorView(v̇, velocity_range(edge_to_parent_data(vertex)))
        jointAccel = SpatialAcceleration(S, v̇joint)
        out[body] = out[vertex_data(parent(vertex)).body] + jointAccel
    end

    # add bias acceleration - gravity
    for vertex in non_root_vertices(state)
        body = vertex_data(vertex).body
        out[body] += bias_acceleration(vertex)
    end
    nothing
end

function newton_euler!{T, X, M, W}(
        out::Associative{RigidBody{M}, Wrench{T}}, state::MechanismState{X, M},
        accelerations::Associative{RigidBody{M}, SpatialAcceleration{T}},
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{T}}())
    mechanism = state.mechanism
    for vertex in non_root_vertices(state)
        body = vertex_data(vertex).body
        wrench = newton_euler(vertex, accelerations[body])
        if haskey(externalWrenches, body)
            wrench -= transform(state, externalWrenches[body], wrench.frame)
        end
        out[body] = wrench
    end
end

"""
Note: pass in net wrenches as wrenches argument. wrenches argument is modified to be joint wrenches
"""
function joint_wrenches_and_torques!{T, X, M}(
        torquesOut::StridedVector{T},
        netWrenchesInJointWrenchesOut::Associative{RigidBody{M}, Wrench{T}},
        state::MechanismState{X, M})
    @boundscheck length(torquesOut) == num_velocities(state) || error("torquesOut size is wrong")
    vertices = state.toposortedStateVertices
    for i = length(vertices) : -1 : 2
        vertex = vertices[i]
        body = vertex_data(vertex).body
        jointWrench = netWrenchesInJointWrenchesOut[body]
        if !isroot(parent(vertex))
            parentBody = vertex_data(parent(vertex)).body
            netWrenchesInJointWrenchesOut[parentBody] = netWrenchesInJointWrenchesOut[parentBody] + jointWrench # action = -reaction
        end
        jointState = edge_to_parent_data(vertex)
        jointWrench = transform(jointWrench, inv(transform_to_root(vertex))) # TODO: stay in world frame?
        @inbounds τjoint = UnsafeVectorView(torquesOut, velocity_range(jointState))
        joint_torque!(jointState.joint, τjoint, configuration(jointState), jointWrench)
    end
end

function dynamics_bias!{T, X, M, W}(
        torques::AbstractVector{T},
        biasAccelerations::Associative{RigidBody{M}, SpatialAcceleration{T}},
        wrenches::Associative{RigidBody{M}, Wrench{T}},
        state::MechanismState{X, M},
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{T}}(), updateCache::Bool = true)
    updateCache && update_cache!(state, Val{(:biasAccelerations, :motionSubspaces, :inertias)}) # TODO: stop using motion subspaces by implementing dedicated joint_acceleration function?
    bias_accelerations!(biasAccelerations, state)
    newton_euler!(wrenches, state, biasAccelerations, externalWrenches)
    joint_wrenches_and_torques!(torques, wrenches, state)
end

function inverse_dynamics!{T, X, M, V, W}(
        torquesOut::AbstractVector{T},
        jointWrenchesOut::Associative{RigidBody{M}, Wrench{T}},
        accelerations::Associative{RigidBody{M}, SpatialAcceleration{T}},
        state::MechanismState{X, M},
        v̇::AbstractVector{V},
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{T}}(),
        updateCache::Bool = true)
    updateCache && update_cache!(state, Val{(:biasAccelerations, :motionSubspaces, :inertias)}) # TODO: stop using motion subspaces by implementing dedicated joint_acceleration function?
    spatial_accelerations!(accelerations, state, v̇)
    newton_euler!(jointWrenchesOut, state, accelerations, externalWrenches)
    joint_wrenches_and_torques!(torquesOut, jointWrenchesOut, state)
end

# note: lots of allocations, preallocate stuff and use inverse_dynamics! for performance
function inverse_dynamics{X, M, V, W}(
        state::MechanismState{X, M},
        v̇::AbstractVector{V},
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{X}}())
    T = promote_type(X, M, V, W)
    torques = Vector{T}(num_velocities(state))
    jointWrenches = Dict{RigidBody{M}, Wrench{T}}()
    accelerations = Dict{RigidBody{M}, SpatialAcceleration{T}}()
    inverse_dynamics!(torques, jointWrenches, accelerations, state, v̇, externalWrenches)
    torques
end

type DynamicsResult{M, T}
    massMatrix::Symmetric{T, Matrix{T}}
    massMatrixInversionCache::Symmetric{T, Matrix{T}}
    dynamicsBias::Vector{T}
    biasedTorques::Vector{T}
    v̇::Vector{T}
    accelerations::Dict{RigidBody{M}, SpatialAcceleration{T}}
    jointWrenches::Dict{RigidBody{M}, Wrench{T}}

    function DynamicsResult(::Type{T}, mechanism::Mechanism{M})
        nq = num_positions(mechanism)
        nv = num_velocities(mechanism)
        massMatrix = Symmetric(zeros(T, nv, nv))
        massMatrixInversionCache = Symmetric(zeros(T, nv, nv))
        v̇ = Vector{T}(nv)
        dynamicsBias = zeros(T, nv)
        biasedTorques = zeros(T, nv)
        accelerations = Dict{RigidBody{M}, SpatialAcceleration{T}}()
        sizehint!(accelerations, num_bodies(mechanism))
        jointWrenches = Dict{RigidBody{M}, Wrench{T}}()
        sizehint!(jointWrenches, num_bodies(mechanism))
        new(massMatrix, massMatrixInversionCache, dynamicsBias, biasedTorques, v̇, accelerations, jointWrenches)
    end
end

DynamicsResult{M, T}(t::Type{T}, mechanism::Mechanism{M}) = DynamicsResult{M, T}(t, mechanism)

function joint_accelerations!(out::AbstractVector, massMatrixInversionCache::Symmetric,
        massMatrix::Symmetric, biasedTorques::Vector)
    out[:] = massMatrix \ biasedTorques # TODO: make more efficient
    nothing
end

function joint_accelerations!{T<:Base.LinAlg.BlasReal}(out::AbstractVector{T}, massMatrixInversionCache::Symmetric{T, Matrix{T}},
        massMatrix::Symmetric{T, Matrix{T}}, biasedTorques::Vector{T})
    @inbounds copy!(out, biasedTorques)
    @inbounds copy!(massMatrixInversionCache.data, massMatrix.data)
    Base.LinAlg.LAPACK.posv!(massMatrixInversionCache.uplo, massMatrixInversionCache.data, out)
    nothing
end

function dynamics!{T, X, M, Tau, W}(out::DynamicsResult{T}, state::MechanismState{X, M},
        torques::AbstractVector{Tau} = NullVector{T}(num_velocities(state)),
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{T}}(), updateCache::Bool = true)
    updateCache && update_cache!(state, Val{(:biasAccelerations, :motionSubspaces, :crbInertias)})
    dynamics_bias!(out.dynamicsBias, out.accelerations, out.jointWrenches, state, externalWrenches, false)
    @inbounds copy!(out.biasedTorques, out.dynamicsBias)
    sub!(out.biasedTorques, torques, out.dynamicsBias)
    mass_matrix!(out.massMatrix, state, false)
    joint_accelerations!(out.v̇, out.massMatrixInversionCache, out.massMatrix, out.biasedTorques)
    nothing
end

# Convenience function that takes a Vector argument for the state stacked as [q; v]
# and returns a Vector, for use with standard ODE integrators.
function dynamics!{T, X, M, Tau, W}(ẋ::StridedVector{X},
        result::DynamicsResult{T}, state::MechanismState{X, M}, stateVec::AbstractVector{X},
        torques::AbstractVector{Tau} = NullVector{T}(num_velocities(state)),
        externalWrenches::Associative{RigidBody{M}, Wrench{W}} = NullDict{RigidBody{M}, Wrench{T}}())
    set!(state, stateVec)
    nq = num_positions(state)
    nv = num_velocities(state)
    q̇ = view(ẋ, 1 : nq) # allocates
    v̇ = view(ẋ, nq + 1 : nq + nv) # allocates
    configuration_derivative!(q̇, state)
    dynamics!(result, state, torques, externalWrenches)
    copy!(v̇, result.v̇)
    ẋ
end
