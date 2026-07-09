-module(plainwire_api_handler).
-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    {Status, Payload, Req1} = handle(Method, Path, Req0),
    Req = reply_json(Status, Payload, Req1),
    {ok, Req, State}.

handle(<<"POST">>, [<<"register">>], Req0) ->
    {Data, Req} = read_json(Req0),
    Username = get(Data, <<"username">>, <<>>),
    Display = get(Data, <<"display_name">>, Username),
    Password = get(Data, <<"password">>, <<>>),
    case plainwire_db:register_user(Username, Display, Password) of
        {ok, User} ->
            #{id := UserId} = User,
            {ok, Token, Expires} = plainwire_db:create_session(UserId),
            Req1 = plainwire_auth:set_session_cookie(Req, Token, Expires),
            {201, #{ok => true, user => User}, Req1};
        {error, Reason} -> {400, #{ok => false, error => Reason}, Req}
    end;
handle(<<"POST">>, [<<"login">>], Req0) ->
    {Data, Req} = read_json(Req0),
    Username = get(Data, <<"username">>, <<>>),
    Password = get(Data, <<"password">>, <<>>),
    case plainwire_db:login_user(Username, Password) of
        {ok, User} ->
            #{id := UserId} = User,
            {ok, Token, Expires} = plainwire_db:create_session(UserId),
            Req1 = plainwire_auth:set_session_cookie(Req, Token, Expires),
            {200, #{ok => true, user => User}, Req1};
        {error, Reason} -> {401, #{ok => false, error => Reason}, Req}
    end;
handle(<<"POST">>, [<<"logout">>], Req0) ->
    Req = plainwire_auth:clear_cookie(Req0),
    {200, #{ok => true}, Req};
handle(<<"GET">>, [<<"me">>], Req) ->
    case plainwire_auth:current_user(Req) of
        {ok, User} ->
            #{id := UserId} = User,
            Counts = case plainwire_db:counts(UserId) of {ok, C} -> C; _ -> #{} end,
            {200, #{ok => true, user => User, counts => Counts}, Req};
        anonymous -> {200, #{ok => true, user => null, counts => #{}}, Req}
    end;
handle(<<"GET">>, [<<"forums">>], Req) ->
    case plainwire_db:list_forums() of
        {ok, Forums} -> {200, #{ok => true, forums => Forums}, Req};
        {error, Reason} -> {500, #{ok => false, error => Reason}, Req}
    end;
handle(<<"GET">>, [<<"threads">>], Req) ->
    Qs = cowboy_req:parse_qs(Req),
    ForumId = qs(<<"forum">>, Qs, <<"all">>),
    Search = qs(<<"q">>, Qs, <<>>),
    case plainwire_db:list_threads(ForumId, Search) of
        {ok, Threads} -> {200, #{ok => true, threads => Threads}, Req};
        {error, Reason} -> {400, #{ok => false, error => Reason}, Req}
    end;
handle(<<"POST">>, [<<"threads">>], Req0) ->
    auth(Req0, fun(User, Req1) ->
        {Data, Req} = read_json(Req1),
        #{id := UserId} = User,
        case plainwire_db:create_thread(UserId, get(Data, <<"forum_id">>, undefined), get(Data, <<"title">>, <<>>), get(Data, <<"body">>, <<>>)) of
            {ok, ThreadId} ->
                plainwire_hub:broadcast(#{type => <<"thread_created">>, thread_id => ThreadId}),
                {201, #{ok => true, thread_id => ThreadId}, Req};
            {error, Reason} -> {400, #{ok => false, error => Reason}, Req}
        end
    end);
handle(<<"GET">>, [<<"threads">>, ThreadId], Req) ->
    MaybeUser = plainwire_auth:current_user(Req),
    UserId = case MaybeUser of {ok, #{id := Id}} -> Id; _ -> 0 end,
    case plainwire_db:get_thread(UserId, ThreadId) of
        {ok, Result} -> {200, maps:merge(#{ok => true}, Result), Req};
        {error, Reason} -> {404, #{ok => false, error => Reason}, Req}
    end;
handle(<<"POST">>, [<<"threads">>, ThreadId, <<"replies">>], Req0) ->
    auth(Req0, fun(User, Req1) ->
        {Data, Req} = read_json(Req1),
        #{id := UserId} = User,
        case plainwire_db:create_reply(UserId, ThreadId, get(Data, <<"body">>, <<>>)) of
            {ok, ReplyId} ->
                plainwire_hub:broadcast(#{type => <<"reply_created">>, thread_id => to_int(ThreadId), reply_id => ReplyId}),
                {201, #{ok => true, reply_id => ReplyId}, Req};
            {error, Reason} -> {400, #{ok => false, error => Reason}, Req}
        end
    end);
handle(<<"GET">>, [<<"conversations">>], Req0) ->
    auth(Req0, fun(User, Req) ->
        #{id := UserId} = User,
        case plainwire_db:list_conversations(UserId) of
            {ok, Conversations} -> {200, #{ok => true, conversations => Conversations}, Req};
            {error, Reason} -> {500, #{ok => false, error => Reason}, Req}
        end
    end);
handle(<<"GET">>, [<<"messages">>, Username], Req0) ->
    auth(Req0, fun(User, Req) ->
        #{id := UserId} = User,
        case plainwire_db:get_messages(UserId, Username) of
            {ok, Result} -> {200, maps:merge(#{ok => true}, Result), Req};
            {error, Reason} -> {404, #{ok => false, error => Reason}, Req}
        end
    end);
handle(<<"POST">>, [<<"messages">>], Req0) ->
    auth(Req0, fun(User, Req1) ->
        {Data, Req} = read_json(Req1),
        #{id := UserId} = User,
        To = get(Data, <<"to">>, <<>>),
        Body = get(Data, <<"body">>, <<>>),
        case plainwire_db:send_message(UserId, To, Body) of
            {ok, Result} ->
                #{recipient := #{id := ToId}} = Result,
                plainwire_hub:send_user(ToId, #{type => <<"message_created">>, from => maps:get(username, User), to => To}),
                plainwire_hub:send_user(UserId, #{type => <<"message_created">>, to => To}),
                {201, maps:merge(#{ok => true}, Result), Req};
            {error, Reason} -> {400, #{ok => false, error => Reason}, Req}
        end
    end);
handle(<<"GET">>, [<<"notifications">>], Req0) ->
    auth(Req0, fun(User, Req) ->
        #{id := UserId} = User,
        {ok, Items} = plainwire_db:notifications(UserId),
        {ok, Counts} = plainwire_db:counts(UserId),
        {200, #{ok => true, notifications => Items, counts => Counts}, Req}
    end);
handle(<<"POST">>, [<<"notifications">>, <<"read">>], Req0) ->
    auth(Req0, fun(User, Req) ->
        #{id := UserId} = User,
        ok = plainwire_db:mark_notifications_read(UserId),
        plainwire_hub:send_user(UserId, #{type => <<"notifications_read">>}),
        {200, #{ok => true}, Req}
    end);
handle(<<"GET">>, [<<"users">>, Username], Req) ->
    case plainwire_db:user_by_username(Username) of
        {ok, User} -> {200, #{ok => true, user => User}, Req};
        none -> {404, #{ok => false, error => <<"User not found.">>}, Req}
    end;
handle(_Method, _Path, Req) ->
    {404, #{ok => false, error => <<"Not found.">>}, Req}.

auth(Req, Fun) ->
    case plainwire_auth:current_user(Req) of
        {ok, User} -> Fun(User, Req);
        anonymous -> {401, #{ok => false, error => <<"Login required.">>}, Req}
    end.

read_json(Req0) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0, #{length => 1048576, period => 5000}),
    Data = case Body of
        <<>> -> #{};
        _ -> try jsx:decode(Body, [return_maps]) catch _:_ -> #{} end
    end,
    {Data, Req}.

get(Map, Key, Default) when is_map(Map) -> maps:get(Key, Map, Default);
get(_, _, Default) -> Default.

qs(Key, Qs, Default) ->
    proplists:get_value(Key, Qs, Default).

reply_json(Status, Payload, Req0) ->
    Body = jsx:encode(Payload),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>
    }, Body, Req0).

to_int(Bin) ->
    try list_to_integer(binary_to_list(Bin)) catch _:_ -> 0 end.
