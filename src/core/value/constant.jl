export null, isnull, all_ones

null(typ::LLVMType) = Value(API.LLVMConstNull(typ))

all_ones(typ::LLVMType) = Value(API.LLVMConstAllOnes(typ))

isnull(val::Value) = convert(Core.Bool, API.LLVMIsNull(val))


abstract type Constant <: User end

unsafe_destroy!(constant::Constant) = API.LLVMDestroyConstant(constant)

# forward declarations
@checked mutable struct Module
    ref::API.LLVMModuleRef
end
abstract type Instruction <: User end


## data

export ConstantData, PointerNull, UndefValue, ConstantInt, ConstantFP

abstract type ConstantData <: Constant end


@checked struct PointerNull <: ConstantData
    ref::API.LLVMValueRef
end
register(PointerNull, API.LLVMConstantPointerNullValueKind)

PointerNull(typ::PointerType) = PointerNull(API.LLVMConstPointerNull(typ))


@checked struct UndefValue <: ConstantData
    ref::API.LLVMValueRef
end
register(UndefValue, API.LLVMUndefValueValueKind)

UndefValue(typ::LLVMType) = UndefValue(API.LLVMGetUndef(typ))


@checked struct ConstantInt <: ConstantData
    ref::API.LLVMValueRef
end
register(ConstantInt, API.LLVMConstantIntValueKind)

# NOTE: fixed set for dispatch, also because we can't rely on sizeof(T)==width(T)
const WideInteger = Union{Int64, UInt64}
ConstantInt(typ::IntegerType, val::WideInteger, signed=false) =
    ConstantInt(API.LLVMConstInt(typ, reinterpret(Culonglong, val),
                convert(Bool, signed)))
const SmallInteger = Union{Core.Bool, Int8, Int16, Int32, UInt8, UInt16, UInt32}
ConstantInt(typ::IntegerType, val::SmallInteger, signed=false) =
    ConstantInt(typ, convert(Int64, val), signed)

function ConstantInt(typ::IntegerType, val::Integer, signed=false)
    valbits = ceil(Int, log2(abs(val))) + 1 # FIXME: doesn't work for val=0
    numwords = ceil(Int, valbits / 64)
    words = Vector{Culonglong}(undef, numwords)
    for i in 1:numwords
        words[i] = (val >> 64(i-1)) % Culonglong
    end
    return ConstantInt(API.LLVMConstIntOfArbitraryPrecision(typ, numwords, words))
end

# NOTE: fixed set where sizeof(T) does match the numerical width
const SizeableInteger = Union{Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128}
function ConstantInt(val::T; ctx::Context) where T<:SizeableInteger
    typ = IntType(sizeof(T)*8; ctx)
    return ConstantInt(typ, val, T<:Signed)
end

# Booleans are encoded with a single bit, so we can't use sizeof
ConstantInt(val::Core.Bool; ctx::Context) = ConstantInt(Int1Type(ctx), val ? 1 : 0)

Base.convert(::Type{T}, val::ConstantInt) where {T<:Unsigned} =
    convert(T, API.LLVMConstIntGetZExtValue(val))

Base.convert(::Type{T}, val::ConstantInt) where {T<:Signed} =
    convert(T, API.LLVMConstIntGetSExtValue(val))

# Booleans aren't Signed or Unsigned
Base.convert(::Type{Core.Bool}, val::ConstantInt) = convert(Int, val) != 0


@checked struct ConstantFP <: ConstantData
    ref::API.LLVMValueRef
end
register(ConstantFP, API.LLVMConstantFPValueKind)

ConstantFP(typ::FloatingPointType, val::Real) =
    ConstantFP(API.LLVMConstReal(typ, Cdouble(val)))

ConstantFP(val::Float16; ctx::Context) =
    ConstantFP(HalfType(ctx), val)
ConstantFP(val::Float32; ctx::Context) =
    ConstantFP(FloatType(ctx), val)
ConstantFP(val::Float64; ctx::Context) =
    ConstantFP(DoubleType(ctx), val)

Base.convert(::Type{T}, val::ConstantFP) where {T<:AbstractFloat} =
    convert(T, API.LLVMConstRealGetDouble(val, Ref{API.LLVMBool}()))


# sequential

export ConstantDataSequential, ConstantDataArray, ConstantDataVector

abstract type ConstantDataSequential <: Constant end

@checked struct ConstantDataArray <: ConstantDataSequential
    ref::API.LLVMValueRef
end
register(ConstantDataArray, API.LLVMConstantDataArrayValueKind)

