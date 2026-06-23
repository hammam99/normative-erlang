%%% eflint.erl
%%% eFLINT runtime engine for Erlang translations.
%%%
%%% Single module covering the full runtime:
%%%   Section 1 — Initialization
%%%   Section 2 — Fact storage (postulated, derived, schemas, placeholders)
%%%   Section 3 — Act engine (generic act loop, pre/post checks, execution)
%%%   Section 4 — Duty engine (generic duty loop, violation checks)
%%%   Section 5 — Debug helpers

-module(eflint).

-export([
    %% 1. Init
    init/0,

    %% 2. Facts
    register_schema/2,
    register_type/2,
    register_derivation/2,
    register_predicate/2,
    canonical_type/1,
    add/2,
    terminate/2,
    holds/2,
    holds_predicate/1,
    all/1,
    count/1,
    count/2,
    get_field/2,
    from_key/2,
    exists/2,

    %% 3. Acts
    act_loop/1,
    trigger/2,
    act_enabled/2,

    %% 4. Duties
    duty_loop/1,
    duty_key/1,
    register_duty/2,
    unregister_duty/1,
    lookup_duty/1,
    is_violated/1,

    %% 5. Debug
    dump/1
]).

%%%======================================================================
%%% 1. Initialization
%%%======================================================================

init() ->
    ets:new(facts,       [set, public, named_table]),
    ets:new(schemas,     [set, public, named_table]),
    ets:new(types,       [set, public, named_table]),
    ets:new(derivations, [set, public, named_table]),
    ets:new(duties,      [set, public, named_table]),
    ets:new(violations,  [set, public, named_table]),
    ets:new(subscribers, [bag, public, named_table]),
    ok.

%%%======================================================================
%%% 2. Fact storage
%%%======================================================================

%% --- Schema & type registration ---

%% Register field names for a compound fact type.
%%   eflint:register_schema(application, [citizen, permit_type]).
register_schema(FactType, Fields) when is_atom(FactType), is_list(Fields) ->
    ets:insert(schemas, {FactType, Fields}),
    ok.

%% Register a placeholder → canonical type mapping.
%%   eflint:register_type(parent, person).
register_type(Placeholder, CanonicalType) ->
    ets:insert(types, {Placeholder, CanonicalType}),
    ok.

%% Resolve a placeholder to its base type.
canonical_type(Name) ->
    case ets:lookup(types, Name) of
        [{Name, Name}]   -> Name;
        [{Name, Deeper}] -> canonical_type(Deeper);
        []               -> Name
    end.

%% Register a derived fact (Holds when).
%%   eflint:register_derivation(legal_parent, fun({Parent, Child}) -> ... end).
register_derivation(FactType, Fun) when is_atom(FactType), is_function(Fun, 1) ->
    ets:insert(derivations, {FactType, Fun}),
    ok.

%% --- Fact operations ---

%% Add a postulated fact.
%%   eflint:add(person, "Alice").
%%   eflint:add(application, {"Chloe", "solar panels"}).
add(FactType, Value) when not is_tuple(Value) ->
    ets:insert(facts, {{FactType, Value}, true}),
    notify_subscribers({added, FactType, Value}),
    ok;
add(FactType, Values) when is_tuple(Values) ->
    Key = list_to_tuple([FactType | tuple_to_list(Values)]),
    ets:insert(facts, {Key, true}),
    notify_subscribers({added, FactType, Values}),
    ok.

%% Terminate a postulated fact.
terminate(FactType, Value) when not is_tuple(Value) ->
    ets:delete(facts, {FactType, Value}),
    notify_subscribers({terminated, FactType, Value}),
    ok;
terminate(FactType, Values) when is_tuple(Values) ->
    Key = list_to_tuple([FactType | tuple_to_list(Values)]),
    ets:delete(facts, Key),
    notify_subscribers({terminated, FactType, Values}),
    ok.

subscribe_fact(FactType, Value, Pid) when not is_tuple(Value) ->
    ets:insert(subscribers, {{FactType, Value}, Pid}),
    ok;
subscribe_fact(FactType, Values, Pid) when is_tuple(Values) ->
    FactKey = list_to_tuple([FactType | tuple_to_list(Values)]),
    ets:insert(subscribers, {FactKey, Pid}),
    ok.

%% do this after a duty is terminated for example
unsubscribe_duty_facts(Pid) ->
    ets:match_delete(subscribers, {'_', Pid}),
    ok.

