%%% -*- erlang -*-
%%%
%%% This file is part of couchbeam released under the MIT license. 
%%% See the NOTICE for more information.

%% @doc gen_changes CouchDB continuous changes consumer behavior
%% This behaviour allws you to create easily a server that consume 
%% Couchdb continuous changes

-module(gen_changes).

-include("couchbeam.hrl").

-behavior(gen_server).

-export([start_link/4]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([behaviour_info/1]).

-export([call/2,
         call/3,
         cast/2]).

-export([stop/1, get_seq/1]).


behaviour_info(callbacks) ->
    [{init, 1},
     {handle_change, 2},
     {handle_call, 3},
     {handle_cast, 2},
     {handle_info, 2},
     {terminate, 2}];
behaviour_info(_) ->
    undefined.

call(Name, Request) ->
    gen_server:call(Name, Request).

call(Name, Request, Timeout) ->
    gen_server:call(Name, Request, Timeout).

cast(Dest, Request) ->
    gen_server:cast(Dest, Request).

%% @doc create a gen_changes process as part of a supervision tree. 
%% The function should be called, directly or indirectly, by the supervisor.
%% @spec start_link(Module, Db::db(), Options::changesoptions(),
%%                  InitArgs::list()) -> term()
%%       changesoptions() = [changeoption()]
%%       changeoption() = {include_docs, string()} |
%%                  {filter, string()} |
%%                  {since, integer()|string()} |
%%                  {heartbeat, string()|boolean()}
start_link(Module, Db, Options, InitArgs) ->
    application:start(couchbeam),
    gen_server:start_link(?MODULE, [Module, Db, Options, InitArgs], []).

init([Module, Db, Options, InitArgs]) ->
    process_flag(trap_exit, true),
    case Module:init(InitArgs) of
        {ok, ModState} ->
            #db{server=Server, options=IbrowseOpts} = Db,
            Url = couchbeam:make_url(Server, [couchbeam:db_url(Db),
                    "/_changes"], [{feed, "continuous"}|Options]),
            case couchbeam:request_stream({self(), once}, get, Url, 
                    IbrowseOpts) of
            {ok, ReqId} ->
                {ok, #gen_changes_state{req_id=ReqId,
                                        mod=Module,
                                        modstate=ModState,
                                        db=Db,
                                        options=Options}};
            {error, Error} ->
                Module:terminate(Error, ModState),
                {stop, Error} 
            end;
        Error ->
            Error
    end.

stop(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, stop).

get_seq(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_seq).

handle_call(get_seq, _From, State=#gen_changes_state{seq=Seq}) ->
    {reply, Seq, State};
handle_call(Request, From,
            State=#gen_changes_state{mod=Module, modstate=ModState}) ->
    case Module:handle_call(Request, From, ModState) of
        {reply, Reply, NewModState} ->
            {reply, Reply, State#gen_changes_state{modstate=NewModState}};
        {reply, Reply, NewModState, A}
          when A =:= hibernate orelse is_number(A) ->
            {reply, Reply, State#gen_changes_state{modstate=NewModState}, A};
        {noreply, NewModState} ->
            {noreply, State#gen_changes_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_changes_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_changes_state{modstate=NewModState}};
        {stop, Reason, Reply, NewModState} ->
            {stop, Reason, Reply, State#gen_changes_state{modstate=NewModState}}
  end.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Msg, State=#gen_changes_state{mod=Module, modstate=ModState}) ->
    case Module:handle_cast(Msg, ModState) of
        {noreply, NewModState} ->
            {noreply, State#gen_changes_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_changes_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_changes_state{modstate=NewModState}}
    end.


handle_info({ibrowse_async_response_end, ReqId},
        State=#gen_changes_state{req_id=ReqId}) ->
        {stop, connection_closed, State};
handle_info({ibrowse_async_response, ReqId, {error,Error}},
        State=#gen_changes_state{req_id=ReqId}) ->
        {stop, {error, Error}, State};
handle_info({ibrowse_async_response, ReqId, Chunk},
        State=#gen_changes_state{mod=Module, modstate=ModState, req_id=ReqId}) ->
    Messages = [M || M <- re:split(Chunk, ",?\n", [trim]), M =/= <<>>],
    
    case handle_messages(Messages, State) of
        {ok, #gen_changes_state{complete=true}=State1} ->
            {stop, complete, State1};
        {ok, #gen_changes_state{row=undefined}=State1} ->
            {noreply, State1};
        {ok, #gen_changes_state{row=Row}=State1} ->
            Seq = couchbeam_doc:get_value(<<"seq">>, Row),
            State2 = State1#gen_changes_state{seq=Seq},

            case catch Module:handle_change(Row, ModState) of
                {noreply, NewModState} ->
                    {noreply, State2#gen_changes_state{modstate=NewModState}};
                {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
                    {noreply, State2#gen_changes_state{modstate=NewModState}, A};
                {stop, Reason, NewModState} ->
                    {stop, Reason, State2#gen_changes_state{modstate=NewModState}}
            end
    end;
handle_info({ibrowse_async_headers, ReqId, Status, Headers},
        State=#gen_changes_state{req_id=ReqId}) ->

    if Status =/= "200" ->
            handle_info({error, {Status, Headers}}, State);
        true ->
            ibrowse:stream_next(State#gen_changes_state.req_id),
            {noreply, State}
    end;

handle_info(Info, State=#gen_changes_state{mod=Module, modstate=ModState}) ->
    case Module:handle_info(Info, ModState) of
        {noreply, NewModState} ->
            {noreply, State#gen_changes_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_changes_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_changes_state{modstate=NewModState}}
    end.

code_change(_OldVersion, State, _Extra) ->
    %% TODO:  support code changes?
    {ok, State}.

terminate(Reason, #gen_changes_state{mod=Module, modstate=ModState}) ->
    Module:terminate(Reason, ModState),
    ok.

handle_messages([], State) ->
    ibrowse:stream_next(State#gen_changes_state.req_id),
    {ok, State};
handle_messages([<<"{\"last_seq\":", _/binary>>], State) ->
    %% end of continuous response
    ibrowse:stream_next(State#gen_changes_state.req_id),
    {ok, State#gen_changes_state{complete=true}};
handle_messages([Chunk|Rest], State) ->
    #gen_changes_state{partial_chunk=Partial}=State,
    NewState = try
        Row = couchbeam_changes:decode_row(<<Partial/binary, Chunk/binary>>),
        Empty= <<"">>,
        State#gen_changes_state{partial_chunk=Empty, row=Row}
    catch
    throw:{invalid_json, Bad} ->
        State#gen_changes_state{partial_chunk = Bad}
    end,
    handle_messages(Rest, NewState).