@checked struct ConstantDataVector <: ConstantDataSequential
    ref::API.LLVMValueRef
end
register(ConstantDataVector, API.LLVMConstantDataVectorValueKind)


# aggregate zero

export ConstantAggregateZero

@checked struct ConstantAggregateZero <: ConstantData
    ref::API.LLVMValueRef
end
register(ConstantAggregateZero, API.LLVMConstantAggregateZeroValueKind)

# array interface
# FIXME: can we reuse the ::ConstantArray functionality with ConstantAggregateZero values?
#        probably works fine if we just get rid of the refcheck
Base.eltype(caz::ConstantAggregateZero) = llvmeltype(caz)
Base.size(caz::ConstantAggregateZero) = (0,)
Base.length(caz::ConstantAggregateZero) = 0
Base.axes(caz::ConstantAggregateZero) = (Base.OneTo(0),)
Base.collect(caz::ConstantAggregateZero) = Value[]


## regular aggregate

export ConstantAggregate

abstract type ConstantAggregate <: Constant end

# arrays

export ConstantArray

@checked struct ConstantArray <: ConstantAggregate
    ref::API.LLVMValueRef
end
register(ConstantArray, API.LLVMConstantArrayValueKind)
register(ConstantArray, API.LLVMConstantDataArrayValueKind)

ConstantArrayOrAggregateZero(value) = Value(value)::Union{ConstantArray,ConstantAggregateZero}

# generic constructor taking an array of constants
function ConstantArray(typ::LLVMType, data::AbstractArray{T,N}=T[]) where {T<:Constant,N}
    @assert all(x->x==typ, llvmtype.(data))

    if N == 1
        return ConstantArrayOrAggregateZero(API.LLVMConstArray(typ, Array(data), length(data)))
    end

    ca_vec = map(x->ConstantArray(typ, x), eachslice(data, dims=1))
    ca_typ = llvmtype(first(ca_vec))

    return ConstantArray(API.LLVMConstArray(ca_typ, ca_vec, length(ca_vec)))
end

# shorthands with arrays of plain Julia data
# FIXME: duplicates the ConstantInt/ConstantFP conversion rules
# XXX: X[X(...)] instead of X.(...) because of empty-container inference
ConstantArray(data::AbstractArray{T,N}; ctx::Context) where {T<:Integer,N} =
    ConstantArray(IntType(sizeof(T)*8; ctx), ConstantInt[ConstantInt(x; ctx) for x in data])
ConstantArray(data::AbstractArray{Core.Bool,N}; ctx::Context) where {N} =
    ConstantArray(Int1Type(ctx), ConstantInt[ConstantInt(x; ctx) for x in data])
ConstantArray(data::AbstractArray{Float16,N}; ctx::Context) where {N} =
    ConstantArray(HalfType(ctx), ConstantFP[ConstantFP(x; ctx) for x in data])
ConstantArray(data::AbstractArray{Float32,N}; ctx::Context) where {N} =
    ConstantArray(FloatType(ctx), ConstantFP[ConstantFP(x; ctx) for x in data])
ConstantArray(data::AbstractArray{Float64,N}; ctx::Context) where {N} =
    ConstantArray(DoubleType(ctx), ConstantFP[ConstantFP(x; ctx) for x in data])

# convert back to known array types
function Base.collect(ca::ConstantArray)
    constants = Array{Value}(undef, size(ca))
    for I in CartesianIndices(size(ca))
        @inbounds constants[I] = ca[Tuple(I)...]
    end
    return constants
end

# array interface
Base.eltype(ca::ConstantArray) = llvmeltype(ca)
function Base.size(ca::ConstantArray)
    dims = Int[]
    typ = llvmtype(ca)
    while typ isa ArrayType
        push!(dims, length(typ))
        typ = eltype(typ)
    end
    return Tuple(dims)
end
Base.length(ca::ConstantArray) = prod(size(ca))
Base.axes(ca::ConstantArray) = Base.OneTo.(size(ca))

function Base.getindex(ca::ConstantArray, idx::Integer...)
    # multidimensional arrays are represented by arrays of arrays,
    # which we need to 'peel back' by looking at the operand sets.
    # for the final dimension, we use LLVMGetElementAsConstant
    @boundscheck Base.checkbounds_indices(Base.Bool, axes(ca), idx) ||
        throw(BoundsError(ca, idx))
    I = CartesianIndices(size(ca))[idx...]
    for i in Tuple(I)
        if isempty(operands(ca))
            ca = LLVM.Value(API.LLVMGetElementAsConstant(ca, i-1))
        else
            ca = (Base.@_propagate_inbounds_meta; operands(ca)[i])
        end
    end
    return ca