%% Notify all active duty processes that a fact changed.
notify_duties(_Change) ->
    Duties = ets:tab2list(duties),
    Refs = lists:map(fun({_Key, Pid}) ->
        Ref = monitor(process, Pid),
        Pid ! {fact_changed, self(), Ref},
        Ref
    end, Duties),
    lists:foreach(fun(Ref) ->
        receive
            {fact_changed_ack, Ref} -> demonitor(Ref, [flush]);
            {'DOWN', Ref, process, _, _} -> ok
        end
    end, Refs).

%% Notify all subscribers of a fact change.
notify_subscribers(_Change) ->
    Subscribers = ets:tab2list(subscribers),
    Refs = lists:map(fun({_Key, Pid}) ->
        Ref = monitor(process, Pid),
        Pid ! {fact_changed, self(), Ref},
        Ref
    end, Subscribers),
    lists:foreach(fun(Ref) ->
        receive
            {fact_changed_ack, Ref} -> demonitor(Ref, [flush]);
            {'DOWN', Ref, process, _, _} -> ok
        end
    end, Refs).

%% Check if a fact holds (exact match, derived or postulated).
%%   eflint:holds(person, "Alice").
%%   eflint:holds(application, {"Chloe", "solar panels"}).
%%   eflint:holds(parent, "Alice").  → resolves to person via canonical_type
holds(FactType, Value) ->
    case ets:lookup(derivations, FactType) of
        [{FactType, Fun}] ->
            Fun(Value);
        [] ->
            Resolved = canonical_type(FactType),
            Key = case is_tuple(Value) of
                true  -> list_to_tuple([Resolved | tuple_to_list(Value)]);
                false -> {Resolved, Value}
            end,
            ets:member(facts, Key)
    end.

%% Return all fact tuples of a given type.
%%   eflint:all(diploma).
all(FactType) ->
    [Key || {Key, _} <- ets:tab2list(facts),
            is_tuple(Key),
            tuple_size(Key) >= 1,
            element(1, Key) =:= FactType].

%% --- Field access ---

%% Get a named field from a fact tuple.
%%   eflint:get_field(citizen, {application, "Chloe", "solar panels"}).
%%   → "Chloe"
get_field(FieldName, FactTuple) when is_tuple(FactTuple) ->
    FactType = element(1, FactTuple),
    case ets:lookup(schemas, FactType) of
        [{FactType, Fields}] ->
            Idx = index_of(FieldName, Fields),
            element(Idx + 1, FactTuple);
        [] ->
            error({no_schema, FactType})
    end.

%% Rebuild a tagged tuple from a fact type and a key.
%%   eflint:from_key(application, {"Chloe", "solar panels"}).
%%   → {application, "Chloe", "solar panels"}
from_key(FactType, Value) when not is_tuple(Value) ->
    {FactType, Value};
from_key(FactType, Values) when is_tuple(Values) ->
    list_to_tuple([FactType | tuple_to_list(Values)]).

%% Existential search — does any fact of this type match all bindings?
%%   eflint:exists(diploma, [{applicant, "Alice"}, {gpa, 3}]).
%%   eflint:exists(owns_course, [{teacher, "Bob"}, {course, "Math101"}]).
exists(FactType, Bindings) ->
    lists:any(fun(Fact) ->
        lists:all(fun({FieldName, Value}) ->
            get_field(FieldName, Fact) =:= Value
        end, Bindings)
    end, all(FactType)).

%% Count all facts of a given type.
%%   eflint:count(vote).
count(FactType) ->
    length(all(FactType)).

%% Count facts of a given type matching a filter fun.
%%   eflint:count(vote, fun(V) -> eflint:get_field(candidate, V) =:= "Eve" end).
count(FactType, FilterFun) ->
    length([F || F <- all(FactType), FilterFun(F)]).

%% Register a predicate (zero-arity derived boolean).
%%   eflint:register_predicate(vote_concluded, fun() -> ... end).
register_predicate(Name, Fun) when is_atom(Name), is_function(Fun, 0) ->
    ets:insert(derivations, {Name, {predicate, Fun}}),
    ok.

%% Check if a predicate holds.
%%   eflint:holds_predicate(vote_concluded).
holds_predicate(Name) ->
    case ets:lookup(derivations, Name) of
        [{Name, {predicate, Fun}}] -> Fun();
        _ -> false
    end.

