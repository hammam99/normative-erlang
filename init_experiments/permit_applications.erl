%%% permit_applications.erl
%%%
%%% Erlang runtime for the eFLINT permit_applications spec.
%%% Same architecture as help_with_homework.erl: shared ETS for facts,
%%% one long-lived process per Act type, no duty processes (this spec
%%% doesn't declare any Duties).
%%%
%%% Compile & run:
%%%   erlc permit_applications.erl
%%%   erl -noshell -s permit_applications run -s init stop

-module(permit_applications).

-export([run/0]).
-export([apply_loop/0, deny_loop/0, approve_loop/0]).


factsbank_init() ->
    ets:new(facts,       [set, public, named_table]),
    ets:new(subscribers, [bag, public, named_table]).

holds(Fact) -> ets:member(facts, Fact).

add_fact(Fact) ->
    case ets:insert_new(facts, {Fact}) of
        true  -> notify(Fact, created);
        false -> ok
    end,
    ok.

terminate_fact(Fact) ->
    case ets:lookup(facts, Fact) of
        []  -> ok;
        [_] ->
            ets:delete(facts, Fact),
            notify(Fact, terminated)
    end,
    ok.

notify(Fact, Change) ->
    Pids = [P || {_, P} <- ets:lookup(subscribers, Fact)],
    [Pid ! {fact_changed, Fact, Change} || Pid <- Pids],
    ok.

%%%======================================================================
%%% Act: apply
%%%   Actor     citizen
%%%   Recipient minister
%%%   Related to permit-type
%%%   Creates   application(citizen, permit-type)
%%%
%%% No precondition in the eFLINT spec — any citizen can apply.
%%% Args convention: {Citizen, Minister, PermitType}
%%%======================================================================

apply_loop() ->
    receive
        {trigger, {Citizen, _Minister, PermitType}, From} ->
            add_fact({application, Citizen, PermitType}),
            From ! {apply_result, {enabled, {application_created,
                                             Citizen, PermitType}}},
            apply_loop();
        stop -> ok
    end.

%%%======================================================================
%%% Act: deny
%%%   Actor     minister
%%%   Recipient citizen
%%%   Related to application
%%%   Conditioned by application  &&
%%%                 application.citizen == citizen &&
%%%                 application.permit_type == "new construction"
%%%   Terminates application
%%%
%%% Args convention: {Minister, Citizen, Application}
%%%   where Application = {application, C, PT}
%%%======================================================================

deny_loop() ->
    receive
        {trigger, {_Minister, Citizen, {application, C, PT} = App}, From} ->
            %% Precondition: the application fact must hold, its citizen
            %% field must match the recipient, and it must be for
            %% "new construction".
            Enabled =
                holds(App)
                andalso C =:= Citizen
                andalso PT =:= "new construction",
            case Enabled of
                false ->
                    From ! {deny_result, {disabled, App}},
                    deny_loop();
                true ->
                    terminate_fact(App),
                    From ! {deny_result, {enabled, {application_terminated,
                                                   App}}},
                    deny_loop()
            end;
        stop -> ok
    end.

%%%======================================================================
%%% Act: approve
%%%   Actor     minister
%%%   Recipient citizen
%%%   Related to application
%%%   Conditioned by application &&
%%%                 application.citizen == citizen &&
%%%                 application.permit_type == "solar panels"
%%%   Terminates application
%%%   Creates    permit(citizen)
%%%
%%% Args convention: {Minister, Citizen, Application}
%%%======================================================================

approve_loop() ->
    receive
        {trigger, {_Minister, Citizen, {application, C, PT} = App}, From} ->
            Enabled =
                holds(App)
                andalso C =:= Citizen
                andalso PT =:= "solar panels",
            case Enabled of
                false ->
                    From ! {approve_result, {disabled, App}},
                    approve_loop();
                true ->
                    terminate_fact(App),
                    add_fact({permit, Citizen}),
                    From ! {approve_result, {enabled,
                                             {application_terminated, App},
                                             {permit_created, Citizen}}},
                    approve_loop()
            end;
        stop -> ok
    end.

%%%======================================================================
%%% Synchronous wrappers
%%%======================================================================

trigger_apply(Args) ->
    apply_proc ! {trigger, Args, self()},
    receive {apply_result, R} -> R end.

trigger_deny(Args) ->
    deny_proc ! {trigger, Args, self()},
    receive {deny_result, R} -> R end.

trigger_approve(Args) ->
    approve_proc ! {trigger, Args, self()},
    receive {approve_result, R} -> R end.

%%%======================================================================
%%% Scenario
%%%
%%% apply(Chloe, minister, "solar panels").
%%% approve(minister, Chloe, application(Chloe, "solar panels")).
%%% apply(Bob, minister, "new construction").
%%% deny(minister, Bob, application(Bob, "new construction")).
%%% apply(Alice, minister, "solar panels").
%%% deny(minister, Alice, application(Alice, "solar panels")).  // non-compliant
%%%======================================================================

run() ->
    factsbank_init(),
    %% Register the act actors under non-reserved names. `apply` is a BIF
    %% so we use `apply_proc`; the others follow the same convention.
    register(apply_proc,   spawn(?MODULE, apply_loop, [])),
    register(deny_proc,    spawn(?MODULE, deny_loop, [])),
    register(approve_proc, spawn(?MODULE, approve_loop, [])),

    Minister = "Minister van Volkshuisvesting",

    io:format("~n--- apply(Chloe, minister, solar panels) ---~n"),
    io:format("~p~n", [trigger_apply({"Chloe", Minister, "solar panels"})]),

    io:format("~n--- approve(minister, Chloe, application(Chloe, solar panels)) ---~n"),
    io:format("~p~n", [trigger_approve({Minister, "Chloe",
                                        {application, "Chloe", "solar panels"}})]),
    io:format("permit held? ~p~n", [holds({permit, "Chloe"})]),

    io:format("~n--- apply(Bob, minister, new construction) ---~n"),
    io:format("~p~n", [trigger_apply({"Bob", Minister, "new construction"})]),

    io:format("~n--- deny(minister, Bob, application(Bob, new construction)) ---~n"),
    io:format("~p~n", [trigger_deny({Minister, "Bob",
                                     {application, "Bob", "new construction"}})]),

    io:format("~n--- apply(Alice, minister, solar panels) ---~n"),
    io:format("~p~n", [trigger_apply({"Alice", Minister, "solar panels"})]),

    io:format("~n--- deny(minister, Alice, solar panels)  NON-COMPLIANT ---~n"),
    io:format("~p~n", [trigger_deny({Minister, "Alice",
                                     {application, "Alice", "solar panels"}})]),

    io:format("~n--- Final facts ---~n"),
    io:format("~p~n", [[F || {F} <- ets:tab2list(facts)]]),

    ok.