end

# structs

export ConstantStruct

@checked struct ConstantStruct <: ConstantAggregate
    ref::API.LLVMValueRef
end
register(ConstantStruct, API.LLVMConstantStructValueKind)

ConstantStructOrAggregateZero(value) = Value(value)::Union{ConstantStruct,ConstantAggregateZero}

# anonymous
ConstantStruct(values::Vector{<:Constant}; ctx::Context, packed::Core.Bool=false) =
    ConstantStructOrAggregateZero(API.LLVMConstStructInContext(ctx, values, length(values), convert(Bool, packed)))

# named
ConstantStruct(typ::StructType, values::Vector{<:Constant}) =
    ConstantStructOrAggregateZero(API.LLVMConstNamedStruct(typ, values, length(values)))

# create a ConstantStruct from a Julia object
function ConstantStruct(value::T, name=String(nameof(T)); ctx::Context,
                        anonymous::Core.Bool=false, packed::Core.Bool=false) where {T}
    isbitstype(T) || throw(ArgumentError("Can only create a ConstantStruct from an isbits struct"))
    isprimitivetype(T) && throw(ArgumentError("Cannot create a ConstantStruct from a primitive value"))

    constants = Vector{Constant}()
    for fieldname in fieldnames(T)
        field = getfield(value, fieldname)

        if isa(field, Integer)
            push!(constants, ConstantInt(field; ctx))
        elseif isa(field, AbstractFloat)
            push!(constants, ConstantFP(field; ctx))
        else # TODO: nested structs?
            throw(ArgumentError("only structs with boolean, integer and floating point fields are allowed"))
        end
    end

    if anonymous
        ConstantStruct(constants; ctx, packed)
    elseif haskey(types(ctx), name)
        typ = types(ctx)[name]
        if collect(elements(typ)) != llvmtype.(constants)
            throw(ArgumentError("Cannot create struct $name {$(join(llvmtype.(constants), ", "))} as it is already defined in this context as {$(join(elements(typ), ", "))}."))
        end
        ConstantStruct(typ, constants)
    else
        typ = StructType(name; ctx)
        elements!(typ, llvmtype.(constants))
        ConstantStruct(typ, constants)
    end
end

# vectors

export ConstantVector

@checked struct ConstantVector <: ConstantAggregate
    ref::API.LLVMValueRef
end
register(ConstantVector, API.LLVMConstantVectorValueKind)


## constant expressions

export ConstantExpr,

       const_neg, const_nswneg, const_nuwneg, const_fneg, const_not, const_add,
       const_nswadd, const_nuwadd, const_fadd, const_sub, const_nswsub, const_nuwsub,
       const_fsub, const_mul, const_nswmul, const_nuwmul, const_fmul, const_udiv,
       const_sdiv, const_fdiv, const_urem, const_srem, const_frem, const_and, const_or,
       const_xor, const_icmp, const_fcmp, const_shl, const_lshr, const_ashr, const_gep,
       const_inbounds_gep, const_trunc, const_sext, const_zext, const_fptrunc, const_fpext,
       const_uitofp, const_sitofp, const_fptoui, const_fptosi, const_ptrtoint,
       const_inttoptr, const_bitcast, const_addrspacecast, const_zextorbitcast,
       const_sextorbitcast, const_truncorbitcast, const_pointercast, const_intcast,
       const_fpcast, const_select, const_extractelement, const_insertelement,
       const_shufflevector, const_extractvalue, const_insertvalue

@checked struct ConstantExpr <: Constant
    ref::API.LLVMValueRef
end
register(ConstantExpr, API.LLVMConstantExprValueKind)

opcode(ce::ConstantExpr) = API.LLVMGetConstOpcode(ce)

const_neg(val::Constant) =
    Value(API.LLVMConstNeg(val))

const_nswneg(val::Constant) =
    Value(API.LLVMConstNSWNeg(val))

const_nuwneg(val::Constant) =
    Value(API.LLVMConstNUWNeg(val))

const_fneg(val::Constant) =
    Value(API.LLVMConstFNeg(val))

const_not(val::Constant) =
    Value(API.LLVMConstNot(val))

const_add(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstAdd(lhs, rhs))

const_nswadd(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNSWAdd(lhs, rhs))

const_nuwadd(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNUWAdd(lhs, rhs))

const_fadd(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFAdd(lhs, rhs))

const_sub(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstSub(lhs, rhs))

const_nswsub(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNSWSub(lhs, rhs))

const_nuwsub(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNUWSub(lhs, rhs))

