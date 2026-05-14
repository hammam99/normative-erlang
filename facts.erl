%%% facts.erl
%%% Reusable facts module for eFLINT → Erlang translations.
%%%
%%% Responsibilities:
%%%   - Schema registration (field names per fact type)
%%%   - Canonical type resolution (placeholder → base type)
%%%   - Adding / terminating facts in ETS
%%%   - holds/2,3 queries
%%%   - Subscriber notifications (for duties)
%%%   - Duty registration
%%%
%%% ETS layout:
%%%   facts       (set)  — key = whole tuple, value = true
%%%                         e.g. {{natural_parent, "alice", "bob"}, true}
%%%   schemas     (set)  — key = fact type atom, value = list of field names
%%%                         e.g. {natural_parent, [parent, child]}
%%%   types       (set)  — key = placeholder atom, value = canonical type atom
%%%                         e.g. {parent, person}
%%%   derivations (set)  — key = fact type atom, value = fun(Value) -> bool
%%%   subscribers (bag)  — key = fact type atom, value = pid
%%%   duties      (set)  — key = {DutyName, Args}, value = pid

-module(facts).

-export([
    init/0,

    %% Schema & type registration
    register_schema/2,
    register_type/2,
    register_derivation/2,
    canonical_type/1,

    %% Fact operations
    add/2, add/3,
    terminate/2, terminate/3,
    holds/2, holds/3,

    %% Field access
    get_field/2,
    query_by_field/3,

    %% Subscriber / duty support
    subscribe/2,
    unsubscribe_all/1,
    register_duty/3,
    unregister_duty/2,
    lookup_duty/2,

    %% Debug
    dump/0, dump/1
]).

%%%======================================================================
%%% Init
%%%======================================================================

init() ->
    ets:new(facts,       [set, public, named_table]),
    ets:new(schemas,     [set, public, named_table]),
    ets:new(types,       [set, public, named_table]),
    ets:new(derivations, [set, public, named_table]),
    ets:new(subscribers, [bag, public, named_table]),
    ets:new(duties,      [set, public, named_table]),
    ok.

%%%======================================================================
%%% Schema & type registration
%%%======================================================================

%% Register field names for a fact type.
%%   facts:register_schema(natural_parent, [parent, child]).
register_schema(FactType, Fields) when is_atom(FactType), is_list(Fields) ->
    ets:insert(schemas, {FactType, Fields}),
    ok.

%% Register a placeholder → canonical type mapping.
%%   facts:register_type(parent, person).
register_type(Placeholder, CanonicalType) ->
    ets:insert(types, {Placeholder, CanonicalType}),
    ok.

%% Resolve a placeholder to its canonical (base) type.
%% Follows the chain:  parent → person → person (stops when self-mapped or unmapped).
canonical_type(Name) ->
    case ets:lookup(types, Name) of
        [{Name, Name}]   -> Name;          %% self-mapped, stop
        [{Name, Deeper}] -> canonical_type(Deeper);
        []               -> Name           %% no mapping, it IS the base type
    end.

%% Register a derived fact.
%% The fun receives the Value (single value or tuple) and returns true | false.
%%   facts:register_derivation(legal_parent, fun({Parent, Child}) ->
%%       facts:holds(natural_parent, {Parent, Child})
%%           orelse facts:holds(adoptive_parent, {Parent, Child})
%%   end).
register_derivation(FactType, Fun) when is_atom(FactType), is_function(Fun, 1) ->
    ets:insert(derivations, {FactType, Fun}),
    ok.

%%%======================================================================
%%% Fact operations
%%%======================================================================

%% Add a fact with a single value (e.g. person "Alice").
%%   facts:add(person, "Alice").
add(FactType, Value) when not is_tuple(Value) ->
    Key = {FactType, Value},
    case ets:insert_new(facts, {Key, true}) of
        true  -> notify(FactType, Key, created);
        false -> ok
    end,
    ok;

%% Add a fact with a tuple of values (e.g. natural_parent {"Alice","Bob"}).
%% Expands the tuple into individual elements:
%%   facts:add(natural_parent, {"alice","bob"}).
%%   → key = {natural_parent, "alice", "bob"}
add(FactType, Values) when is_tuple(Values) ->
    Key = list_to_tuple([FactType | tuple_to_list(Values)]),
    case ets:insert_new(facts, {Key, true}) of
        true  -> notify(FactType, Key, created);
        false -> ok
    end,
    ok.

%% Add with explicit field values (uses schema for validation later if needed).
%%   facts:add(natural_parent, parent, "alice").  — not typical, but available.
add(FactType, _FieldName, Value) ->
    add(FactType, Value).

