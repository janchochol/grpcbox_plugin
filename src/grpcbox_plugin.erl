-module(grpcbox_plugin).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    GrpcConfig = rebar_opts:get(rebar_state:opts(State), grpc, []),
    UseCompilerModule = proplists:get_value(use_compiler_module, GrpcConfig, false),

    {ok, State1} = case UseCompilerModule of
        true ->
            grpcbox_plugin_complier_module:init(State);
        false ->
            grpcbox_plugin_prv:init(State)
    end,
    {ok, State1}.
