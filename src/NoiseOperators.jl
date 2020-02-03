#=
Functions for constructing noise operators
=#
using SparseArrays
using LinearAlgebra
import SparseArrays.getcolptr
using BlockDiagonals


"""
    σ_j(j, n, direction)

Return a sparse matrix representing the Pauli operator on the ``j``-th of ``n`` spins in the computational basis.

`direction` must be `(:x, :y, :z)`
"""
function σ_j(direction::Symbol, j::Int, n::Int)
    @assert direction ∈ (:x, :y, :z) "Direction must be :x, :y, :z"
    @assert j <= n "j must be less or equal than n"

    sigma = Dict(:x => sparse([0im 1.; 1. 0.] ),
             :y => sparse([0. -1im; 1im 0.]),
             :z => sparse([1. 0im; 0. -1.]))
    if n == 1
        return sigma[direction]
    else
        return kron(
            vcat([SparseMatrixCSC{ComplexF64}(I, 2, 2) for i = j + 1:n],
                [sigma[direction]],
                [SparseMatrixCSC{ComplexF64}(I, 2, 2) for i = 1:j-1])...)
    end
end



"""
    σ(direction, n)

Return a sparse matrix representing the collective noise operator
``\\σ_d = \\sum \\σ^{(d)}_j`` where d is the
`direction` and must be one of `(:x, :y, :z)`

# Examples
```jldoctest
julia> full(σ(:x, 1))
2×2 Array{Complex{Float64},2}:
 0.0+0.0im  0.5+0.0im
 0.5+0.0im  0.0+0.0im
```
"""
function σ(direction::Symbol, n::Int)
    σ = spzeros(2^n, 2^n)
    for i = 1:n
        σ += σ_j(direction, i, n)
    end
    return σ
end

"""
    trace(A)

Return the trace of a vectorized operator A
"""
function trace(A::AbstractArray{T,1}) where T

    N = Int(sqrt(length(A)))
    return tr(reshape(A, (N,N)))
end

"""
    sup_pre(A)

    Superoperator formed from pre-multiplication by operator A.

    Effectively evaluate the Kronecker product I ⊗ A
"""
function sup_pre(A)
    return blkdiag(A, size(A, 1))
end


"""
    sup_post(A)

    Superoperator formed from post-multiplication by operator A†.

    Effectively evaluate the Kronecker product A* ⊗ I
"""
function sup_post(A)
    return kron(conj(A), I + zero(A))
end

"""
    sup_pre_post(A, B)

    Superoperator formed from A * . * B†

    Effectively evaluate the Kronecker product B* ⊗ A
"""
function sup_pre_post(A, B)
    return kron(conj(B), A)
end

"""
    sup_pre_post(A)

    Superoperator formed from A * . * A†

    Effectively evaluate the Kronecker product A* ⊗ A
"""
function sup_pre_post(A)
    return kron(conj(A), A)
end

function blkdiag(X::SparseMatrixCSC{Tv, Ti}, num) where {Tv, Ti<:Integer}
    mX = size(X, 1)
    nX = size(X, 2)
    m = num * size(X, 1)
    n = num * size(X, 2)

    nnzX = nnz(X)
    nnz_res = nnzX * num
    colptr = Vector{Ti}(undef, n+1)
    rowval = Vector{Ti}(undef, nnz_res)
    nzval = repeat(X.nzval, num)

    @inbounds @simd for i = 1 : num
         @simd for j = 1 : nX + 1
            colptr[(i - 1) * nX + j] = X.colptr[j] + (i-1) * nnzX
        end
         @simd for j = 1 : nnzX
            rowval[(i - 1) * nnzX + j] = X.rowval[j] + (i - 1) * (mX)
        end
    end
    colptr[n+1] = num * nnzX + 1
    SparseMatrixCSC(m, n, colptr, rowval, nzval)
end

# function blkdiag!(Sup::SparseMatrixCSC{Tv, Ti}, X::SparseMatrixCSC{Tv, Ti}, num) where {Tv, Ti<:Integer}
#     copy!(Sup.nzval, repeat(X.nzval, num))
#     return Sup
# end

"""
Non-allocating update of the matrix Sup = I ⊗ A.

ATTENTION!!! It assumes the position of the non-zero elements
does not change!
USE WITH CARE!!!!!
"""
function fast_sup_pre!(Sup::SparseMatrixCSC{Tv, Ti}, A::SparseMatrixCSC{Tv, Ti}) where {Tv, Ti<:Integer}
    num = size(A, 1)
    nnzX = nnz(A)
    @inbounds @simd for i = 1 : num
         @simd for j = 1 : nnzX
            Sup.nzval[(i - 1) * nnzX + j] = A.nzval[j]
        end
    end
end

