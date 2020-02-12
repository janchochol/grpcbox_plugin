-module(grpcbox_plugin_complier_module).

-behaviour(rebar_compiler).

-export([init/1]).
-export([context/1,
         needed_files/4,
         dependencies/3,
         compile/4,
         clean/2]).

-include_lib("gpb/include/gpb.hrl").

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, rebar_state:prepend_compilers(State, [?MODULE])}.

%% ===================================================================
%% rebar_compiler callbacks
%% ===================================================================

context(AppInfo) ->
    Config = rebar_app_info:opts(AppInfo),
    GrpcConfig = rebar_opts:get(Config, grpc, []),
    SrcDirs = proplists:get_value(src, GrpcConfig, ["proto"]),
    IncludeDirs = proplists:get_value(include, GrpcConfig, []),

    #{
        src_dirs => SrcDirs,
        include_dirs => IncludeDirs,
        src_ext => ".proto",
        out_mappings => [{".erl", out_dir(AppInfo)}]
    }.

needed_files(Graph, FoundFiles, [{_, OutDir}], AppInfo) ->
    Config = rebar_app_info:opts(AppInfo),
    GrpcConfig = rebar_opts:get(Config, grpc, []),
    FilteredFiles = lists:filter(fun(Source) ->
                Target = erl_file(Source, GrpcConfig, OutDir),
                digraph:vertex(Graph, Source) > {Source, filelib:last_modified(Target)}
        end, FoundFiles),
    {{[], GrpcConfig}, {FilteredFiles, GrpcConfig}}.

dependencies(Source, _SourceDir, Dirs) ->
    {ok, Defs} = gpb_compile:file(
        Source, [use_packages, to_proto_defs] ++ [{i, Dir} || Dir <- Dirs]
    ),
    Deps = proplists:get_all_values(import, Defs),
    AbsDeps = lists:flatmap(fun(Dep) ->
                lists:flatmap(
                    fun(Dir) ->
                            FullPath = filename:join(Dir, Dep),
                            case filelib:is_regular(FullPath) of
                                true ->
                                    [FullPath];
                                false ->
                                    []
                            end
                    end, Dirs)
        end, Deps),
    AbsDeps.

compile(Source, [{_, OutDir}], _Config, GrpcConfig) ->
    AllOpts = all_opts(GrpcConfig),
    case gpb_compile:file(Source, [{o, OutDir} | AllOpts]) of
        {ok, Ws} ->
            compile_service_behaviour(Source, AllOpts, OutDir, GrpcConfig),
            rebar_compiler:ok_tuple(Source, Ws);
        {error, Es, Ws} ->
            rebar_compiler:error_tuple(Source, Es, Ws, AllOpts)
    end.

clean(Sources, AppInfo) ->
    Config = rebar_app_info:opts(AppInfo),
    GrpcConfig = rebar_opts:get(Config, grpc, []),
    OutDir = out_dir(AppInfo),
    Type = proplists:get_value(type, GrpcConfig, all),

    AllOpts = all_opts(GrpcConfig),
    Files = lists:flatmap(fun(Source) ->
                try
                    {ok, Defs, _} = gpb_compile:file(Source, [to_proto_defs | AllOpts]),
                    ServiceNames = [ServiceName || {{service, ServiceName}, _Methods} <- Defs],
                    ServiceFiles = lists:flatmap(fun(ServiceName) ->
                                TargetModuleName = service_module_name_prefix(ServiceName, GrpcConfig),
                                Client = filename:join(OutDir, TargetModuleName ++ "_client.erl"),
                                if
                                    Type =:= all; Type =:= "all" ->
                                        [filename:join(OutDir, TargetModuleName ++ "_bhvr.erl"), Client];
                                    true ->
                                        Client
                                end
                        end, ServiceNames),
                    [erl_file(Source, GrpcConfig, OutDir) | ServiceFiles]
                catch
                    % Ignore compile errors during clean
                    _:_ -> []
                end
        end, Sources),
    rebar_file_utils:delete_each(Files).

%% ===================================================================
%% helpers
%% ===================================================================

