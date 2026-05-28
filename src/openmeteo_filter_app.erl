%%%-------------------------------------------------------------------
%%% @doc Open-Meteo weather forecast agent.
%%%
%%% Fetches current weather for a given latitude/longitude using the
%%% Open-Meteo API (no API key required).
%%%
%%% Expected body fields:
%%%   latitude  (float or binary, e.g. 48.85)
%%%   longitude (float or binary, e.g. 2.35)
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(openmeteo_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(FORECAST_URL,
    "https://api.open-meteo.com/v1/forecast"
    "?current_weather=true&latitude=~s&longitude=~s").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"weather">>, <<"openmeteo">>,
                                      <<"forecast">>, <<"meteorology">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case openmeteo_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(openmeteo_filter_query_listener),
    catch em_pop_sup:stop_node(openmeteo_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(openmeteo_filter, pop_port,   9482),
    QueryPort = application:get_env(openmeteo_filter, query_port, 9483),
    Seeds     = application:get_env(openmeteo_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(openmeteo_filter),
    catch cowboy:stop_listener(openmeteo_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(openmeteo_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => openmeteo_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(openmeteo_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[openmeteo_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Forecast fetching
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Lat, Lon, Timeout} = extract_params(JsonBinary),
    fetch_weather(Lat, Lon, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Lat     = to_string(maps:get(<<"latitude">>,  Map, maps:get(<<"lat">>, Map, undefined))),
            Lon     = to_string(maps:get(<<"longitude">>, Map, maps:get(<<"lon">>, Map, undefined))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Lat, Lon, Timeout};
        _ ->
            {undefined, undefined, 10}
    catch
        _:_ -> {undefined, undefined, 10}
    end.

to_string(undefined)              -> undefined;
to_string(V) when is_binary(V)    -> binary_to_list(V);
to_string(V) when is_float(V)     -> float_to_list(V, [{decimals, 6}]);
to_string(V) when is_integer(V)   -> integer_to_list(V).

fetch_weather(undefined, _, _) -> [];
fetch_weather(_, undefined, _) -> [];
fetch_weather(Lat, Lon, Timeout) ->
    Url = lists:flatten(io_lib:format(?FORECAST_URL, [Lat, Lon])),
    case httpc:request(get, {Url, []},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_weather(Lat, Lon, Body);
        _ ->
            []
    end.

parse_weather(Lat, Lon, JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"current_weather">> := W} when is_map(W) ->
            Temp      = maps:get(<<"temperature">>,   W, null),
            Wind      = maps:get(<<"windspeed">>,     W, null),
            WindDir   = maps:get(<<"winddirection">>, W, null),
            Code      = maps:get(<<"weathercode">>,   W, null),
            Time      = maps:get(<<"time">>,          W, <<"">>),
            Resume    = format_resume(Temp, Wind, WindDir, Code),
            MapUrl    = lists:flatten(io_lib:format(
                "https://open-meteo.com/en/docs#latitude=~s&longitude=~s",
                [Lat, Lon])),
            {true, Embryo} = build_embryo(Lat, Lon, Time, Resume, MapUrl),
            [Embryo];
        _ ->
            []
    catch
        _:_ -> []
    end.

format_resume(Temp, Wind, WindDir, Code) ->
    Parts = [
        format_val("temperature", Temp, "°C"),
        format_val("wind",        Wind, " km/h"),
        format_val("direction",   WindDir, "°"),
        format_code(Code)
    ],
    string:join([P || P <- Parts, P =/= ""], ", ").

format_val(_Label, null, _Unit) -> "";
format_val(Label, Val, Unit) when is_float(Val) ->
    lists:flatten(io_lib:format("~s: ~.1f~s", [Label, Val, Unit]));
format_val(Label, Val, Unit) when is_integer(Val) ->
    lists:flatten(io_lib:format("~s: ~p~s", [Label, Val, Unit])).

format_code(null) -> "";
format_code(Code) ->
    lists:flatten(io_lib:format("code: ~p", [Code])).

build_embryo(Lat, Lon, Time, Resume, MapUrl) ->
    {true, #{
        <<"properties">> => #{
            <<"url">>       => list_to_binary(MapUrl),
            <<"resume">>    => list_to_binary(Resume),
            <<"latitude">>  => list_to_binary(Lat),
            <<"longitude">> => list_to_binary(Lon),
            <<"time">>      => Time,
            <<"source">>    => <<"api.open-meteo.com">>
        }
    }}.