"""
Non-allocating update of the matrix Sup = A' ⊗ I.

ATTENTION!!! It assumes the position of the non-zero elements
does not change!
USE WITH CARE!!!!!
"""
function fast_sup_post!(Sup::SparseMatrixCSC{T1, S1}, A::SparseMatrixCSC{T1,S1}) where {T1, S1}
    n = size(A, 1)
    col = 1

    @inbounds for j = 1 : n
        startA = getcolptr(A)[j]
        stopA = getcolptr(A)[j+1] - 1
        lA = stopA - startA + 1
        for i = 1:n
            ptr_range = Sup.colptr[col]
            col += 1
            for ptrA = startA : stopA
                Sup.nzval[ptr_range] = nonzeros(A)[ptrA]'
                ptr_range += 1
            end
        end
    end
    return Sup
end

"""
Contains the block, row and column indices for efficient application of the superoperator
"""
# TODO: Format using 2 tuples
struct Indices{T}
    br::Array{T, 1}
    bc::Array{T, 1}
    ir::Array{T, 1}
    jr::Array{T, 1}
    ic::Array{T, 1}
    jc::Array{T, 1}
end

"""
    apply_superop!(C::BlockDiagonal, A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal) -> C

Apply the superoperator A (in Liouville form) to the matrix B and store the result in C.

"""
function apply_superop!(C::BlockDiagonal, A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal) where Ti where Tv
    return apply_superop!(C, A, B, get_superop_indices(A, B))
end

""" get_superop_indices(A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal)

Returns the Indices structure for the action of operator A onto the matrix B
"""
function get_superop_indices(A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal) where Ti where Tv

    N = size(B, 1)
    row, col, val = findnz(A)
    bs = first.(blocksizes(B))

    blockindices = cumsum(vcat(1, bs[1:end-1]))

    irow = (row .- 1) .% N .+ 1
    jrow = (row .- 1) .÷ N .+ 1
    ir = similar(irow)
    jr = similar(jrow)

    t1 = sum(Int.(floor.(reshape(irow, :, 1) ./ blockindices[2:end]')) .>= 1, dims=2) .+ 1
    t2 = sum(Int.(floor.(reshape(jrow, :, 1) ./ blockindices[2:end]')) .>= 1, dims=2) .+ 1

    br = t1 .* (t1 .== t2)

    @simd for i = 1:length(irow)
        if br[i] > 0
            ir[i] = irow[i] - blockindices[br[i]] + 1
            jr[i] = jrow[i] - blockindices[br[i]] + 1
        end
    end

    icol = (col .- 1) .% N .+ 1
    jcol = (col .- 1) .÷ N .+ 1

    ic = similar(icol)
    jc = similar(jcol)

    t1 .= sum(Int.(floor.(reshape(icol, :, 1) ./ blockindices[2:end]')) .>= 1, dims=2) .+ 1
    t2 .= sum(Int.(floor.(reshape(jcol, :, 1) ./ blockindices[2:end]')) .>= 1, dims=2) .+ 1

    bc = t1 .* (t1 .== t2)

    @simd for i = 1:length(icol)
        if bc[i] > 0
            ic[i] = icol[i] - blockindices[bc[i]] + 1
            jc[i] = jcol[i] - blockindices[bc[i]] + 1
        end
    end

    return Indices(br[:], bc[:], ir, jr, ic, jc)
end

"""
    apply_superop!(C::BlockDiagonal, A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal, indices::Indices) -> C

Apply the superoperator A (in Liouville form) to the matrix B and store the result in C, using the provided
indices for much faster operation
"""
function apply_superop!(C::BlockDiagonal, A::SparseMatrixCSC{Ti, Tv}, B::BlockDiagonal, indices::Indices{Tv}) where Ti where Tv
        val = nonzeros(A)
        fill!(C, zero(eltype(C)))
        @simd for i = 1 : length(val)
            if indices.bc[i] > 0
                tmp = val[i] * B.blocks[indices.bc[i]][indices.ic[i], indices.jc[i]]
                if tmp != 0.0
                    C.blocks[indices.br[i]][indices.ir[i], indices.jr[i]] += tmp
                end
            end
        end
        return C
    end

import ZChop: zchop!
# Specialize zchop! to BlockDiagonal
function zchop!(A::BlockDiagonal)
   for b in blocks(A)
        zchop!(b)
    end
end

""" nspins(size)

Obtain the number of spins from the size of a matrix in the
Dicke basis
"""
function nspins(size)
    if sqrt(size) == floor(sqrt(size)) # Nspin even
         return 2 * (Int(sqrt(size)) - 1)
     else # Nspin odd
         return -2 + Int(sqrt(1 + 4 * size))
     end
 end

""" blockdiagonal(M; [dense=false])

Converts a matrix into a BlockDiagonal matrix, by default preserving the matrix type (e.g. sparse, dense).
If dense=true, force the blocks to have a dense structure
"""
function blockdiagonal(M::T; dense=false) where T <: AbstractArray
    N = nspins(size(M, 1))

    blocksizes = ContinuousMeasurementFI.block_sizes(N)

    views = Array{T}(undef, length(blocksizes))
    startidx = 1
    for i in 1:length(blocksizes)
        range = startidx:(startidx + blocksizes[i] - 1)
        views[i] = view(M, range, range)
        startidx += blocksizes[i]
    end
    if dense # Force dense blocks
        return BlockDiagonal(Matrix.(views))
    else
        return BlockDiagonal(views)
    end
end