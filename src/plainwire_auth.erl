-module(plainwire_auth).
-export([current_user/1, session_token/1, set_session_cookie/3, clear_cookie/1]).

session_token(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    proplists:get_value(<<"plainwire_session">>, Cookies, undefined).

current_user(Req) ->
    case plainwire_db:session_user(session_token(Req)) of
        {ok, User} -> {ok, User};
        none -> anonymous;
        {error, _} -> anonymous
    end.

set_session_cookie(Req0, Token, ExpiresAt) ->
    MaxAge = max(0, ExpiresAt - plainwire_util:now()),
    cowboy_req:set_resp_cookie(<<"plainwire_session">>, Token, Req0, #{
        path => <<"/">>,
        max_age => MaxAge,
        http_only => true,
        same_site => lax,
        secure => plainwire_config:cookie_secure()
    }).

clear_cookie(Req0) ->
    cowboy_req:set_resp_cookie(<<"plainwire_session">>, <<"">>, Req0, #{
        path => <<"/">>,
        max_age => 0,
        http_only => true,
        same_site => lax,
        secure => plainwire_config:cookie_secure()
    }).
