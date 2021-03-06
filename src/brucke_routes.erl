%%%
%%%   Copyright (c) 2016 Klarna AB
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%
-module(brucke_routes).

-export([ all/0
        , destroy/0
        , init/1
        , lookup/2
        ]).

-include("brucke_int.hrl").

-define(ETS, ?MODULE).

-define(IS_PRINTABLE(C), (C >= 32 andalso C < 127)).

-define(IS_VALID_TOPIC_NAME(N),
        (is_atom(N) orelse
         is_binary(N) orelse
         is_list(N) andalso N =/= [] andalso ?IS_PRINTABLE(hd(N)))).

-type validation_result() :: true | binary() | [validation_result()].

%%%_* APIs =====================================================================

-spec init([raw_route()]) -> ok | no_return().
init(Routes) when is_list(Routes) ->
  ets:info(?ETS) =/= ?undef andalso exit({?ETS, already_created}),
  ?ETS = ets:new(?ETS, [named_table, protected, set,
                        {keypos, #route.upstream}]),
  try
    ok = do_init_loop(Routes)
  catch C : E ->
    ok = destroy(),
    erlang:C({E, erlang:get_stacktrace()})
  end;
init(Other) ->
  lager:emergency("Expecting list of routes, got ~P", [Other, 9]),
  erlang:exit(bad_routes_config).

%% @doc Lookup in config cache for the message routing destination.
-spec lookup(brod_client_id(), kafka_topic()) -> route() | false.
lookup(UpstreamClientId, UpstreamTopic) ->
  case ets:lookup(?ETS, {UpstreamClientId, UpstreamTopic}) of
    []      -> false;
    [Route] -> Route
  end.

%% @doc Delete Ets.
-spec destroy() -> ok.
destroy() ->
  try
    ets:delete(?ETS),
    ok
  catch error : badarg ->
    ok
  end.

%% @doc Get all routes from cache.
-spec all() -> [route()].
all() -> ets:tab2list(?ETS).

%%%_* Internal functions =======================================================

-spec do_init_loop([raw_route()]) -> ok.
do_init_loop([]) -> ok;
do_init_loop([RawRoute | Rest]) ->
  try
    case validate_route(RawRoute) of
      {ok, Routes} ->
        ok = insert_routes(Routes);
      {error, Reasons} ->
        Rs = [[Reason, "\n"] || Reason <- Reasons],
        ok = brucke_lib:log_skipped_route_alert(RawRoute, Rs)
    end
  catch throw : Reason ->
      ReasonTxt = io_lib:format("~p", [Reason]),
      ok = brucke_lib:log_skipped_route_alert(RawRoute, ReasonTxt)
  end,
  do_init_loop(Rest).

-spec validate_route(raw_route()) ->
                {ok, [route()]} | {error, validation_result()} | no_return().
validate_route(RawRoute0) ->
  %% use maps to ensure
  %% 1. key-value list
  %% 2. later value should overwrite earlier in case of key duplication
  RawRouteMap =
    try
      maps:from_list(RawRoute0)
    catch error : badarg ->
        throw(bad_route)
    end,
  RawRoute = maps:to_list(RawRouteMap),
  case apply_route_schema(RawRoute, schema(), defaults(), #{}, []) of
    {ok, #{ upstream_client   := UpstreamClient
          , downstream_client := DownstreamClient
          , upstream_topics   := UpstreamTopics
          , downstream_topic  := DownstreamTopic
          } = RouteAsMap} ->
      case UpstreamClient =:= DownstreamClient of
        true  -> ok = ensure_no_loopback(UpstreamTopics, DownstreamTopic);
        false -> ok
      end,
      convert_to_route_record(RouteAsMap);
    {error, Reasons} ->
      {error, Reasons}
  end.

convert_to_route_record(Route) ->
  #{ upstream_client := UpstreamClientId
   , upstream_topics := UpstreamTopics
   , downstream_client := DownstreamClientId
   , downstream_topic := DownstreamTopic
   , repartitioning_strategy := RepartitioningStrategy
   , max_partitions_per_group_member := MaxPartitionsPerGroupMember
   , default_begin_offset := BeginOffset
   , compression := Compression
   } = Route,
  ProducerConfig = [{compression, Compression}],
  ConsumerConfig = [{begin_offset, BeginOffset}],
  Options =
    #{ repartitioning_strategy => RepartitioningStrategy
     , max_partitions_per_group_member => MaxPartitionsPerGroupMember
     , producer_config => ProducerConfig
     , consumer_config => ConsumerConfig
     },
  %% flatten out the upstream topics
  %% to cimplify the config as if it's all
  %% one upstream topic to one downstream topic mapping
  MapF =
    fun(Topic) ->
        #route{ upstream = {UpstreamClientId, topic(Topic)}
              , downstream = {DownstreamClientId, topic(DownstreamTopic)}
              , options = Options}
    end,
  {ok, lists:map(MapF, topics(UpstreamTopics))}.

