################
# AbstractTape #
################

@compat abstract type AbstractTape end

Base.show(io::IO, t::AbstractTape) = print(io, typeof(t).name, "(", t.func, ")")

# Define a few different T<:AbstractTape types. All these types share the same structure,
# but feature different constructors and dispatch restrictions in downstream code.
for T in (:GradientTape, :JacobianTape, :HessianTape)
    _T = Symbol(string("_", T))
    @eval begin
        immutable $(T){F,I,O} <: AbstractTape
            func::F
            input::I
            output::O
            tape::InstructionTape
            # disable default outer constructor
            (::Type{$(T){F,I,O}}){F,I,O}(func, input, output, tape) = new{F,I,O}(func, input, output, tape)
        end

        # "private" convienence constructor
        $(_T){F,I,O}(func::F, input::I, output::O, tape::InstructionTape) = $(T){F,I,O}(func, input, output, tape)

        Base.length(t::$T) = length(t.tape)

        @inline func_hook(t::$T) = t.func

        @inline input_hook(t::$T) = t.input

        @inline output_hook(t::$T) = t.output

        forward_pass!(t::$T) = forward_pass!(t.tape)

        reverse_pass!(t::$T) = reverse_pass!(t.tape)
    end
end

function seeded_forward_pass!(t::AbstractTape, input)
    value!(input_hook(t), input)
    forward_pass!(t)
    return nothing
end

function seeded_reverse_pass!(result, t::AbstractTape)
    seeded_reverse_pass!(result, output_hook(t), input_hook(t), t)
    return result
end

################
# CompiledTape #
################

immutable CompiledTape{S,T<:AbstractTape} <: AbstractTape
    tape::T
    forward_exec::Vector{FunctionWrapper{Void, Tuple{}}}
    reverse_exec::Vector{FunctionWrapper{Void, Tuple{}}}
end

immutable ForwardExecutor{I <: AbstractInstruction}
    instruction::I
end

@inline (e::ForwardExecutor)() = forward_exec!(e.instruction)

immutable ReverseExecutor{I <: AbstractInstruction}
    instruction::I
end

@inline (e::ReverseExecutor)() = reverse_exec!(e.instruction)

(::Type{CompiledTape{S}}){S,T<:AbstractTape}(t::T) = CompiledTape{S,T}(
    t, 
    [FunctionWrapper{Void, Tuple{}}(ForwardExecutor(instruction)) for instruction in t.tape],
    [FunctionWrapper{Void, Tuple{}}(ReverseExecutor(t.tape[i])) for i in length(t.tape):-1:1]
    )

Base.show{S}(io::IO, t::CompiledTape{S}) = print(io, typeof(t).name, "{$S}($(t.tape.func))")

@compat const CompiledGradient{S,T<:GradientTape} = CompiledTape{S,T}
@compat const CompiledJacobian{S,T<:JacobianTape} = CompiledTape{S,T}
@compat const CompiledHessian{S,T<:HessianTape}   = CompiledTape{S,T}

Base.length(ct::CompiledTape) = length(ct.tape)

@inline func_hook(ct::CompiledTape) = func_hook(ct.tape)

@inline input_hook(ct::CompiledTape) = input_hook(ct.tape)

@inline output_hook(ct::CompiledTape) = output_hook(ct.tape)

function forward_pass!(compiled_tape::CompiledTape)
    for wrapper in compiled_tape.forward_exec
        wrapper()
    end
    nothing
end

function reverse_pass!(compiled_tape::CompiledTape)
    for wrapper in compiled_tape.reverse_exec
        wrapper()
    end
    nothing
end

"""
    ReverseDiff.compile(t::AbstractTape)

Return a fully compiled representation of `t` of type `CompiledTape`. This object can be
passed to any API methods that accept `t` (e.g. `gradient!(result, t, input)`).

In many cases, compiling `t` can significantly speed up execution time. Note that the longer
the tape, the more time compilation may take. Very long tapes (i.e. when `length(t)` is on
the order of 10000 elements) can take a very long time to compile.
"""
function compile(t::AbstractTape)
    ct = CompiledTape{gensym()}(t)
    return ct
end

function compile_gradient(f, args...)
    Base.depwarn("`ReverseDiff.compile_gradient(f, args...)` is deprecated" *
                 ", use `ReverseDiff.compile(ReverseDiff.GradientTape(f, args...))`"*
                 "instead. Then, you can execute the returned CompiledTape `t` by calling"*
                 " `ReverseDiff.gradient!(result, t, input)`.",
                 :compile_gradient)
    tape = compile(GradientTape(f, args...))
    return (result, input) -> gradient!(result, tape, input)
end

function compile_jacobian(f, args...)
    Base.depwarn("`ReverseDiff.compile_jacobian(f, args...)` is deprecated" *
                 ", use `ReverseDiff.compile(ReverseDiff.JacobianTape(f, args...))`"*
                 "instead. Then, you can execute the returned CompiledTape `t` by calling"*
                 " `ReverseDiff.jacobian!(result, t, input)`.",
                 :compile_jacobian)
    tape = compile(JacobianTape(f, args...))
    return (result, input) -> jacobian!(result, tape, input)
