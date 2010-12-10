%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
%%

-module(rabbit_mirror_queue_master).

-export([init/2, terminate/1, delete_and_terminate/1,
         purge/1, publish/4, publish_delivered/5, fetch/2, ack/2,
         tx_publish/5, tx_ack/3, tx_rollback/2, tx_commit/4,
         requeue/3, len/1, is_empty/1, dropwhile/2,
         set_ram_duration_target/2, ram_duration/1,
         needs_idle_timeout/1, idle_timeout/1, handle_pre_hibernate/1,
         status/1]).

-export([start/1, stop/0]).

-export([promote_backing_queue_state/3]).

-behaviour(rabbit_backing_queue).

-include_lib("rabbit_common/include/rabbit.hrl").

-record(state, { coordinator,
                 backing_queue,
                 backing_queue_state,

                 guid_ack %% :: Guid -> AckTag
               }).

%% ---------------------------------------------------------------------------
%% Backing queue
%% ---------------------------------------------------------------------------

start(_DurableQueues) ->
    %% This will never get called as this module will never be
    %% installed as the default BQ implementation.
    exit({not_valid_for_generic_backing_queue, ?MODULE}).

stop() ->
    %% Same as start/1.
    exit({not_valid_for_generic_backing_queue, ?MODULE}).

init(#amqqueue { arguments = Args, durable = false } = Q, Recover) ->
    {ok, CPid} =
        rabbit_mirror_queue_coordinator:start_link(Q, undefined),
    {_Type, Nodes} = rabbit_misc:table_lookup(Args, <<"x-mirror">>),
    [rabbit_mirror_queue_coordinator:add_slave(CPid, binary_to_atom(Node, utf8))
     || {longstr, Node} <- Nodes],
    {ok, BQ} = application:get_env(backing_queue_module),
    BQS = BQ:init(Q, Recover),
    #state { coordinator         = CPid,
             backing_queue       = BQ,
             backing_queue_state = BQS,
             guid_ack            = dict:new() }.

promote_backing_queue_state(CPid, BQ, BQS) ->
    #state { coordinator         = CPid,
             backing_queue       = BQ,
             backing_queue_state = BQS,
             guid_ack            = dict:new() }.

terminate(State = #state { backing_queue = BQ, backing_queue_state = BQS }) ->
    %% Backing queue termination. The queue is going down but
    %% shouldn't be deleted. It thinks it's durable most likely. Not
    %% sure yet what to tell the slaves.
    State #state { backing_queue_state = BQ:terminate(BQS) }.

delete_and_terminate(State = #state { backing_queue       = BQ,
                                      backing_queue_state = BQS }) ->
    %% TODO: should confirmed_broadcast to make sure our slaves don't
    %% try and promote themselves.
    State #state { backing_queue_state = BQ:delete_and_terminate(BQS) }.

purge(#state {} = State) ->
    %% gm:broadcast(GM, {set_length, 0})
    {0, State}.

publish(Msg, MsgProps, ChPid, #state {} = State) ->
    %% gm:broadcast(GM, {publish, false, Guid, MsgProps, ChPid})
    State.

publish_delivered(AckRequired, Msg, MsgProps, ChPid, #state {} = State) ->
    %% gm:broadcast(GM, {publish, {true, AckRequired}, Guid, MsgProps, ChPid})
    {blank_ack, State}.

dropwhile(Fun, #state {} = State) ->
    %% gm:broadcast(GM, {set_length, len(State1)})
    State.

fetch(AckRequired, #state {} = State) ->
    %% case fetch of
    %%   empty -> do nothing;
    %%   {Msg, Remaining} -> gm:broadcast(GM, {fetch, AckRequired, Guid, Remaining})
    %% end
    {empty, State}.

ack(AckTags, #state {} = State) ->
    %% gm:broadcast(GM, {ack, Guids})
    State.

tx_publish(Txn, Msg, MsgProps, ChPid, #state {} = State) ->
    %% gm:broadcast(GM, {tx_publish, Txn, Guid, MsgProps, ChPid})
    State.

tx_ack(Txn, AckTags, #state {} = State) ->
    %% gm:broadcast(GM, {tx_ack, Txn, Guids})
    State.

tx_rollback(Txn, #state {} = State) ->
    %% gm:broadcast(GM, {tx_rollback, Txn})
    State.

tx_commit(Txn, PostCommitFun, MsgPropsFun, #state {} = State) ->
    %% Maybe don't want to transmit the MsgPropsFun but what choice do
    %% we have? OTOH, on the slaves, things won't be expiring on their
    %% own (props are interpreted by amqqueue, not vq), so if the msg
    %% props aren't quite the same, that doesn't matter.
    %%
    %% The PostCommitFun is actually worse - we need to prevent that
    %% from being invoked until we have confirmation from all the
    %% slaves that they've done everything up to there.
    %%
    %% In fact, transactions are going to need work seeing as it's at
    %% this point that VQ mentions amqqueue, which will thus not work
    %% on the slaves - we need to make sure that all the slaves do the
    %% tx_commit_post_msg_store at the same point, and then when they
    %% all confirm that (scatter/gather), we can finally invoke the
    %% PostCommitFun.
    %%
    %% Another idea is that the slaves are actually driven with
    %% pubacks and thus only the master needs to support txns
    %% directly.
    {[], State}.

requeue(AckTags, MsgPropsFun, #state {} = State) ->
    %% gm:broadcast(GM, {requeue, Guids}),
    State.

len(#state { backing_queue = BQ, backing_queue_state = BQS}) ->
    BQ:len(BQS).

is_empty(#state { backing_queue = BQ, backing_queue_state = BQS}) ->
    BQ:is_empty(BQS).

set_ram_duration_target(Target, State = #state { backing_queue       = BQ,
                                                 backing_queue_state = BQS}) ->
    State #state { backing_queue_state =
                       BQ:set_ram_duration_target(Target, BQS) }.

ram_duration(State = #state { backing_queue = BQ, backing_queue_state = BQS}) ->
    {Result, BQS1} = BQ:ram_duration(BQS),
    {Result, State #state { backing_queue_state = BQS1 }}.

needs_idle_timeout(#state { backing_queue = BQ, backing_queue_state = BQS}) ->
    BQ:needs_idle_timeout(BQS).

idle_timeout(#state { backing_queue = BQ, backing_queue_state = BQS}) ->
    BQ:idle_timeout(BQS).

handle_pre_hibernate(State = #state { backing_queue       = BQ,
                                      backing_queue_state = BQS}) ->
    State #state { backing_queue_state = BQ:handle_pre_hibernate(BQS) }.

status(#state { backing_queue = BQ, backing_queue_state = BQS}) ->
    BQ:status(BQS).