%%%======================================================================
%%% 3. Act engine
%%%======================================================================
%%%
%%% Act definition (map):
%%%   #{
%%%       name            => atom(),
%%%       actor           => atom(),                %% fact type of the actor
%%%       recipient       => atom(),                %% optional
%%%       related_to      => atom() | [atom()],     %% optional
%%%       holds_when      => fun(Args) -> boolean(), %% power check, optional
%%%       conditioned_by  => fun(Args) -> boolean(), %% compliance check, optional
%%%       creates         => fun(Args) -> [{Type, Val}],        %% optional
%%%       terminates      => fun(Args) -> [{Type, Val}],        %% optional
%%%       creates_duty    => fun(Args) -> DutyDef :: map(),     %% optional
%%%       terminates_duty => fun(Args) -> DutyKey :: term()     %% optional
%%%   }
%%%
%%% Results:
%%%   disabled       — roles don't exist or holds_when or condition_by failed (no power)
%%%   {enabled, E}   — all checks passsed and effects E were executed

act_loop(ActDef) ->
    Name = maps:get(name, ActDef),
    receive
        {trigger, Args, From} ->
            case run_act(ActDef, Args) of
                {enabled, Effects} ->
                    From ! {act_result, Name, {enabled, Effects}};
                disabled ->
                    From ! {act_result, Name, disabled}
            end,
            act_loop(ActDef);
        {is_enabled, Args, From} ->
            case is_enabled(ActDef, Args) of
                true -> From ! {act_result, Name, enabled};
                false -> From ! {act_result, Name, disabled}
            end,
            act_loop(ActDef);
        stop -> ok
    end.

%% This function returns whether an act is enabled. 
is_enabled(ActDef, Args) ->
  pre_check(ActDef, Args)
  andalso check_holds_when(ActDef, Args)
  andalso check_conditioned_by(ActDef, Args).

run_act(ActDef, Args) ->
    case pre_check(ActDef, Args) of
        false -> disabled;
        true ->
            case check_holds_when(ActDef, Args) of
                false -> disabled;
                true ->
                    case check_conditioned_by(ActDef, Args) of
                        false -> disabled;
                        true ->
                            Effects = execute(ActDef, Args),
                            {enabled, Effects}
                    end
            end
    end.

%% Pre-check: actor, recipient, and all related_to must exist as facts.
pre_check(ActDef, Args) ->
    ActorType     = maps:get(actor, ActDef, none),
    RecipientType = maps:get(recipient, ActDef, none),
    RelatedTo     = normalize_related(maps:get(related_to, ActDef, [])),

    check_role(ActorType, Args)
        andalso check_recipient(RecipientType, Args)
        andalso lists:all(fun(Type) -> check_role(Type, Args) end, RelatedTo).

%% Actor is required.
check_role(none, _Args) ->
    false;
check_role(Type, Args) ->
    case maps:get(Type, Args, undefined) of
        undefined -> false;
        Value     -> holds(Type, Value)
    end.

%% Recipient is optional.
check_recipient(none, _Args) ->
    true;
check_recipient(Type, Args) ->
    check_role(Type, Args).

%% Holds when — power/permission check.
check_holds_when(ActDef, Args) ->
    case maps:get(holds_when, ActDef, none) of
        none -> true;
        Fun  -> Fun(Args)
    end.

%% Conditioned by — compliance check.
check_conditioned_by(ActDef, Args) ->
    case maps:get(conditioned_by, ActDef, none) of
        none -> true;
        Fun  -> Fun(Args)
    end.

%% Execute all effects: terminates first (facts + duties), then creates (facts + duties).
execute(ActDef, Args) ->
    %% --- All terminations ---
    FactTerminated = case maps:get(terminates, ActDef, none) of
        none -> [];
        TFun ->
            lists:map(fun({FT, V}) ->
                terminate(FT, V),
                {terminated, FT, V}
            end, TFun(Args))
    end,
    DutyTerminated = case maps:get(terminates_duty, ActDef, none) of
        none -> [];
        TDFun ->
            DutyKey = TDFun(Args),
            case lookup_duty(DutyKey) of
                {ok, Pid} ->
                    Pid ! terminate,
                    [{terminated, duty, DutyKey}];
                not_found ->
                    []
            end
    end,
    %% --- All creations ---
    FactCreated = case maps:get(creates, ActDef, none) of
        none -> [];
        CFun ->
            lists:map(fun({FT, V}) ->
                add(FT, V),
                {created, FT, V}
            end, CFun(Args))
    end,
    DutyCreated = case maps:get(creates_duty, ActDef, none) of
        none -> [];
        CDFun ->
            DutyResult = CDFun(Args),
            DutyDefs = case is_list(DutyResult) of
                true  -> DutyResult;
                false -> [DutyResult]
            end,
            lists:map(fun(DutyDef) ->
                DKey = duty_key(DutyDef),
                NewPid = spawn(?MODULE, duty_loop, [DutyDef]),
                register_duty(DKey, NewPid),
                {created, duty, DKey}
            end, DutyDefs)
    end,
    FactTerminated ++ DutyTerminated ++ FactCreated ++ DutyCreated.

