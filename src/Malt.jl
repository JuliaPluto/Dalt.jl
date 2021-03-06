"""
Malt is a  minimal multi-processing package for Julia.

Malt doesn't export anything, use qualified names instead.
Internal functions are marked with a leading underscore,
these functions are not stable.
"""
module Malt

import Base.Meta: quot
import Base: Process, Channel, kill
import Serialization: serialize, deserialize

using Logging
using Sockets

mutable struct Worker
    port::UInt16
    proc::Process
end

"""
    Malt.Worker()

Spawn a new worker process.
"""
function Worker()
    # Spawn process
    cmd = _get_worker_cmd()
    proc = open(cmd, "w+") # TODO: Capture stdio

    # Block until reading the port number of the process
    port_str = readline(proc)
    port = parse(UInt16, port_str)
    Worker(port, proc)
end

function _get_worker_cmd(bin="julia")
    script = @__DIR__() * "/worker.jl"
    # TODO: Project environment
    `$bin $script`
end

## Use tuples instead of structs so the worker doesn't need to load additional modules.

function _new_call_msg(send_result, f, args...; kwargs...)
    (header=:call, body=(f=f, args=args, kwargs=kwargs), send_result=send_result)
end

function _new_do_msg(f, args...; kwargs...)
    (header=:remote_do, body=(f=f, args=args, kwargs=kwargs))
end

function _new_channel_msg(expr)
    (header=:channel, body=expr)
end

function _send_msg(port::UInt16, msg)
    socket = connect(port)
    serialize(socket, msg)
    return socket
end

function _promise(socket)
    @async begin
        response = deserialize(socket)
        close(socket)
        # FIXME:
        # `response.result` can be the result of a computation, or an Exception.
        # If it's an exception defined in Base, we could rethrow it here,
        # but what should be done if it's an exception that's NOT defined in Base???
        #
        # Also, these exceptions are wrapped in a `TaskFailedException`,
        # which seems kind of ugly. How to unwrap them?
        response.result
    end
end

function _send(w::Worker, msg)::Task
    _promise(_send_msg(w.port, msg))
end


## Define 4 remote calls:
## remotecall:       Async,    returns value
## remote_do:        Async,    returns nothing
## remotecall_fetch: Blocking, returns value
## remotecall_wait:  Blocking, returns nothing

"""
    Malt.remotecall(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Returns a task that acts as a promise; the result value of the task is the
result of the computation.

The function `f` must already be defined in the namespace of `w`.
"""
function remotecall(f, w::Worker, args...; kwargs...)
    _send(w, _new_call_msg(true, f, args..., kwargs...))
end


"""
    Malt.remote_do(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Unlike `remotecall`, it discards the result of the computation,
meaning there's no way to check if the computation was completed.
"""
function remote_do(f, w::Worker, args...; kwargs...)
    _send_msg(w.port, _new_do_msg(f, args..., kwargs...))
    nothing
end


"""
    Malt.remotecall_fetch(f, w::Worker, args...; kwargs...)

Shorthand for `fetch(Malt.remotecall(???))`. Blocks and then returns the result of the remote call.
"""
function remotecall_fetch(f, w::Worker, args...; kwargs...)
    fetch(_send(w, _new_call_msg(true, f, args..., kwargs...)))
end


"""
    Malt.remotecall_wait(f, w::Worker, args...; kwargs...)

Shorthand for `wait(Malt.remotecall(???))`. Blocks and discards the resulting value.
"""
function remotecall_wait(f, w::Worker, args...; kwargs...)
    wait(_send(w, _new_call_msg(false, f, args..., kwargs...)))
end


## Eval variants

"""
    Malt.remote_eval([m], w::Worker, ex)

Evaluate expression `ex` under module `m` on the worker `w`.
If no module is specified, `ex` is evaluated under `Main`.
`Malt.remote_eval` is asynchronous, like `Malt.remotecall`.

The module `m` and the type of `ex` must be defined in both the main process and the worker.
"""
remote_eval(m::Module, w::Worker, ex) = remotecall(Core.eval, w, m, ex)
remote_eval(w::Worker, ex) = remote_eval(Main, w, ex)


"""
Shorthand for `fetch(Malt.remote_eval(???))`, Blocks and returns the result of evaluating `ex`.
"""
remote_eval_fetch(m::Module, w::Worker, ex) = remotecall_fetch(Core.eval, w, m, ex)
remote_eval_fetch(w::Worker, ex) = remote_eval_fetch(Main, w, ex)


"""
Shorthand for `wait(Malt.remote_eval(???))`. Blocks and discards the resulting value.
"""
remote_eval_wait(m::Module, w::Worker, ex) = remotecall_wait(Core.eval, w, m, ex)
remote_eval_wait(w::Worker, ex) = remote_eval_wait(Main, w, ex)


"""
    Malt.worker_channel(w::Worker, ex)

Create a channel to communicate with worker `w`. `ex` must be an expression
that evaluates to a Channel. `ex` should assign the Channel to a (global) variable
so the worker has a handle that can be used to send messages back to the manager.
"""
function worker_channel(w::Worker, ex)::Channel
    # Send message
    s = connect(w.port)
    serialize(s, _new_channel_msg(ex))

    # Return channel
    Channel(function(channel)
        while isopen(channel) && isopen(s)
            put!(channel, deserialize(s))
        end
        close(s)
        return
    end)
end


"""
    kill(w::Malt.Worker)

Terminate the worker process `w`.
""" # https://youtu.be/dyIilW_eBjc
Base.kill(w::Worker) = remote_do(Base.exit, w)


end # module
