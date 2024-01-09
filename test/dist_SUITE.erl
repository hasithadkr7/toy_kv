-module(dist_SUITE).

-include_lib("common_test/include/ct.hrl").

%% Common Test
-export([all/0, init_per_suite/1, end_per_suite/1]).
%% Tests
-export([t_kv_basic_ops/1, t_ops_with_options/1, t_join_leave_ops/1]).

-define(SLAVES, ['a@127.0.0.1', 'b@127.0.0.1', 'c@127.0.0.1', 'd@127.0.0.1']).

%%==============================================================================
%% Common Test
%%==============================================================================

all() ->
    [t_kv_basic_ops, t_ops_with_options, t_join_leave_ops].

init_per_suite(Config) ->
    ok = application:set_env(toy_kv, mode, distributed),
    toy_kv:start(),
    Nodes = start_slaves(),
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    toy_kv:stop(),
    Config.

%%==============================================================================
%% Exported Test functions
%%==============================================================================
%%%% @private
%%start_primary_node() ->
%%    _ = net_kernel:start([?PRIMARY]),
%%    ok.
%%
%%%% @private
%%allow_boot() ->
%%    _ = erl_boot_server:start([]),
%%    {ok, IPv4} = inet:parse_ipv4_address("127.0.0.1"),
%%    erl_boot_server:add_slave(IPv4).

t_kv_basic_ops(_Config) ->
    %% Set
    ok = toy_kv:set(db1, k1, v1),
    ok = toy_kv:set(db1, k2, v2),
    ok = toy_kv:set(db1, k3, v3),

    %% Get
    {ok, v1} = toy_kv:get(db1, k1),
    {ok, v2} = toy_kv:get(db1, k2),
    {ok, v3} = toy_kv:get(db1, k3),

    %% Delete
    ok = toy_kv:del(db1, k3),
    {error, notfound} = toy_kv:get(db1, k3),

    ct:print("\e[1;1m t_kv_basic_ops \e[0m\e[32m[OK] \e[0m"),
    ok.

t_ops_with_options(_Config) ->
    %% Set
    ok = toy_kv:set(db1, k11, v1, [{replicas, 1}]),
    ok = toy_kv:set(db1, k22, v2, [{replicas, 2}]),
    ok = toy_kv:set(db1, k33, v3, [{replicas, 3}]),

    %% Get
    {ok, v1} = toy_kv:get(db1, k11, [{replicas, 1}]),
    {ok, v2} = toy_kv:get(db1, k22, [{replicas, 2}]),
    {ok, v3} = toy_kv:get(db1, k33, [{replicas, 3}]),

    %% Delete
    ok = toy_kv:del(db1, k33, [{replicas, 2}]),
    {ok, v3} = toy_kv:get(db1, k33, [{replicas, 3}]),
    ok = toy_kv:del(db1, k33, [{replicas, 3}]),
    {error, notfound} = toy_kv:get(db1, k33),

    ct:print("\e[1;1m t_ops_with_options \e[0m\e[32m[OK] \e[0m"),
    ok.

t_join_leave_ops(Config) ->
    %% Get nodes
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    [N0, N1, N2 | _] = lists:usort(Nodes),

    %% Eval functions
    EvalLocal =
        fun() ->
           lists:usort(
               toy_kv:get_nodes(db2))
        end,
    EvalRemotes =
        fun(RemoteNodes) ->
           {ResL, _} = rpc:multicall(RemoteNodes, toy_kv, get_nodes, [db2]),
           [lists:usort(RL) || RL <- ResL]
        end,

    %% Join
    [] = toy_kv:get_nodes(db2),
    ok = toy_kv:join(db2, [N0]),
    [N0] = EvalLocal(),
    ok = toy_kv:join(db2, [N1, N2]),
    [N0, N1, N2] = EvalLocal(),
    ok = toy_kv:join(db2, [N2]),
    [N0, N1, N2] = EvalLocal(),
    ok = toy_kv:join(db2, [N0, N1]),
    [N0, N1, N2] = EvalLocal(),

    %% Eval remotes
    [R00, R10, R20] = EvalRemotes([N0, N1, N2]),
    Local = node(),
    [N1, N2, Local] = R00,
    [N0, N2, Local] = R10,
    [N0, N1, Local] = R20,

    %% Leave
    ok = toy_kv:leave(db2, [N2]),
    [N0, N1] = EvalLocal(),
    [R01, R11, R21] = EvalRemotes([N0, N1, N2]),
    [N1, Local] = R01,
    [N0, Local] = R11,
    [] = R21,

    %% Bad join
    invalid_node = toy_kv:join(db2, [unknown@localhost]),

    %% Test some operations
    ok = toy_kv:set(db2, 1, 1),
    ok = toy_kv:set(db2, 1, 4),
    {ok, 4} = toy_kv:get(db2, 1),

    %% Check remote nodes
    {[LastR, LastR], _} = rpc:multicall([N0, N1], toy_kv, get, [db2, 1]),
    {[{error, notfound}], _} = rpc:multicall([N2], toy_kv, get, [db2, 1]),

    ct:print("\e[1;1m t_join_leave_ops \e[0m\e[32m[OK] \e[0m"),
    ok.

%%==============================================================================
%% Internal functions
%%==============================================================================

start_slaves() ->
    start_slaves(?SLAVES, []).

start_slaves([], Acc) ->
    Acc;
start_slaves([Node | T], Acc) ->
    HostNode = spawn_node(Node),
    start_slaves(T, [HostNode | Acc]).

%% @private
spawn_node(NodeName) ->
    Cookie = atom_to_list(erlang:get_cookie()),
    InetLoaderArgs =
        "-loader inet -hosts 127.0.0.1
        -config ../../config/sys.config
        -setcookie "
        ++ Cookie,
    {ok, _Pid, Node} = start_node(NodeName, InetLoaderArgs),
    pong = net_adm:ping(Node),
    ct:log("Slave started as ~p~n", [Node]),
    ok = rpc:block_call(Node, code, add_paths, [code:get_path()]),
    {ok, _} = rpc:block_call(Node, application, ensure_all_started, [toy_kv]),
    Node.

%% @private
start_node(NodeName, InetLoaderArgs) ->
    peer:start(#{name => node_name(NodeName),
                 host => "127.0.0.1",
                 args => [InetLoaderArgs]}).

%% @private
node_name(Node) ->
    [Name, _] = binary:split(atom_to_binary(Node, utf8), <<"@">>),
    binary_to_atom(Name, utf8).