%% Synchronous trigger.
trigger(ProcName, Args) when is_map(Args) ->
    ProcName ! {trigger, Args, self()},
    receive {act_result, _Name, Result} -> Result end.

act_enabled(ProcName, Args) when is_map(Args) ->
    ProcName ! {is_enabled, Args, self()},
    receive {act_result, _Name, Result} -> Result end.

normalize_related(List) when is_list(List) -> List;
normalize_related(Single) -> [Single].

%%%======================================================================
%%% 4. Duty engine
%%%======================================================================
%%%
%%% Duty definition (map):
%%%   #{
%%%       name          => atom(),
%%%       holder        => {atom(), Value},    %% {role_type, actual_value}
%%%       claimant      => {atom(), Value},    %% {role_type, actual_value}
%%%       related_to    => [{atom(), Value}],  %% optional
%%%       violated_when => fun() -> boolean()  %% zero-arity closure
%%%       subscribes_to => [{atom(), Value}]   %% subscribe to facts
%%%   }
%%%
%%% Duty key is derived from name + holder + claimant + related_to values.

%% Build the duty key from the definition.
duty_key(DutyDef) ->
    Name     = maps:get(name, DutyDef),
    {_, HV}  = maps:get(holder, DutyDef),
    {_, CV}  = maps:get(claimant, DutyDef),
    Related  = maps:get(related_to, DutyDef, []),
    RVals    = [V || {_, V} <- Related],
    list_to_tuple([Name, HV, CV | RVals]).

register_duty(Key, Pid) ->
    ets:insert(duties, {Key, Pid}).

unregister_duty(Key) ->
    ets:delete(duties, Key).

lookup_duty(Key) ->
    case ets:lookup(duties, Key) of
        [{Key, Pid}] -> {ok, Pid};
        []           -> not_found
    end.

duty_loop(DutyDef) ->
    Key = duty_key(DutyDef),
    %% subscribe to fact changes relevant to this duty (could be optimized by tracking which facts are relevant based on the violated_when function, but we'll keep it simple for now)
    FactsSubscriptions = maps:get(subscribes_to, DutyDef, []),
    lists:foreach(fun({FactKey, Value}) ->
        subscribe_fact(FactKey, Value, self())
    end, FactsSubscriptions),
    %% Evaluate violation on entry (a relevant fact may already hold).
    check_and_record_violation(Key, DutyDef),
    duty_loop_inner(Key, DutyDef).

duty_loop_inner(Key, DutyDef) ->
    receive
        {fact_changed, From, Ref} ->
            % io:format("Duty ~p received fact change notification~n", [Key]),
            check_and_record_violation(Key, DutyDef),
            From ! {fact_changed_ack, Ref},
            duty_loop_inner(Key, DutyDef);
        {is_violated, From} ->
            From ! {violated_reply, ets:member(violations, Key)},
            duty_loop_inner(Key, DutyDef);
        terminate ->
            unsubscribe_duty_facts(self()),
            unregister_duty(Key),
            ets:delete(violations, Key),
            ok;
        stop ->
            ets:delete(violations, Key),
            ok
    end.

%% Evaluate violated_when (zero-arity) and write/clear the violations table.
check_and_record_violation(Key, DutyDef) ->
    ViolatedFun = maps:get(violated_when, DutyDef, fun() -> false end),
    case ViolatedFun() of
        true  -> ets:insert(violations, {Key, true});
        false -> ets:delete(violations, Key)
    end.

%% Check if a duty is violated.
%% Reads directly from the violations table — no message-passing needed.
is_violated(Key) ->
    case lookup_duty(Key) of
        not_found -> not_found;
        {ok, _Pid} -> ets:member(violations, Key)
    end.

%%%======================================================================
%%% 5. Debug helpers
%%%======================================================================

dump(Table) ->
    % io:format("--- facts ---~n"),
    ets:foldl(fun(Entry, _) ->
        io:format("  ~p~n", [Entry]),
        ok
    end, ok, Table),
    io:format("---~n"),
    ok.

%%%======================================================================
%%% Internal helpers
%%%======================================================================

index_of(Item, List) ->
    index_of(Item, List, 1).
index_of(_, [], _) ->
    error(field_not_found);
index_of(Item, [Item | _], N) ->
    N;
index_of(Item, [_ | Rest], N) ->
    index_of(Item, Rest, N + 1).
