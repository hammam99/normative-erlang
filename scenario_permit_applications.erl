%%% scenario_permit_applications.erl
%%%
%%% eFLINT permit_applications translated to Erlang.
%%%
%%% Compile & run:
%%%   erlc eflint.erl scenario_permit_applications.erl
%%%   erl -noshell -s scenario_permit_applications run -s init stop

-module(scenario_permit_applications).

-export([run/0]).

%%%======================================================================
%%% Fact declarations
%%%======================================================================

setup_facts() ->
    %% Fact application Identified by citizen * permit-type
    eflint:register_schema(application, [citizen, permit_type]),

    %% Initial facts
    eflint:add(citizen, "Alice"),
    eflint:add(citizen, "Bob"),
    eflint:add(citizen, "Chloe"),
    eflint:add(minister, "Minister van Volkshuisvesting"),
    eflint:add(permit_type, "solar panels"),
    eflint:add(permit_type, "new construction"),
    ok.

%%%======================================================================
%%% Act declarations
%%%======================================================================

%% Act apply
%%   Actor citizen
%%   Recipient minister
%%   Related to permit-type
%%   Creates application(citizen, permit-type)
apply_act() -> #{
    name => apply_act,
    actor => citizen,
    recipient => minister,
    related_to => permit_type,
    creates => fun(#{citizen := Citizen, permit_type := PermitType}) ->
        [{application, {Citizen, PermitType}}]
    end
}.

%% Act deny
%%   Actor minister
%%   Recipient citizen
%%   Related to application
%%   Conditioned by
%%     application &&
%%     application.citizen == citizen &&
%%     application.permit-type == "new construction"
%%   Terminates application
deny_act() -> #{
    name => deny,
    actor => minister,
    recipient => citizen,
    related_to => application,
    conditioned_by => fun(#{application := AppKey, citizen := Citizen}) ->
        App = eflint:from_key(application, AppKey),
        eflint:get_field(citizen, App) =:= Citizen
            andalso eflint:get_field(permit_type, App) =:= "new construction"
    end,
    terminates => fun(#{application := AppKey}) ->
        [{application, AppKey}]
    end
}.

%% Act approve
%%   Actor minister
%%   Recipient citizen
%%   Related to application
%%   Conditioned by
%%     application &&
%%     application.citizen == citizen &&
%%     application.permit-type == "solar panels"
%%   Terminates application
%%   Creates permit(citizen)
approve_act() -> #{
    name => approve,
    actor => minister,
    recipient => citizen,
    related_to => application,
    conditioned_by => fun(#{application := AppKey, citizen := Citizen}) ->
        App = eflint:from_key(application, AppKey),
        eflint:get_field(citizen, App) =:= Citizen
            andalso eflint:get_field(permit_type, App) =:= "solar panels"
    end,
    creates => fun(#{citizen := Citizen}) ->
        [{permit, Citizen}]
    end,
    terminates => fun(#{application := AppKey}) ->
        [{application, AppKey}]
    end
}.

%%%======================================================================
%%% Scenario
%%%======================================================================

run() ->
    eflint:init(),
    setup_facts(),

    %% Spawn act processes
    register(apply_proc,   spawn(eflint, act_loop, [apply_act()])),
    register(deny_proc,    spawn(eflint, act_loop, [deny_act()])),
    register(approve_proc, spawn(eflint, act_loop, [approve_act()])),

    io:format("~n--- Initial facts ---~n"),
    eflint:dump(),

    %% apply(Chloe, minister, "solar panels")
    io:format("~n--- apply(Chloe, minister, solar panels) ---~n"),
    io:format("~p~n", [eflint:trigger(apply_proc, #{
        citizen => "Chloe",
        minister => "Minister van Volkshuisvesting",
        permit_type => "solar panels"
    })]),

    %% approve(minister, Chloe, application(Chloe, "solar panels"))
    io:format("~n--- approve(minister, Chloe, application(Chloe, solar panels)) ---~n"),
    io:format("~p~n", [eflint:trigger(approve_proc, #{
        minister => "Minister van Volkshuisvesting",
        citizen => "Chloe",
        application => {"Chloe", "solar panels"}
    })]),
    io:format("permit(Chloe)? ~p~n", [eflint:holds(permit, "Chloe")]),

    %% apply(Bob, minister, "new construction")
    io:format("~n--- apply(Bob, minister, new construction) ---~n"),
    io:format("~p~n", [eflint:trigger(apply_proc, #{
        citizen => "Bob",
        minister => "Minister van Volkshuisvesting",
        permit_type => "new construction"
    })]),

    %% deny(minister, Bob, application(Bob, "new construction"))
    io:format("~n--- deny(minister, Bob, application(Bob, new construction)) ---~n"),
    io:format("~p~n", [eflint:trigger(deny_proc, #{
        minister => "Minister van Volkshuisvesting",
        citizen => "Bob",
        application => {"Bob", "new construction"}
    })]),

    %% apply(Alice, minister, "solar panels")
    io:format("~n--- apply(Alice, minister, solar panels) ---~n"),
    io:format("~p~n", [eflint:trigger(apply_proc, #{
        citizen => "Alice",
        minister => "Minister van Volkshuisvesting",
        permit_type => "solar panels"
    })]),

    %% deny(minister, Alice, application(Alice, "solar panels")) — NON-COMPLIANT
    io:format("~n--- deny(minister, Alice, solar panels) — NON-COMPLIANT ---~n"),
    io:format("~p~n", [eflint:trigger(deny_proc, #{
        minister => "Minister van Volkshuisvesting",
        citizen => "Alice",
        application => {"Alice", "solar panels"}
    })]),

    io:format("~n--- Final facts ---~n"),
    eflint:dump(),

    ok.
