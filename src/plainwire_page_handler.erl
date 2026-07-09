-module(plainwire_page_handler).
-export([init/2]).

init(Req0, State) ->
    PrivDir = code:priv_dir(plainwire_forum),
    File = filename:join([PrivDir, "static", "index.html"]),
    case file:read_file(File) of
        {ok, Html} ->
            Req = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Html, Req0),
            {ok, Req, State};
        {error, _} ->
            Req = cowboy_req:reply(500, #{<<"content-type">> => <<"text/plain">>}, <<"index.html missing">>, Req0),
            {ok, Req, State}
    end.
