%% facts_bank.erl
%% This file is an implementation of a facts bank that acts as a resources manager Actor
%% for the normative relations actors. There should be one Facts bank per entity.
%% The nature of Erlang will make distributed execution and communicaton between actos easy.
%%
%%
%% Functionalities:
%% - Store Facts
%% - Recieve Facts or derive them
%% - Signal Facts to subscribers
%% - Post conditions handling of normative relations: Creates | terminates
%% - 


-module(facts_bank).
-behaviour(gen_server).

-export([start_link/0]).
-export([add_fact/2, remove_fact/2, holds/2, subscribe/3]).
-export([register_act/2, lookup_act/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% In eFLINT a fact can be data unit or identefied by a tuple of data
-type person() :: string().
-type fact() :: atom() | tuple().

-type facts_map() :: #{
                     parent => sets:set(person()),
                     child => sets:set(person()),
                     %% defined Facts holds if exist
                     natural_parent => sets:set({person(), person()}),
                     adoptive_parent => sets:set({person(), person()})
                     %% TODO legal_parent (derived facts)
                     % legal_parent => sets:set({{person(), person()}, function => boolean} )
                    }.

-record(state, {
    %% Postulated facts: FactKey => boolean()
    facts       :: facts_map(),
 
    % %% Derived fact rules: FactKey => fun(Facts) -> boolean()
    % %% The function receives the current facts map and returns true/false.
    % derived     :: #{term() => fun((#{term() => boolean()}) -> boolean())},
 
    %% Subscribers: FactKey => [pid()]
    %% A pid in this list receives a push when that fact changes.
    subscribers :: #{term() => [pid()]},
 
    %% Act registry: ActName => pid()
    %% Act processes register here on startup so any process can reach
    %% them by name without using whereis/1 or global registries.
    %% Works transparently across distributed Erlang nodes.
    acts        :: #{atom() => pid()}
}).


start_link() ->
  gen_server:start_link({local, facts_bank}, ?MODULE, [], []).


-spec add_fact(atom(), fact()) -> ok.
add_fact(Fact, Data) ->
  gen_server:call(facts_bank, {add_fact, Fact, Data}).


-spec remove_fact(atom(), fact()) -> ok.
remove_fact(Fact, Data) ->
  gen_server:call(facts_bank, {remove_fact, Fact, Data}).

-spec holds(atom(), fact()) -> boolean().
holds(Fact, Data) ->
    gen_server:call(facts_bank, {holds, Fact, Data}).


-spec subscribe(atom(), fact(), pid()) -> ok.
subscribe(Fact, Data, Pid) ->
    gen_server:call(facts_bank, {subscribe, Fact, Data, Pid}).


%% initial way to register PID of Act procs (preperation for Distributed nodes)
-spec register_act(atom(), pid()) -> ok.
register_act(ActName, Pid) ->
    gen_server:call(facts_bank, {register_act, ActName, Pid}).
 
-spec lookup_act(atom()) -> {ok, pid()} | {error, not_found}.
lookup_act(ActName) ->
    gen_server:call(facts_bank, {lookup_act, ActName}).


%% gen_server callbacks
%%
%% here comes the intitial facts
init([]) ->
    {ok, #state{
        facts       = #{
                        parent => sets:new(),
                        child => sets:new(),
                        natural_parent => sets:new(),
                        adoptive_parent => sets:new()
                       },
        % derived     = #{},
        subscribers = #{},
        acts        = #{}
    }}.
 
handle_call({add_fact, Fact, Data}, _From, State) ->
    case maps:is_key(Fact, State#state.facts) of
      false ->
        {reply, {error, {unknown_fact, Fact}}, State};
      true ->
        NewFacts = maps:update_with(
                     Fact,
                     fun(S) -> sets:add_element(Data, S) end, 
                     State#state.facts
                    ),
        NewState = State#state{facts = NewFacts},
        %% TODO notify for Holds When, need more thoght
        % push(fact_added, Fact, NewState),
        {reply, ok, NewState}
    end;
 
handle_call({remove_fact, Fact, Data}, _From, State) ->
    %% TODO
    {reply, ok, State};
 
%% Derived fact — evaluate the registered function against current facts
handle_call({holds, Fact, Data}, _From, State) ->
    Result = case maps:find(Fact, State#state.facts) of
        {ok, Set} -> sets:is_element(Data, Set);
        error     -> false
    end,
    {reply, Result, State}; 

% handle_call({subscribe, Fact, Pid}, _From, State) ->
%     Current = maps:get(Fact, State#state.subscribers, []),
%     NewSubs = maps:put(Fact, [Pid | Current], State#state.subscribers),
%     {reply, ok, State#state{subscribers = NewSubs}};
 
% handle_call({register_derived, FactKey, Fun}, _From, State) ->
%     NewDerived = maps:put(FactKey, Fun, State#state.derived),
%     {reply, ok, State#state{derived = NewDerived}};
 
handle_call({register_act, ActName, Pid}, _From, State) ->
    io:format("[facts_bank] registered act ~w => ~w~n", [ActName, Pid]),
    NewActs = maps:put(ActName, Pid, State#state.acts),
    {reply, ok, State#state{acts = NewActs}};
 
handle_call({lookup_act, ActName}, _From, State) ->
    Result = case maps:find(ActName, State#state.acts) of
        {ok, Pid} -> {ok, Pid};
        error     -> {error, not_found}
    end,
    {reply, Result, State};
 
handle_call(all_acts, _From, State) ->
    {reply, State#state.acts, State}.
 
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
 

% notify PID proc with fact data insertion
% push(Event, FactKey, #state{subscribers = Subs}) ->
%     Pids = maps:get(FactKey, Subs, []),
%     lists:foreach(fun(Pid) -> Pid ! {Event, FactKey} end, Pids).