end

function compile_hessian(f, args...)
    Base.depwarn("`ReverseDiff.compile_hessian(f, args...)` is deprecated" *
                 ", use `ReverseDiff.compile(ReverseDiff.HessianTape(f, args...))`"*
                 "instead. Then, you can execute the returned CompiledTape `t` by calling"*
                 " `ReverseDiff.hessian!(result, t, input)`.",
                 :compile_hessian)
    tape = compile(HessianTape(f, args...))
    return (result, input) -> hessian!(result, tape, input)
end

################
# GradientTape #
################

"""
    ReverseDiff.GradientTape(f, input, cfg::GradientConfig = GradientConfig(input))

Return a `GradientTape` instance containing a pre-recorded execution trace of `f` at the
given `input`.

This `GradientTape` can then be passed to `ReverseDiff.gradient!` to take gradients of the
execution trace with new `input` values. Note that these new values must have the same
element type and shape as `input`.

See `ReverseDiff.gradient` for a description of acceptable types for `input`.
"""
function GradientTape(f, input, cfg::GradientConfig = GradientConfig(input))
    track!(cfg.input, input)
    tracked_ouput = f(cfg.input)
    return _GradientTape(f, cfg.input, tracked_ouput, cfg.tape)
end

function GradientTape(f, input::Tuple, cfg::GradientConfig = GradientConfig(input))
    for i in eachindex(cfg.input)
        track!(cfg.input[i], input[i])
    end
    tracked_output = f(cfg.input...)
    return _GradientTape(f, cfg.input, tracked_output, cfg.tape)
end

################
# JacobianTape #
################

"""
    ReverseDiff.JacobianTape(f, input, cfg::JacobianConfig = JacobianConfig(input))

Return a `JacobianTape` instance containing a pre-recorded execution trace of
`f` at the given `input`.

This `JacobianTape` can then be passed to `ReverseDiff.jacobian!` to take Jacobians of the
execution trace with new `input` values. Note that these new values must have the same
element type and shape as `input`.

See `ReverseDiff.jacobian` for a description of acceptable types for `input`.
"""
function JacobianTape(f, input, cfg::JacobianConfig = JacobianConfig(input))
    track!(cfg.input, input)
    tracked_ouput = f(cfg.input)
    return _JacobianTape(f, cfg.input, tracked_ouput, cfg.tape)
end

function JacobianTape(f, input::Tuple, cfg::JacobianConfig = JacobianConfig(input))
    for i in eachindex(cfg.input)
        track!(cfg.input[i], input[i])
    end
    tracked_output = f(cfg.input...)
    return _JacobianTape(f, cfg.input, tracked_output, cfg.tape)
end

"""
    ReverseDiff.JacobianTape(f!, output, input, cfg::JacobianConfig = JacobianConfig(output, input))

Return a `JacobianTape` instance containing a pre-recorded execution trace of
`f` at the given `output` and `input`.

This `JacobianTape` can then be passed to `ReverseDiff.jacobian!` to take Jacobians of the
execution trace with new `input` values. Note that these new values must have the same
element type and shape as `input`.

See `ReverseDiff.jacobian` for a description of acceptable types for `input`.
"""
function JacobianTape(f!, output, input, cfg::JacobianConfig = JacobianConfig(output, input))
    track!(cfg.output, output, cfg.tape)
    track!(cfg.input, input)
    f!(cfg.output, cfg.input)
    return _JacobianTape(f!, cfg.input, cfg.output, cfg.tape)
end

function JacobianTape(f!, output, input::Tuple, cfg::JacobianConfig = JacobianConfig(output, input))
    track!(cfg.output, output, cfg.tape)
    for i in eachindex(input)
        track!(cfg.input[i], input[i])
    end
    f!(cfg.output, cfg.input...)
    return _JacobianTape(f!, cfg.input, cfg.output, cfg.tape)
end

###############
# HessianTape #
###############

"""
    ReverseDiff.HessianTape(f, input, cfg::HessianConfig = HessianConfig(input))

Return a `HessianTape` instance containing a pre-recorded execution trace of
`f` at the given `input`.

This `HessianTape` can then be passed to `ReverseDiff.hessian!` to take Hessians of the
execution trace with new `input` values. Note that these new values must have the same
element type and shape as `input`.

See `ReverseDiff.hessian` for a description of acceptable types for `input`.
"""
function HessianTape(f, input, cfg::HessianConfig = HessianConfig(input))
    gcfg = cfg.gradient_config
    jcfg = cfg.jacobian_config
    ht = _HessianTape(f, jcfg.input, similar(deriv(gcfg.input)), jcfg.tape)
    track!(ht.input, input)
    gt = GradientTape(f, ht.input, gcfg)
    seeded_reverse_pass!(ht.output, gt.output, gt.input, gt.tape)
    return ht
end