const_fsub(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFSub(lhs, rhs))

const_mul(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstMul(lhs, rhs))

const_nswmul(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNSWMul(lhs, rhs))

const_nuwmul(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstNUWMul(lhs, rhs))

const_fmul(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFMul(lhs, rhs))

const_udiv(lhs::Constant, rhs::Constant; exact::Base.Bool=false) =
    Value(exact ? API.LLVMConstExactUDiv(lhs, rhs) : API.LLVMConstUDiv(lhs, rhs))

const_sdiv(lhs::Constant, rhs::Constant; exact::Base.Bool=false) =
    Value(exact ? API.LLVMConstExactSDiv(lhs, rhs) : API.LLVMConstSDiv(lhs, rhs))

const_fdiv(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFDiv(lhs, rhs))

const_urem(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstURem(lhs, rhs))

const_srem(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstSRem(lhs, rhs))

const_frem(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFRem(lhs, rhs))

const_and(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstAnd(lhs, rhs))

const_or(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstOr(lhs, rhs))

const_xor(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstXor(lhs, rhs))

const_icmp(Predicate::API.LLVMIntPredicate, lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstICmp(Predicate, lhs, rhs))

const_fcmp(Predicate::API.LLVMRealPredicate, lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstFCmp(Predicate, lhs, rhs))

const_shl(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstShl(lhs, rhs))

const_lshr(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstLShr(lhs, rhs))

const_ashr(lhs::Constant, rhs::Constant) =
    Value(API.LLVMConstAShr(lhs, rhs))

const_gep(val::Constant, Indices::Vector{<:Constant}) =
   Value(API.LLVMConstGEP(val, Indices, length(Indices)))

const_inbounds_gep(val::Constant, Indices::Vector{<:Constant}) =
   Value(API.LLVMConstInBoundsGEP(val, Indices, length(indices)))

const_trunc(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstTrunc(val, ToType))

const_sext(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstSExt(val, ToType))

const_zext(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstZExt(val, ToType))

const_fptrunc(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstFPTrunc(val, ToType))

const_fpext(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstFPExt(val, ToType))

const_uitofp(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstUIToFP(val, ToType))

const_sitofp(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstSIToFP(val, ToType))

const_fptoui(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstFPToUI(val, ToType))

const_fptosi(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstFPToSI(val, ToType))

const_ptrtoint(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstPtrToInt(val, ToType))

const_inttoptr(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstIntToPtr(val, ToType))

const_bitcast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstBitCast(val, ToType))

const_addrspacecast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstAddrSpaceCast(val, ToType))

const_zextorbitcast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstZExtOrBitCast(val, ToType))

const_sextorbitcast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstSExtOrBitCast(val, ToType))

const_truncorbitcast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstTruncOrBitCast(val, ToType))

const_pointercast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstPointerCast(val, ToType))

const_intcast(val::Constant, ToType::LLVMType, isSigned::Base.Bool) =
    Value(API.LLVMConstIntCast(val, ToType, isSigned))

const_fpcast(val::Constant, ToType::LLVMType) =
    Value(API.LLVMConstFPCast(val, ToType))

const_select(cond::Constant, if_true::Value, if_false::Value) =
    Value(API.LLVMConstSelect(cond, if_true, if_false))

const_extractelement(vector::Constant, index::Constant) =
    Value(API.LLVMConstExtractElement(vector ,index))

const_insertelement(vector::Constant, element::Value, index::Constant) =
    Value(API.LLVMConstInsertElement(vector ,element, index))

const_shufflevector(vector1::Constant, vector2::Constant, mask::Constant) =
    Value(API.LLVMConstShuffleVector(vector1, vector2, mask))

const_extractvalue(agg::Constant, Idx::Vector{<:Integer}) =
   Value(API.LLVMConstExtractValue(agg, Idx, length(Idx)))

const_insertvalue(agg::Constant, element::Constant, Idx::Vector{<:Integer}) =
   Value(API.LLVMConstInsertValue(agg, element, Idx, length(Idx)))

# TODO: alignof, sizeof, block_address


## inline assembly

export InlineAsm

@checked struct InlineAsm <: Constant
    ref::API.LLVMValueRef
end
register(InlineAsm, API.LLVMInlineAsmValueKind)

InlineAsm(typ::FunctionType, asm::String, constraints::String,
          side_effects::Core.Bool, align_stack::Core.Bool=false) =
    InlineAsm(API.LLVMConstInlineAsm(typ, asm, constraints,
                                     convert(Bool, side_effects),
                                     convert(Bool, align_stack)))


## global values

abstract type GlobalValue <: Constant end

