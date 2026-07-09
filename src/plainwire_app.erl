-module(plainwire_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% Start DB/hub first so early HTTP requests cannot race the supervisor.
    {ok, SupPid} = plainwire_sup:start_link(),
    Port = plainwire_config:port(),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", plainwire_page_handler, []},
            {"/assets/[...]", cowboy_static, {priv_dir, plainwire_forum, "static"}},
            {"/ws", plainwire_ws_handler, []},
            {"/api/[...]", plainwire_api_handler, []},
            {"/[...]", plainwire_page_handler, []}
        ]}
    ]),
    case cowboy:start_clear(plainwire_http, [{port, Port}], #{
        env => #{dispatch => Dispatch},
        stream_handlers => [cowboy_stream_h]
    }) of
        {ok, _ListenerPid} ->
            io:format("Plainwire listening on http://0.0.0.0:~p~n", [Port]),
            {ok, SupPid};
        {error, Reason} ->
            exit({plainwire_http_start_failed, Reason})
    end.

stop(_State) ->
    cowboy:stop_listener(plainwire_http),
    ok.
