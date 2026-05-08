

-module(voting).


-export([run/0]).
%% procs functions need to be exported
-export([cast_vote_loop/0, enable_vote_loop/0, declare_winner_loop/0]).

%%% NOTES:
%%%  - Predicate needs to subscribe to winner(candidate)
%%%  - also own process
%%%

%% Let's see types later
% -type person() :: string().
% -type parent() :: person().
% -type child() :: person().
% % In eFLINT a fact can be data unit or identefied by a tuple of data GENERAL
% -type fact() :: atom() | tuple().

factsbank_init() ->
  ets:new(facts,       [set, public, named_table]),
  ets:new(subscribers, [bag, public, named_table]),
  ets:new(duties,      [set, public, named_table]).

holds(Fact) -> ets:member(facts, Fact).

%% {Fact, Arguments}
add_fact(Fact) ->
    case ets:insert_new(facts, {Fact}) of
        true  -> notify(Fact, created);
        false -> ok      %% fact already held — no change, no notification
    end,
    ok.

terminate_fact(Fact) ->
    case ets:lookup(facts, Fact) of
        [] ->
            ok;          %% didn't hold — paper says this is a no-op
        [_] ->
            ets:delete(facts, Fact),
            notify(Fact, terminated)
    end,
    ok.

subscribe(FactKey, Pid) ->
    ets:insert(subscribers, {FactKey, Pid}),
    ok.

%% do this after a duty is terminated for example
unsubscribe_all(Pid) ->
    ets:match_delete(subscribers, {'_', Pid}),
    ok.
 
notify(Fact, Change) ->
    Pids = [P || {_, P} <- ets:lookup(subscribers, Fact)],
    [Pid ! {fact_changed, Fact, Change} || Pid <- Pids],
    ok.


register_duty(Name, Args, Pid) -> ets:insert(duties, {{Name, Args}, Pid}).

unregister_duty(Name, Args) -> ets:delete(duties, {Name, Args}).
 
lookup_duty(Name, Args) ->
    case ets:lookup(duties, {Name, Args}) of
        [{_, Pid}] -> {ok, Pid};
        []         -> not_found
    end.

%%% 
% Act cast-vote
%   Actor citizen 
%   Recipient administrator
%   Related to candidate
%   Conditioned by voter(citizen) && !has-voted(citizen)
%   Creates vote(citizen,candidate)
%   Terminates cast-vote-duty(citizen,administrator)
cast_vote_loop() ->
  receive
    {trigger, {Citizen, Admin}, Candidate, From} ->
      ConditionedBy = holds({voter, Citizen}) andalso not holds({has_voted, Citizen}),
      case ConditionedBy of
        false ->
          From ! {cast_vote_result, disabled},
          cast_vote_loop();
        true ->
          io:format("DEBUG: action triggered and enabled"),
          %% Creates
          add_fact({vote, {Citizen, Candidate}}),
          %% Terminates
          case lookup_duty(cast-vote-duty, {Citizen, Admin}) of
            not_found ->
              From ! {cast_vote_result, {enabled, no_duty}};
            {ok, DutyPid} ->
              DutyPid ! terminate,
              From ! {cast_vote_result, {enabled, duty_terminated}}
          end,
          cast_vote_loop(),
          ok
      end;
    stop ->
      ok
  end.



% Act enable-vote
%   Actor administrator
%   Recipient citizen
%   Conditioned by !voter(citizen) && !vote-concluded()
%   Creates voter(citizen),
%           cast-vote-duty(citizen,administrator),
%           (Foreach candidate : cast-vote(citizen,administrator,candidate))
enable_vote_loop() ->
  receive
    {trigger, {admin, citizen}, from} ->
      ConditionedBy = not holds({voter, Citizen}) andalso not holds({vote_concluded,}),
      case ConditionedBy of
        false -> 
          From ! {enable_vote_result, disabled},
          enable_vote_loop();
        true ->
          add_fact({voter, Citizen}),
          %% notice cast-vote doesnt have violated
          Pid = spawn(?MODULE, duty_loop,
                      [cast_vote_duty, {Citizen, Admin}, false]),
          register_duty(cast_vote_duty, {Citizen, Admin}, Pid),
          From ! {enable_vote_result, {enabled_duty, Pid}},
          %% TODO  I think I should just create these fact, so they can be executed
          %% But I don't know if we need to treat the configuration like this, but I can
%           (Foreach candidate : cast-vote(citizen,administrator,candidate))
          enable_vote_loop();
  .

declare_winner_loop() ->
    {trigger, {admin, candidate}, from} ->
      ConditionedBy = not holds({vote_concluded,}),
      case ConditionedBy of
        false -> 
          From ! {declare_winner_result, disabled},
          declare_winner_loop();
        true ->
          Votes = ets:match_object(facts, {vote, '_'}),
          lists:foreach(fun(Vote) ->
                            io:format("Vote Entry: ~p~n", [Vote])
                        end, Votes)
          %% create winner(candidate)


  ok.


run() ->
  ok.