% compile_service_behaviour(TemplateName, ServiceModules, GpbModule, OutDir, Options, GrpcConfig, State) ->
compile_service_behaviour(Source, AllOpts, OutDir, GrpcConfig) ->
    {{Y,M,D},{H,Min,S}} = calendar:universal_time(),
    Type = proplists:get_value(type, GrpcConfig, all),

    {ok, Defs, _} = gpb_compile:file(Source, [to_proto_defs | AllOpts]),
    Services = [{ServiceName, Methods} || {{service, ServiceName}, Methods} <- Defs],

    NoRenameOpts = lists:filter(fun({rename, _}) -> false; (_) -> true end, AllOpts),
    {ok, NoRenameDefs, _} = gpb_compile:file(Source, [to_proto_defs | NoRenameOpts]),
    {ok, Renamings} = gpb_names:compute_renamings(NoRenameDefs, AllOpts),
    MsgRenamings = proplists:get_value(inverse_msgs, Renamings),

    lists:foreach(fun({ServiceName, Methods}) ->
                ResultMethods = [
                    [
                        {message_type, dict:fetch(Method#?gpb_rpc.input, MsgRenamings)},

                        {input, atom_to_list(Method#?gpb_rpc.input)},
                        {input_stream, Method#?gpb_rpc.input_stream},
                        {output, atom_to_list(Method#?gpb_rpc.output)},
                        {output_stream, Method#?gpb_rpc.output_stream},
                        {method, list_snake_case(atom_to_list(Method#?gpb_rpc.name))},

                        {unmodified_input, atom_to_list(Method#?gpb_rpc.input)},
                        {unmodified_input_stream, Method#?gpb_rpc.input_stream},
                        {unmodified_output, atom_to_list(Method#?gpb_rpc.output)},
                        {unmodified_output_stream, Method#?gpb_rpc.output_stream},
                        {unmodified_method, atom_to_list(Method#?gpb_rpc.name)}
                    ] || Method <- Methods
                ],
                TargetModuleName = service_module_name_prefix(ServiceName, GrpcConfig),
                Service = [
                    {out_dir, OutDir},
                    {pb_module, module_name(Source, GrpcConfig)},
                    {unmodified_service_name, ServiceName},
                    {module_name, TargetModuleName},
                    {methods, ResultMethods},
                    {datetime, lists:flatten(io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w+00:00",[Y,M,D,H,Min,S]))}
                ],
                if
                    Type =:= all; Type =:= "all" ->
                        ok = file:write_file(
                            filename:join(OutDir, TargetModuleName ++ "_bhvr.erl"),
                            bbmustache:render(behavior_template(), Service, mustache_opts())
                        );
                    true ->
                        ok
                end,
                ok = file:write_file(
                    filename:join(OutDir, TargetModuleName ++ "_client.erl"),
                    bbmustache:render(client_template(), Service, mustache_opts())
                )
        end, Services).

mustache_opts() ->
    [{key_type, atom}, {escape_fun, fun(X) -> X end}].

all_opts(GrpcConfig) ->
    IncludeDirs = proplists:get_value(include, GrpcConfig, []),
    Includes = [{i, Dir} || Dir <- IncludeDirs],
    Options = proplists:get_value(gpb_opts, GrpcConfig, []),

    [
        {rename, {msg_name, snake_case}},
        {rename, {msg_fqname, base_name}},
        use_packages, maps,
        strings_as_binaries,
        return_warnings
    ] ++ Options ++ Includes.

out_dir(AppInfo) ->
    Dir = rebar_app_info:dir(AppInfo),
    filename:join([Dir, "src"]).

erl_file(Source, GrpcConfig, OutDir) ->
    filename:join(
        OutDir,
        module_name(Source, GrpcConfig) ++ ".erl"
    ).

module_name(Source, GrpcConfig) ->
    Options = proplists:get_value(gpb_opts, GrpcConfig, []),

    ModuleNameSuffix = proplists:get_value(module_name_suffix, Options, ""),
    ModuleNamePrefix = proplists:get_value(module_name_prefix, Options, ""),

    ModuleNamePrefix ++ filename:basename(Source, ".proto") ++ ModuleNameSuffix.

service_module_name_prefix(ServiceName, GrpcConfig) ->
    ServiceModules = proplists:get_value(service_modules, GrpcConfig, []),
    ServicePrefix = proplists:get_value(prefix, GrpcConfig, ""),
    ServiceSuffix = proplists:get_value(suffix, GrpcConfig, ""),

    ModuleName = proplists:get_value(ServiceName, ServiceModules, list_snake_case(atom_to_list(ServiceName))),
    ServicePrefix ++ ModuleName ++ ServiceSuffix.

list_snake_case(NameString) ->
    Snaked = lists:foldl(fun(RE, Snaking) ->
                                 re:replace(Snaking, RE, "\\1_\\2", [{return, list},
                                                                     global])
                         end, NameString, [%% uppercase followed by lowercase
                                           "(.)([A-Z][a-z]+)",
                                           %% any consecutive digits
                                           "(.)([0-9]+)",
                                           %% uppercase with lowercase
                                           %% or digit before it
                                           "([a-z0-9])([A-Z])"]),
    Snaked1 = string:replace(Snaked, ".", "_", all),
    Snaked2 = string:replace(Snaked1, "__", "_", all),
    string:to_lower(unicode:characters_to_list(Snaked2)).

behavior_template() ->
    <<"%%%-------------------------------------------------------------------
%% @doc Behaviour to implement for grpc service {{unmodified_service_name}}.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on {{datetime}} and should not be modified manually

-module({{module_name}}_bhvr).

{{#methods}}
%% @doc {{^input_stream}}{{^output_stream}}Unary RPC{{/output_stream}}{{/input_stream}}
-callback {{method}}({{^input_stream}}{{#output_stream}}{{pb_module}}:{{input}}(), grpcbox_stream:t(){{/output_stream}}{{/input_stream}}{{#input_stream}}{{^output_stream}}reference(), grpcbox_stream:t(){{/output_stream}}{{#output_stream}}reference(), grpcbox_stream:t(){{/output_stream}}{{/input_stream}}{{^input_stream}}{{^output_stream}}ctx:ctx(), {{pb_module}}:{{input}}(){{/output_stream}}{{/input_stream}}) ->
    {{#output_stream}}ok{{/output_stream}}{{^output_stream}}{ok, {{pb_module}}:{{output}}(), ctx:ctx()}{{/output_stream}} | grpcbox_stream:grpc_error_response().

{{/methods}}
">>.

client_template() ->
    <<"%%%-------------------------------------------------------------------
%% @doc Client module for grpc service {{unmodified_service_name}}.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on {{datetime}} and should not be modified manually

-module({{module_name}}_client).

-include_lib(\"grpcbox/include/grpcbox.hrl\").

{{#methods}}
-export([{{method}}/1, {{method}}/2, {{method}}/3]).
{{/methods}}

-define(is_ctx(Ctx), is_tuple(Ctx) andalso element(1, Ctx) =:= ctx).

-define(SERVICE, '{{unmodified_service_name}}').
-define(PROTO_MODULE, '{{pb_module}}').
-define(MARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:encode_msg(I, T) end).
-define(UNMARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:decode_msg(I, T) end).
-define(DEF(Input, Output, MessageType), #grpcbox_def{service=?SERVICE,
                                                      message_type=MessageType,
                                                      marshal_fun=?MARSHAL_FUN(Input),
                                                      unmarshal_fun=?UNMARSHAL_FUN(Output)}).

{{#methods}}

%% @doc {{^input_stream}}{{^output_stream}}Unary RPC{{/output_stream}}{{/input_stream}}
-spec {{method}}({{^input_stream}}{{pb_module}}:{{input}}(){{/input_stream}}) ->
    {{^output_stream}}{{^input_stream}}{ok, {{pb_module}}:{{output}}(), grpcbox:metadata()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}}{{#output_stream}}{{^input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}} | grpcbox_stream:grpc_error_response().
{{method}}({{^input_stream}}Input{{/input_stream}}) ->
    {{method}}(ctx:new(){{^input_stream}}, Input{{/input_stream}}, #{}).

-spec {{method}}(ctx:t(){{^input_stream}} | {{pb_module}}:{{input}}(){{/input_stream}}{{^input_stream}}, {{pb_module}}:{{input}}(){{/input_stream}} | grpcbox_client:options()) ->
    {{^output_stream}}{{^input_stream}}{ok, {{pb_module}}:{{output}}(), grpcbox:metadata()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}}{{#output_stream}}{{^input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}} | grpcbox_stream:grpc_error_response().
{{method}}(Ctx{{^input_stream}}, Input{{/input_stream}}) when ?is_ctx(Ctx) ->
    {{method}}(Ctx{{^input_stream}}, Input{{/input_stream}}, #{});
{{method}}({{^input_stream}}Input, {{/input_stream}}Options) ->
    {{method}}(ctx:new(){{^input_stream}}, Input{{/input_stream}}, Options).

-spec {{method}}(ctx:t(){{^input_stream}}, {{pb_module}}:{{input}}(){{/input_stream}}, grpcbox_client:options()) ->
    {{^output_stream}}{{^input_stream}}{ok, {{pb_module}}:{{output}}(), grpcbox:metadata()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}}{{#output_stream}}{{^input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{#input_stream}}{ok, grpcbox_client:stream()}{{/input_stream}}{{/output_stream}} | grpcbox_stream:grpc_error_response().
{{method}}(Ctx{{^input_stream}}, Input{{/input_stream}}, Options) ->
    {{^output_stream}}{{^input_stream}}grpcbox_client:unary(Ctx, <<\"/{{unmodified_service_name}}/{{unmodified_method}}\">>, Input, ?DEF({{input}}, {{output}}, <<\"{{message_type}}\">>), Options){{/input_stream}}{{#input_stream}}grpcbox_client:stream(Ctx, <<\"/{{unmodified_service_name}}/{{unmodified_method}}\">>, ?DEF({{input}}, {{output}}, <<\"{{message_type}}\">>), Options){{/input_stream}}{{/output_stream}}{{#output_stream}}{{^input_stream}}grpcbox_client:stream(Ctx, <<\"/{{unmodified_service_name}}/{{unmodified_method}}\">>, Input, ?DEF({{input}}, {{output}}, <<\"{{message_type}}\">>), Options){{/input_stream}}{{#input_stream}}grpcbox_client:stream(Ctx, <<\"/{{unmodified_service_name}}/{{unmodified_method}}\">>, ?DEF({{input}}, {{output}}, <<\"{{message_type}}\">>), Options){{/input_stream}}{{/output_stream}}.

{{/methods}}
">>.

