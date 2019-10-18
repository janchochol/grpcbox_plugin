-module(grpcbox_plugin_prv).

-export([init/1, do/1, format_error/1]).

-include_lib("providers/include/providers.hrl").

-define(PROVIDER, gen).
-define(NAMESPACE, grpc).
-define(DEPS, [{default, app_discovery}]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {namespace, ?NAMESPACE},
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 grpc gen"}, % How to use the plugin
            {opts, [{protos, $p, "protos", string, "directory of protos to build"},
                    {force, $f, "force", boolean, "overwrite already generated modules"},
                    {type, $t, "type", string, "generate 'client' or 'all' (server behaviour and client)"}]},
            {short_desc, "Generates behaviours for grpc services"},
            {desc, "Generates behaviours for grpc services"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    Apps = case rebar_state:current_app(State) of
               undefined ->
                   rebar_state:project_apps(State);
               AppInfo ->
                   [AppInfo]
           end,
    [begin
         Config = rebar_app_info:opts(AppInfo),
         BaseDir = rebar_app_info:dir(AppInfo),
         DefaultOutDir = filename:join(BaseDir, "src"),
         DefaultProtosDir = filename:join("priv", "protos"),

         %% Config = rebar_state:opts(State),
         GrpcConfig = rebar_opts:get(Config, grpc, []),
         {Options, _} = rebar_state:command_parsed_args(State),
         ProtosDirs = case proplists:get_all_values(protos, Options) of
                          [] ->
                              case proplists:get_value(protos, GrpcConfig, [DefaultProtosDir]) of
                                  [H | _]=Ds when is_list(H) ->
                                      Ds;
                                  D ->
                                      [D]
                              end;
                          Ds ->
                              Ds
                      end,
         ProtosDirs1 = [filename:join(BaseDir, D) || D <- ProtosDirs],
         GpbOpts = proplists:get_value(gpb_opts, GrpcConfig, []),
         GrpcOutDir = proplists:get_value(out_dir, GrpcConfig, DefaultOutDir),
         Type = case proplists:get_value(type, Options, undefined) of
                    undefined ->
                        proplists:get_value(type, GrpcConfig, all);
                    T when T =:= "all" orelse T =:= "client" ->
                        T
                end,
         TemplateName = to_template_name(Type),
         ServiceModules = proplists:get_value(service_modules, GrpcConfig, []),

         IncludeDirs = [filename:join(BaseDir, D) || D <- proplists:get_all_values(i, GpbOpts)],
         Graph = init_dag(AppInfo, IncludeDirs, ProtosDirs1, GpbOpts ++ [{i, ProtoDir} || ProtoDir <- ProtosDirs1]),

         [[begin
               GpbModule = compile_pb(Filename, GrpcOutDir, BaseDir, GpbOpts),
               gen_service_behaviour(TemplateName, ServiceModules, GpbModule, GrpcOutDir, Options, GrpcConfig, State)
           end || Filename <- filelib:wildcard(filename:join(Dir, "*.proto"))]
          || Dir <- ProtosDirs1]

     end || AppInfo <- Apps],
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error({compile_errors, Errors, Warnings}) ->
    [begin
         rebar_api:warn("Warning building ~s~n", [File]),
         [rebar_api:warn("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]
     end || {File, Es} <- Warnings],
    [[io_lib:format("Error building ~s~n", [File]) |
         [io_lib:format("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]] || {File, Es} <- Errors];
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

to_template_name(all) ->
    "grpcbox";
to_template_name(client) ->
    "grpcbox_client";
to_template_name("all") ->
    "grpcbox";
to_template_name("client") ->
    "grpcbox_client".

maybe_rename(name) ->
    method;
maybe_rename(N) ->
    N.

unmodified_maybe_rename(name) ->
    unmodified_method;
unmodified_maybe_rename(N) ->
    N.

gen_service_behaviour(TemplateName, ServiceModules, GpbModule, OutDir, Options, GrpcConfig, State) ->
    Force = proplists:get_value(force, Options, true),
    ServicePrefix = proplists:get_value(prefix, GrpcConfig, ""),
    ServiceSuffix = proplists:get_value(suffix, GrpcConfig, ""),
    Services = [begin
                    {{_, Name}, Methods} = GpbModule:get_service_def(S),
                    ModuleName = proplists:get_value(Name, ServiceModules,
                                                     list_snake_case(atom_to_list(Name))),
                    [{out_dir, OutDir},
                     {pb_module, atom_to_list(GpbModule)},
                     {unmodified_service_name, atom_to_list(Name)},
                     {module_name, ServicePrefix++ModuleName++ServiceSuffix},
                     {methods, [lists:flatten([[[{maybe_rename(X), maybe_snake_case(X, atom_to_list(Y))},
                                                   {unmodified_maybe_rename(X), atom_to_list(Y)}]
                                               || {X, Y} <- maps:to_list(Method), X =/= opts],
                                              {message_type, GpbModule:msg_name_to_fqbin(maps:get(input, Method))}])
                                || Method <- Methods]}]
                end || S <- GpbModule:get_service_names()],
    rebar_log:log(debug, "services: ~p", [Services]),
    [rebar_templater:new(TemplateName, Service, Force, State) || Service <- Services].

compile_pb(Filename, GrpcOutDir, BaseDir, Options) ->
    OutDir = filename:join(BaseDir, proplists:get_value(o, Options, GrpcOutDir)),
    ModuleNameSuffix = proplists:get_value(module_name_suffix, Options, ""),
    ModuleNamePrefix = proplists:get_value(module_name_prefix, Options, ""),
    CompiledPB =  filename:join(OutDir, ModuleNamePrefix++filename:basename(Filename, ".proto") ++ ModuleNameSuffix++".erl"),
    rebar_log:log(info, "Writing ~s", [CompiledPB]),
    ok = gpb_compile:file(Filename, [{rename,{msg_name,snake_case}},
                                     {rename,{msg_fqname,base_name}},
                                     use_packages, maps,
                                     strings_as_binaries, {i, "."}, {o, OutDir} | Options]),
    GpbInludeDir = filename:join(code:lib_dir(gpb), "include"),
    case compile:file(CompiledPB,
                      [binary, {i, GpbInludeDir}, return_errors]) of
        {ok, Module, Compiled} ->
            {module, _} = code:load_binary(Module, CompiledPB, Compiled),
            Module;
        {ok, Module, Compiled, Warnings} ->
            [begin
                 rebar_api:warn("Warning building ~s~n", [File]),
                 [rebar_api:warn("        ~p: ~s", [Line, M:format_error(E)]) || {Line, M, E} <- Es]
             end || {File, Es} <- Warnings],
            {module, _} = code:load_binary(Module, CompiledPB, Compiled),
            Module;
        {error, Errors, Warnings} ->
            throw(?PRV_ERROR({compile_errors, Errors, Warnings}))
    end.

maybe_snake_case(name, Name) ->
    list_snake_case(Name);
maybe_snake_case(_, "true") ->
    true;
maybe_snake_case(_, "false") ->
    false;
maybe_snake_case(_, Value) ->
    Value.

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








serialize(Graph) ->
    SerializedGraph = lists:map(fun(Proto) ->
                {Proto, Props} = digraph:vertex(Graph, Proto),
                {Proto, Props, digraph:out_neighbours(Graph, Proto)}
        end, digraph:vertices(Graph)),
    digraph:delete(Graph),
    SerializedGraph.

deserialize(SerializedGraph, Graph) ->
    lists:foreach(fun({Proto, Props, _Deps}) ->
                digraph:add_vertex(Graph, Proto, Props)
        end, SerializedGraph),
    lists:foreach(fun({Proto, _Props, Deps}) ->
                lists:foreach(fun(Dep) ->
                            digraph:add_edge(Graph, Proto, Dep)
                    end, Deps)
        end, SerializedGraph),
    Graph.

dag_file(AppInfo) ->
    EbinDir = rebar_app_info:ebin_dir(AppInfo),
    CacheDir = rebar_dir:local_cache_dir(EbinDir),
    filename:join([CacheDir, "grpcbox_plugin", "dependency.dag"]).

restore_dag(AppInfo, Graph) ->
    case file:read_file(dag_file(AppInfo)) of
        {ok, Data} ->
            deserialize(binary_to_term(Data), Graph);
        {error, _} ->
            Graph
    end.

init_dag(AppInfo, InclDirs, ProtoDirs, GpbOpts) ->
    rebar_api:debug("dag include dirs: ~p~n", [InclDirs]),
    rebar_api:debug("dag proto dirs: ~p~n", [ProtoDirs]),
    rebar_api:debug("dag file: ~ts~n", [dag_file(AppInfo)]),
    InitGraph = digraph:new([acyclic]),
    Graph = try restore_dag(AppInfo, InitGraph)
    catch
        _:_ ->
            rebar_api:warn("Failed to restore ~ts file. Discarding it.~n", [dag_file(AppInfo)]),
            digraph:delete(InitGraph),
            file:delete(dag_file(AppInfo)),
            % Ensure empty graph
            digraph:new([acyclic])
    end,
    scan_protos(InclDirs, ProtoDirs, Graph),
    detect_compile_protos(Graph, GpbOpts),
    Graph.
    
%do(InclDirs, ProtoDirs, Graph, GpbOpts) ->
%    scan_protos(InclDirs, ProtoDirs, Graph),
%    compile_protos(Graph, GpbOpts),
%    lists:foreach(fun(Proto) ->
%                {Proto, Props} = digraph:vertex(Graph, Proto),
%                io:format("~p (~p) ->~n - ", [Proto, Props]),
%                Deps = digraph:out_neighbours(Graph, Proto),
%                lists:foreach(fun(Dep) ->
%                            io:format("~p, ", [Dep])
%                    end, Deps),
%                io:format("~n", []),
%                digraph:add_vertex(Graph, Proto, do_compile(Proto, Props))
%        end, digraph:vertices(Graph)),
%    Graph.

scan_protos(InclDirs, ProtoDirs, Graph) ->
    Includes = scan_dirs(InclDirs, include, Graph, sets:new()),
    scan_dirs(ProtoDirs, proto, Graph, Includes),
    Graph.

scan_dirs(Dirs, Type, Graph, AllExistingProtos) ->
    lists:foldl(fun(Dir, AllExistingProtosAcc) ->
                scan_dir(Dir, Type, Graph, AllExistingProtosAcc)
        end, AllExistingProtos, Dirs).

scan_dir(Dir, Type, Graph, AllExistingProtos) ->
    lists:foldl(fun(File, AllExistingProtosAcc) ->
                Proto = filename:basename(File),
                case sets:is_element(Proto, AllExistingProtosAcc) of
                    true ->
                        throw({dep_error, {duplicate_filename, Proto}});
                    false ->
                        ok
                end,
                case digraph:vertex(Graph, Proto) of
                    false ->
                        digraph:add_vertex(Graph, Proto,
                            [Type, compile, {modified, filelib:last_modified(File)}, {file, File}]);
                    _ ->
                        ok
                end,
                sets:add_element(Proto, AllExistingProtosAcc)
        end, AllExistingProtos, filelib:wildcard(filename:join(Dir, "*.proto"))).
    
detect_compile_protos(Graph, GpbOpts) ->
    update_graph(Graph, GpbOpts),
    spread_compile_from_deps(Graph).
    
update_graph(Graph, GpbOpts) ->
    lists:foreach(fun(Proto) ->
                {Proto, Props} = digraph:vertex(Graph, Proto),
                File = proplists:get_value(file, Props),
                Compile = proplists:get_value(compile, Props, false),
                OldModified = proplists:get_value(modified, Props),
                NewModified = filelib:last_modified(File),
                if
                    NewModified =:= 0 ->
                        mark_all_compile(digraph:in_neighbours(Graph, Proto), Graph),
                        digraph:del_vertex(Graph, Proto);
                    Compile orelse NewModified /= OldModified ->
                        mark_compile(Proto, Graph),
                        update_proto_deps(Proto, Graph, GpbOpts);
                    true ->
                        ok
                end
        end, digraph:vertices(Graph)).


update_proto_deps(Proto, Graph, GpbOpts) ->
    Defs = case gpb_compile:file(Proto, [to_proto_defs, return | GpbOpts]) of
        {ok, OkDefs, _Warnings} ->
            OkDefs;
        {error, Error, _Warnings} ->
            throw({dep_error, Error})
    end,
    Deps = lists:usort(gpb_parse:fetch_imports(Defs)),
    digraph:del_edges(Graph, digraph:out_edges(Graph, Proto)),
    lists:foreach(fun(Dep) ->
                case digraph:vertex(Graph, Dep) of
                    false ->
                        throw({dep_error, {dependency_not_found, Proto, Dep}});
                    _ ->
                        ok
                end,
                digraph:add_edge(Graph, Proto, Dep)
        end, Deps).

mark_all_compile(Protos, Graph) ->
    lists:foreach(fun(Proto) -> mark_compile(Proto, Graph) end, Protos).

mark_compile(Proto, Graph) ->
    {Proto, Props} = digraph:vertex(Graph, Proto),
    case proplists:get_value(compile, Props, false) of
        false ->
            digraph:add_vertex(Graph, Proto, [compile | Props]),
            true;
        true ->
            % Already set to compile
            false
    end.
    
spread_compile_from_deps(Graph) ->
    lists:foreach(fun(Proto) ->
                {Proto, Props} = digraph:vertex(Graph, Proto),
                Compile = proplists:get_value(compile, Props, false),
                case Compile of
                    true ->
                        mark_compile_from_deps(Proto, Graph);
                    false ->
                        ok
                end
        end, digraph:vertices(Graph)).

mark_compile_from_deps(Proto, Graph) ->
    ReverseDeps = digraph:in_neighbours(Graph, Proto),
    lists:foreach(fun(ReverseDep) ->
                case mark_compile(ReverseDep, Graph) of
                    true ->
                        mark_compile_from_deps(ReverseDep, Graph);
                    false ->
                        ok
                end
        end, ReverseDeps).
                
do_compile(Proto, Props) ->
    File = proplists:get_value(file, Props),
    NewModified = filelib:last_modified(File),
    NewProps = lists:keyreplace(modified, 1, lists:delete(compile, Props), {modified, NewModified}),
    % COMPILE
    NewProps.