%% Terminate a fact.
terminate(FactType, Value) when not is_tuple(Value) ->
    Key = {FactType, Value},
    do_terminate(FactType, Key);
terminate(FactType, Values) when is_tuple(Values) ->
    Key = list_to_tuple([FactType | tuple_to_list(Values)]),
    do_terminate(FactType, Key).

terminate(FactType, _FieldName, Value) ->
    terminate(FactType, Value).

do_terminate(FactType, Key) ->
    case ets:lookup(facts, Key) of
        []  -> ok;
        [_] ->
            ets:delete(facts, Key),
            notify(FactType, Key, terminated)
    end,
    ok.

%% Check if a fact holds.
%%   facts:holds(person, "Alice").                  → true | false  (postulated)
%%   facts:holds(natural_parent, {"alice","bob"}).   → true | false  (postulated)
%%   facts:holds(legal_parent, {"alice","bob"}).     → true | false  (derived)
%%
%% Checks derivations first, then resolves placeholders and checks ETS.
holds(FactType, Value) ->
    Resolved = canonical_type(FactType),
    case ets:lookup(derivations, FactType) of
        [{FactType, Fun}] ->
            Fun(Value);
        [] ->
            Key = case is_tuple(Value) of
                true  -> list_to_tuple([Resolved | tuple_to_list(Value)]);
                false -> {Resolved, Value}
            end,
            ets:member(facts, Key)
    end.

%% Three-arg holds for when you want to specify the field explicitly
%% (just forwards to holds/2).
holds(FactType, _FieldName, Value) ->
    holds(FactType, Value).

%%%======================================================================
%%% Field access (by name)
%%%======================================================================

%% Get a named field from a fact tuple.
%%   facts:get_field(parent, {natural_parent, "alice", "bob"}).  → "alice"
%%   facts:get_field(child,  {natural_parent, "alice", "bob"}).  → "bob"
get_field(FieldName, FactTuple) when is_tuple(FactTuple) ->
    FactType = element(1, FactTuple),
    case ets:lookup(schemas, FactType) of
        [{FactType, Fields}] ->
            Idx = index_of(FieldName, Fields),
            element(Idx + 1, FactTuple);   %% +1 for the type tag
        [] ->
            error({no_schema, FactType})
    end.

%% Query all facts of a type where a specific field matches a value.
%%   facts:query_by_field(natural_parent, child, "bob").
%%   → [{natural_parent, "alice", "bob"}]
query_by_field(FactType, FieldName, Value) ->
    case ets:lookup(schemas, FactType) of
        [{FactType, Fields}] ->
            Idx = index_of(FieldName, Fields) + 1,  %% +1 for type tag
            Arity = length(Fields) + 1,
            Pattern = erlang:make_tuple(Arity, '_', [{1, FactType}]),
            AllKeys = [K || {K, _} <- ets:match_object(facts, {Pattern, '_'})],
            [K || K <- AllKeys, element(Idx, K) =:= Value];
        [] ->
            error({no_schema, FactType})
    end.

%%%======================================================================
%%% Subscribers (push notifications for duties)
%%%======================================================================

%% Subscribe a process to changes on a fact type.
%%   facts:subscribe(homework_due, self()).
subscribe(FactType, Pid) ->
    ets:insert(subscribers, {FactType, Pid}),
    ok.

unsubscribe_all(Pid) ->
    ets:match_delete(subscribers, {'_', Pid}),
    ok.

%% Internal: notify all subscribers of a fact type.
notify(FactType, FactKey, Change) ->
    Pids = [P || {_, P} <- ets:lookup(subscribers, FactType)],
    [Pid ! {fact_changed, FactKey, Change} || Pid <- Pids],
    ok.

%%%======================================================================
%%% Duty registry
%%%======================================================================

register_duty(Name, Args, Pid) ->
    ets:insert(duties, {{Name, Args}, Pid}).

unregister_duty(Name, Args) ->
    ets:delete(duties, {Name, Args}).

lookup_duty(Name, Args) ->
    case ets:lookup(duties, {Name, Args}) of
        [{_, Pid}] -> {ok, Pid};
        []         -> not_found
    end.

%%%======================================================================
%%% Debug helpers
%%%======================================================================

dump() ->
    dump(facts).

dump(Tab) ->
    io:format("--- ~p ---~n", [Tab]),
    ets:foldl(fun(Entry, _) ->
        io:format("  ~p~n", [Entry]),
        ok
    end, ok, Tab),
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