export GlobalValue,
       isdeclaration,
       linkage, linkage!,
       section, section!,
       visibility, visibility!,
       dllstorage, dllstorage!,
       unnamed_addr, unnamed_addr!,
       alignment, alignment!

parent(val::GlobalValue) = Module(API.LLVMGetGlobalParent(val))

isdeclaration(val::GlobalValue) = convert(Core.Bool, API.LLVMIsDeclaration(val))

linkage(val::GlobalValue) = API.LLVMGetLinkage(val)
linkage!(val::GlobalValue, linkage::API.LLVMLinkage) =
    API.LLVMSetLinkage(val, linkage)

function section(val::GlobalValue)
  #=
  The following started to fail on LLVM 4.0:
    Context() do ctx
      LLVM.Module("SomeModule"; ctx) do mod
        st = LLVM.StructType("SomeType"; ctx)
        ft = LLVM.FunctionType(st, [st])
        fn = LLVM.Function(mod, "SomeFunction", ft)
        section(fn) == ""
      end
      end
  =#
  section_ptr = API.LLVMGetSection(val)
  return section_ptr != C_NULL ? unsafe_string(section_ptr) : ""
end
section!(val::GlobalValue, sec::String) = API.LLVMSetSection(val, sec)

visibility(val::GlobalValue) = API.LLVMGetVisibility(val)
visibility!(val::GlobalValue, viz::API.LLVMVisibility) =
    API.LLVMSetVisibility(val, viz)

dllstorage(val::GlobalValue) = API.LLVMGetDLLStorageClass(val)
dllstorage!(val::GlobalValue, storage::API.LLVMDLLStorageClass) =
    API.LLVMSetDLLStorageClass(val, storage)

unnamed_addr(val::GlobalValue) = convert(Core.Bool, API.LLVMHasUnnamedAddr(val))
unnamed_addr!(val::GlobalValue, flag::Core.Bool) =
    API.LLVMSetUnnamedAddr(val, convert(Bool, flag))

const AlignedValue = Union{GlobalValue,Instruction}   # load, store, alloca
alignment(val::AlignedValue) = API.LLVMGetAlignment(val)
alignment!(val::AlignedValue, bytes::Integer) = API.LLVMSetAlignment(val, bytes)


## global variables

abstract type GlobalObject <: GlobalValue end

export GlobalVariable, unsafe_delete!,
       initializer, initializer!,
       isthreadlocal, threadlocal!,
       threadlocalmode, threadlocalmode!,
       isconstant, constant!,
       isextinit, extinit!

@checked struct GlobalVariable <: GlobalObject
    ref::API.LLVMValueRef
end
register(GlobalVariable, API.LLVMGlobalVariableValueKind)

GlobalVariable(mod::Module, typ::LLVMType, name::String) =
    GlobalVariable(API.LLVMAddGlobal(mod, typ, name))

GlobalVariable(mod::Module, typ::LLVMType, name::String, addrspace::Integer) =
    GlobalVariable(API.LLVMAddGlobalInAddressSpace(mod, typ,
                                                   name, addrspace))

unsafe_delete!(::Module, gv::GlobalVariable) = API.LLVMDeleteGlobal(gv)

function initializer(gv::GlobalVariable)
    init = API.LLVMGetInitializer(gv)
    init == C_NULL ? nothing : Value(init)
end
initializer!(gv::GlobalVariable, val::Constant) =
  API.LLVMExtraSetInitializer(gv, val)
initializer!(gv::GlobalVariable, ::Nothing) =
  API.LLVMExtraSetInitializer(gv, C_NULL)

isthreadlocal(gv::GlobalVariable) = convert(Core.Bool, API.LLVMIsThreadLocal(gv))
threadlocal!(gv::GlobalVariable, bool) =
  API.LLVMSetThreadLocal(gv, convert(Bool, bool))

isconstant(gv::GlobalVariable) = convert(Core.Bool, API.LLVMIsGlobalConstant(gv))
constant!(gv::GlobalVariable, bool) =
  API.LLVMSetGlobalConstant(gv, convert(Bool, bool))

threadlocalmode(gv::GlobalVariable) = API.LLVMGetThreadLocalMode(gv)
threadlocalmode!(gv::GlobalVariable, mode) =
  API.LLVMSetThreadLocalMode(gv, mode)

isextinit(gv::GlobalVariable) =
  convert(Core.Bool, API.LLVMIsExternallyInitialized(gv))
extinit!(gv::GlobalVariable, bool) =
  API.LLVMSetExternallyInitialized(gv, convert(Bool, bool))
