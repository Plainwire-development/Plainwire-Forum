-module(plainwire_hub).
-behaviour(gen_server).

-export([start_link/0, register/2, unregister/1, broadcast/1, send_user/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {clients = #{}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(UserId, Pid) -> gen_server:cast(?MODULE, {register, UserId, Pid}).
unregister(Pid) -> gen_server:cast(?MODULE, {unregister, Pid}).
broadcast(Event) -> gen_server:cast(?MODULE, {broadcast, Event}).
send_user(UserId, Event) -> gen_server:cast(?MODULE, {send_user, UserId, Event}).

init([]) -> {ok, #state{}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.

handle_cast({register, UserId, Pid}, #state{clients = Clients0} = State) ->
    monitor(process, Pid),
    Clients = Clients0#{Pid => UserId},
    {noreply, State#state{clients = Clients}};
handle_cast({unregister, Pid}, #state{clients = Clients0} = State) ->
    {noreply, State#state{clients = maps:remove(Pid, Clients0)}};
handle_cast({broadcast, Event}, #state{clients = Clients} = State) ->
    Payload = encode(Event),
    maps:foreach(fun(Pid, _UserId) -> Pid ! {plainwire_event, Payload} end, Clients),
    {noreply, State};
handle_cast({send_user, UserId, Event}, #state{clients = Clients} = State) ->
    Payload = encode(Event),
    maps:foreach(fun(Pid, CUserId) ->
        case CUserId =:= UserId of
            true -> Pid ! {plainwire_event, Payload};
            false -> ok
        end
    end, Clients),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{clients = Clients0} = State) ->
    {noreply, State#state{clients = maps:remove(Pid, Clients0)}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

encode(Event) -> jsx:encode(Event).