defaults() ->
  #{ repartitioning_strategy         => ?DEFAULT_REPARTITIONING_STRATEGY
   , max_partitions_per_group_member => ?MAX_PARTITIONS_PER_GROUP_MEMBER
   , default_begin_offset            => ?DEFAULT_DEFAULT_BEGIN_OFFSET
   , compression                     => ?DEFAULT_COMPRESSION
   }.

schema() ->
  #{ upstream_client =>
       fun(_, Id) ->
           is_configured_client_id(Id) orelse
             <<"unknown upstream client id">>
       end
   , downstream_client =>
       fun(_, Id) ->
           is_configured_client_id(Id) orelse
             <<"unknown downstream client id">>
       end
   , downstream_topic =>
       fun(_, Topic) ->
           ?IS_VALID_TOPIC_NAME(Topic) orelse
             invalid_topic_name(downstream, Topic)
       end
   , upstream_topics =>
       fun(#{upstream_client := UpstreamClientId}, Topic) ->
           validate_upstream_topics(UpstreamClientId, Topic)
       end
   , repartitioning_strategy =>
       fun(_, S) ->
           ?IS_VALID_REPARTITIONING_STRATEGY(S) orelse
             fmt("unknown repartitioning strategy ~p", [S])
       end
   , max_partitions_per_group_member =>
       fun(_, M) ->
           (is_integer(M) andalso M > 0) orelse
             fmt("max_partitions_per_group_member "
                 "should be a positive integer\nGto~p", [M])
       end
   , default_begin_offset =>
       fun(_, B) ->
           (B =:= latest orelse B =:= earliest) orelse
             fmt("default_begin_offset should be either "
                 "'latest' or 'earliest'\nGot~p", [B])
       end
   , compression =>
       fun(_, C) ->
           C =:= no_compression orelse
           C =:= gzip           orelse
           C =:= snappy         orelse
           fmt("compression should be one of "
               "[no_compression, gzip, snappy]\nGot~p", [C])
       end
   }.

