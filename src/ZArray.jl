module ZArrays
import JSON
import ..Storage: ZStorage, getattrs, DiskStorage, zname, getchunk, MemStorage
import ..Compressors: Compressor, read_uncompress!, compressortypes, getCompressor,
  write_compress, NoCompressor, areltype
export ZArray, zzeros

ztype2jltype = Dict(
  "<f4"=>Float32,
  "<f8"=>Float64,
  "<i4"=>Int32,
  "<i8"=>Int64
)
zshape2shape(x) = ntuple(i->x[i],length(x))
struct C end
struct F end
const StorageOrder = Union{C,F}

zorder2order(x) = x=="C" ? C : x=="F" ? F : error("Unknown storage order")


getfillval(target::Type{T},t::String) where T<: Number =parse(T,t)
getfillval(target::Type{T},t::Union{T,Nothing}) where T = t

struct ZArray{T,N,C<:Compressor,S<:ZStorage}
    folder::S
    size::NTuple{N,Int} # Stored in Julia order
    order::StorageOrder
    chunks::NTuple{N,Int} # Stored in Julia order
    fillval::Union{T,Nothing}
    compressor::C
    attrs::Dict
    writeable::Bool
end
Base.eltype(::ZArray{T}) where T =  T
Base.ndims(::ZArray{<:Any,N}) where N = N
Base.size(z::ZArray)=z.size
Base.size(z::ZArray,i)=s.size[i]
Base.length(z::ZArray)=prod(z.size)
zname(z::ZArray)=zname(z.folder)

function ZArray(folder::String,mode="r")
    files = readdir(folder)
    @assert in(".zarray",files)
    arrayinfo = JSON.parsefile(joinpath(folder,".zarray"))
    dt = ztype2jltype[arrayinfo["dtype"]]
    shape = zshape2shape(arrayinfo["shape"])
    order = zorder2order(arrayinfo["order"])
    arrayinfo["zarr_format"] != 2 && error("Expecting Zarr format version 2")
    chunks = zshape2shape(arrayinfo["chunks"])
    fillval = getfillval(dt,arrayinfo["fill_value"])
    compdict = arrayinfo["compressor"]
    compressor = getCompressor(compressortypes[compdict["id"]],compdict)
    attrs = getattrs(DiskStorage(folder))
    writeable= mode=="w"
    ZArray{dt,length(shape),typeof(compressor),DiskStorage}(DiskStorage(folder),reverse(shape),order(),reverse(chunks),fillval,compressor,attrs,writeable)
end
convert_index(i,s::Int)=i:i
convert_index(i::AbstractUnitRange,s::Int)=i
convert_index(::Colon,s::Int)=Base.OneTo(s)
trans_ind(r::AbstractUnitRange,bs) = ((first(r)-1)÷bs):((last(r)-1)÷bs)
trans_ind(r::Integer,bs)   = (r-1)÷bs
function inds_in_block(r::CartesianIndices{N}, #Outer Array indices to read
        bI::CartesianIndex{N}, #Index of the current block to read
        blockAll::CartesianIndices{N}, # All blocks to read
        c::NTuple{N,Int}, # Chunks
        enumI::CartesianIndices{N}, # Idices of all block to read
        offsfirst::NTuple{N,Int} # Offset of the first block to read
        ) where N

    sI=size(enumI)
    map(r.indices,bI.I,blockAll.indices,c,enumI.indices,sI,offsfirst) do iouter, iblock, ablock, chunk, enu , senu, o0

        if iblock==first(ablock)
            i1=mod1(first(iouter),chunk)
            io1=1
        else
            i1=1
            io1=o0+(iblock-first(ablock)-1)*chunk+1
        end
        if iblock==last(ablock)
            i2=mod1(last(iouter),chunk)
            io2=length(iouter)
        else
            i2=chunk
            io2=(iblock-first(ablock))*chunk+o0
        end
        i1:i2,io1:io2
    end
end

function Base.getindex(z::ZArray{T},i...) where T
  ii=CartesianIndices(map(convert_index,i,size(z)))
  aout=zeros(T,size(ii))
  readblock!(aout,z,ii)
end
function Base.setindex!(z::ZArray,v,i...)
  ii=CartesianIndices(map(convert_index,i,size(z)))
  readblock!(v,z,ii,readmode=false)
end
function readchunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N}) where {T,N}
    length(a)==prod(z.chunks) || throw(DimensionMismatch("Array size does not equal chunk size"))
    curchunk=getchunk(z.folder,i)
    if curchunk==nothing
      fill!(a,z.fillval)
    else
      read_uncompress!(a,curchunk,z.compressor)
    end
    a
end
function writechunk!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N}) where {T,N}
  z.writeable || error("ZArray not in write mode")
  length(a)==prod(z.chunks) || throw(DimensionMismatch("Array size does not equal chunk size"))
  curchunk=getchunk(z.folder,i)
  write_compress(a,curchunk,z.compressor)
  a
end
function readblock!(aout,z::ZArray{<:Any,N},r::CartesianIndices{N};readmode=true) where N
    if !readmode && !z.writeable
      error("Trying to write to read-only ZArray")
    end
    blockr = CartesianIndices(map(trans_ind,r.indices,z.chunks))
    enumI = CartesianIndices(blockr)
    offsfirst = map((a,bs)->mod(first(a)-1,bs)+1,r.indices,z.chunks)
    a = zeros(eltype(z),z.chunks)
    linoutinds = LinearIndices(r)
    for bI in blockr
        readchunk!(a,z,bI+one(bI))
        ii = inds_in_block(r,bI,blockr,z.chunks,enumI,offsfirst)
        i_in_a = CartesianIndices(map(i->i[1],ii))
        i_in_out = CartesianIndices(map(i->i[2],ii))
        if readmode
          aout[i_in_out]=a[i_in_a]
        else
          i_in_out2 = linoutinds[i_in_out]
          a[i_in_a]=aout[i_in_out2]
          writechunk!(a,z,bI+one(bI))
        end
    end
    aout
end

function zzeros(::Type{T},
        dims...;
        path="",
        name="",
        chunks=dims,
        fillval=nothing,
        compressor=NoCompressor(),
        attrs=Dict(),
        writeable=true,
        ) where T
    length(dims) == length(chunks) || throw(DimensionMismatch("Dims must have the same length as chunks"))
    N=length(dims)
    nsubs = map((s,c)->ceil(Int,s/c),dims,chunks)
    et    = areltype(compressor,T)
    if isempty(path)
        isempty(name) && (name="data")
        a=Array{et}(undef,nsubs...)
        for i in eachindex(a)
            a[i]=T[]
        end
        folder=MemStorage(name,a)
    else
      # Assume that we write to disk, no S3 yet
      if isempty(name)
        name = splitdir(path)[2]
      else
        path = joinpath(path,name)
      end
      isdir(path) && error("Directory $path already exists")
      mkpath(path)
      #Generate JSON file

    end
    z=ZArray{T,N,typeof(compressor),typeof(folder)}(folder,dims,F(),chunks,fillval,compressor,attrs,writeable)
    as = zeros(T,chunks...)
    for i in CartesianIndices(a)
        writechunk!(as,z,i)
    end
    z
end


end
