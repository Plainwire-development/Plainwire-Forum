-module(plainwire_ws_handler).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req0, _Opts) ->
    case plainwire_auth:current_user(Req0) of
        {ok, User} ->
            UserId = maps:get(id, User),
            {cowboy_websocket, Req0, #{user_id => UserId}, #{idle_timeout => 60000}};
        anonymous ->
            Req = cowboy_req:reply(
                401,
                #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                <<"login required">>,
                Req0
            ),
            %% Normal HTTP handler return. The old code returned unbound State here.
            {ok, Req, #{}}
    end.

websocket_init(State = #{user_id := UserId}) ->
    plainwire_hub:register(UserId, self()),
    {ok, State}.

websocket_handle({text, <<"ping">>}, State) ->
    {reply, {text, <<"pong">>}, State};
websocket_handle({text, _Text}, State) ->
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({plainwire_event, Payload}, State) when is_binary(Payload) ->
    %% Cowboy 2 websocket callbacks must use {reply, Frame, State}.
    {reply, {text, Payload}, State};
websocket_info({plainwire_event, Payload}, State) ->
    {reply, {text, jsx:encode(Payload)}, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, _State) ->
    plainwire_hub:unregister(self()),
    ok.