-spec apply_route_schema(raw_route(), #{}, #{}, #{}, validation_result()) ->
                            {ok, #{}} | {error, validation_result()} |
                            no_return().
apply_route_schema([], Schema, Defaults, Result, Errors0) ->
  Errors1 =
    case maps:to_list(maps:without(maps:keys(Defaults), Schema)) of
      [] ->
        Errors0;
      Missing ->
        MissingAttrs = [K || {K, _V} <- Missing],
        [fmt("missing mandatory attributes ~p", [MissingAttrs]) | Errors0]
    end,
  Errors = [E || E <- lists:flatten(Errors1), E =/= true],
  case [] =:= Errors of
    true ->
      %% merge (overwrite) parsed values to defaults
      {ok, maps:merge(Defaults, Result)};
    false ->
      {error, Errors}
  end;
apply_route_schema([{K, V} | Rest], Schema, Defaults, Result, Errors) ->
  case maps:find(K, Schema) of
    {ok, Fun} ->
      NewSchema = maps:remove(K, Schema),
      NewResult = Result#{K => V},
      case Fun(NewResult, V) of
        true ->
          apply_route_schema(Rest, NewSchema, Defaults, NewResult, Errors);
        Error ->
          NewErrors = [Error | Errors],
          apply_route_schema(Rest, NewSchema, Defaults, NewResult, NewErrors)
      end;
    error ->
      Error =
        case is_atom(K) of
          true  -> fmt("unknown attribute ~p", [K]);
          false -> fmt("unknown attribute ~p, expecting atom", [K])
        end,
      apply_route_schema(Rest, Schema, Defaults, Result, [Error | Errors])
  end.

%% This is to ensure there is no direct loopback due to typo for example.
%% indirect loopback would be fun for testing, so not trying to build a graph
%% {upstream, topic_1} -> {downstream, topic_2}
%% {downstream, topic_2} -> {upstream, topic_1}
%% you get a perfect data generator for load testing.
-spec ensure_no_loopback(topic_name() | [topic_name()], topic_name()) ->
        ok | no_return().
ensure_no_loopback(UpstreamTopics, DownstreamTopic) ->
  case lists:member(topic(DownstreamTopic), topics(UpstreamTopics)) of
    true  -> throw(direct_loopback);
    false -> ok
  end.

-spec insert_routes([route()]) -> ok.
insert_routes(Routes) ->
  true = ets:insert(?ETS, Routes),
  ok.

-spec is_configured_client_id(brod_client_id()) -> boolean().
is_configured_client_id(ClientId) ->
  brucke_config:is_configured_client_id(ClientId).

-spec validate_upstream_topics(brod_client_id(),
                               topic_name() | [topic_name()]) ->
                                  validation_result().
validate_upstream_topics(_ClientId, []) ->
  invalid_topic_name(upstream, []);
validate_upstream_topics(ClientId, Topic) when ?IS_VALID_TOPIC_NAME(Topic) ->
  validate_upstream_topic(ClientId, Topic);
validate_upstream_topics(ClientId, Topics0) when is_list(Topics0) ->
  case lists:partition(fun(T) -> ?IS_VALID_TOPIC_NAME(T) end, Topics0) of
    {Topics, []} ->
      [validate_upstream_topic(ClientId, T) || T <- Topics];
    {_, InvalidTopics} ->
      invalid_topic_name(upstream, InvalidTopics)
  end.

-spec validate_upstream_topic(brod_client_id(), topic_name()) ->
        [true | validation_result()].
validate_upstream_topic(ClientId, Topic) ->
  ClientIds = lookup_upstream_client_ids_by_topic(Topic),
  ClusterName = brucke_config:get_cluster_name(ClientId),
  lists:map(
    fun(Id) ->
      case ClusterName =:= brucke_config:get_cluster_name(Id) of
        true ->
          fmt("Duplicated route for upstream topic ~s in cluster ~s. "
              "This means you are trying to bridge one upstream topic to "
              "two or more downstream topics. If this is a valid use case "
              "(not misconfiguration), a workaround is to make a copy of the "
              "upstream cluster with a different name assigned.",
              [Topic, ClusterName]);
        false ->
          true
      end
    end, ClientIds).

-spec lookup_upstream_client_ids_by_topic(topic_name()) -> [brod_client_id()].
lookup_upstream_client_ids_by_topic(Topic) ->
  lists:foldl(
    fun(#route{upstream = {ClientId, Topic_}}, Acc) ->
      case Topic_ =:= topic(Topic) of
        true  -> [ClientId | Acc];
        false -> Acc
      end
    end, [], all()).

-spec invalid_topic_name(upstream | downstream, any()) -> validation_result().
invalid_topic_name(UpOrDown_stream, NameOrList) ->
  fmt("expecting ~p topic(s) to be (a list of) atom() | string() | binary()\n"
      "got: ~p", [UpOrDown_stream, NameOrList]).

%% @private Accept atom(), string(), or binary() as topic name,
%% unified to binary().
%% @end
-spec topic(topic_name()) -> kafka_topic().
topic(Topic) when is_atom(Topic)   -> topic(atom_to_list(Topic));
topic(Topic) when is_binary(Topic) -> Topic;
topic(Topic) when is_list(Topic)   -> list_to_binary(Topic).

-spec topics(topic_name() | [topic_name()]) -> [kafka_topic()].
topics(TopicName) when ?IS_VALID_TOPIC_NAME(TopicName) ->
  [topic(TopicName)];
topics(TopicNames) when is_list(TopicNames) ->
  [topic(T) || T <- TopicNames].

-spec fmt(string(), [term()]) -> binary().
fmt(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).

%%%_* Tests ====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

no_ets_leak_test() ->
  clean_setup(),
  L = ets:all(),
  ?assertNot(lists:member(?ETS, L)),
  try
    init([a|b])
  catch _ : _ ->
    ?assertEqual(L, ets:all())
  end.

client_not_configured_test() ->
  clean_setup(false),
  R0 = 
    [ {upstream_client, client_2}
    , {upstream_topics, topic_1}
    , {downstream_client, client_3}
    , {downstream_topic, topic_2}
    ],
  ok = init([R0]),
  ?assertEqual([], all()),
  ok = destroy().

bad_topic_name_test() ->
  clean_setup(),
  Base =
    [ {upstream_client, client_1}
    , {downstream_client, client_1}
    ],
  Route1 = [{upstream_topics, [topic_1]}, {downstream_topic, []} | Base],
  Route2 = [{upstream_topics, topic_1}, {downstream_topic, ["topic_x"]} | Base],
  Route3 = [{upstream_topics, []}, {downstream_topic, []} | Base],
  Route4 = [{upstream_topics, [[]]}, {downstream_topic, []} | Base],
  ok = init([Route1, Route2, Route3, Route4]),
  ?assertEqual([], all()),
  ok = destroy().

bad_routing_options_test() ->
  clean_setup(),
  R0 =
    [ {upstream_client, client_1}
    , {upstream_topics, topic_1}
    , {downstream_client, client_1}
    , {downstream_topic, topic_2}
    ],
  Routes = [ [{default_begin_offset, x} | R0]
           , [{repartitioning_strategy, x} | R0]
           , [{max_partitions_per_group_member, x} | R0]
           , [{"unknown_string", x} | R0]
           , [{unknown, x} | R0]
           , [{compression, x} | R0]
           ],
  ok = init(Routes),
  ?assertEqual([], all()),
  ok = destroy().

mandatory_attribute_missing_test() ->
  clean_setup(),
  R = [ {upstream_client, client_1}
      , {upstream_topics, topic_1}
      , {downstream_client, client_1}
      ],
  ok = init([R]),
  ?assertEqual([], all()),
  ok = destroy().

duplicated_source_test() ->
  clean_setup(),
  ValidRoute1 = [ {upstream_client, client_1}
                , {upstream_topics, [<<"topic_1">>, "topic_2"]}
                , {downstream_client, client_1}
                , {downstream_topic, <<"topic_3">>}
                ],
  ValidRoute2 = [ {upstream_client, client_1}
                , {upstream_topics, <<"topic_4">>}
                , {downstream_client, client_1}
                , {downstream_topic, <<"topic_3">>}
                ],
  DupeRoute = [ {upstream_client, client_1}
              , {upstream_topics, topic_1}
              , {downstream_client, client_1}
              , {downstream_topic, <<"topic_3">>}
              ],
  ok = init([ValidRoute1, ValidRoute2, DupeRoute]),
  ?assertMatch([ #route{upstream = {client_1, <<"topic_1">>}}
               , #route{upstream = {client_1, <<"topic_2">>}}
               , #route{upstream = {client_1, <<"topic_4">>}}
               ], all_sorted()),
  ?assertMatch(#route{upstream = {client_1, <<"topic_1">>}},
               lookup(client_1, <<"topic_1">>)),
  ?assertEqual(false, lookup(client_1, <<"unknown_topic">>)),
  ok = destroy().

direct_loopback_test() ->
  clean_setup(),
  Routes = [ [ {upstream_client, client_1}
             , {upstream_topics, topic_1}
             , {downstream_client, client_1}
             , {downstream_topic, topic_1}
             ]
           , [ {upstream_client, client_1}
             , {upstream_topics, topic_1}
             , {downstream_client, client_2}
             , {downstream_topic, topic_2}
             ]
           ],
  ok = init(Routes),
  ?assertMatch([#route{ upstream = {client_1, <<"topic_1">>}
                      , downstream = {client_2, <<"topic_2">>}
                      , options = #{}}],
               all()),
  ok = destroy().

bad_config_test() ->
  ?assertException(exit, bad_routes_config, init(<<"not a list">>)).

clean_setup() -> clean_setup(true).

clean_setup(IsConfiguredClientId) ->
  ok = destroy(),
  try
    meck:unload(brucke_config)
  catch _:_ ->
    ok
  end,
  meck:new(brucke_config, [no_passthrough_cover]),
  meck:expect(brucke_config, is_configured_client_id, 1, IsConfiguredClientId),
  meck:expect(brucke_config, get_cluster_name, 1, <<"group-id">>),
  ok.

all_sorted() -> lists:keysort(#route.upstream, all()).

topics_test() ->
  ?assertEqual([<<"topic_1">>], topics(topic_1)).

-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
