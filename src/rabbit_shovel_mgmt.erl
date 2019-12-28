%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at https://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2020 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_shovel_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0]).
-export([init/2, to_json/2, resource_exists/2, content_types_provided/2,
         is_authorized/2, allowed_methods/2, delete_resource/2]).

-import(rabbit_misc, [pget/2]).

-include_lib("rabbitmq_management_agent/include/rabbit_mgmt_records.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

dispatcher() -> [{"/shovels",        ?MODULE, []},
                 {"/shovels/:vhost", ?MODULE, []},
                 {"/shovels/vhost/:vhost/:name/restart", ?MODULE, []}].

web_ui()     -> [{javascript, <<"shovel.js">>}].

%%--------------------------------------------------------------------

init(Req, _Opts) ->
    {cowboy_rest, rabbit_mgmt_cors:set_headers(Req, ?MODULE), #context{}}.

content_types_provided(ReqData, Context) ->
   {[{<<"application/json">>, to_json}], ReqData, Context}.

allowed_methods(ReqData, Context) ->
    {[<<"HEAD">>, <<"GET">>, <<"DELETE">>, <<"OPTIONS">>], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {case rabbit_mgmt_util:vhost(ReqData) of
         not_found -> false;
         VHost     -> case rabbit_mgmt_util:id(name, ReqData) of
                          none -> true;
                          %% Restarting a shovel
                          Name -> case rabbit_shovel_status:lookup({VHost, Name}) of
                                      not_found -> false;
                                      _ -> true
                                  end
                      end
     end, ReqData, Context}.

to_json(ReqData, Context) ->
    rabbit_mgmt_util:reply_list(
      filter_vhost_req(status(ReqData, Context), ReqData), ReqData, Context).

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_monitor(ReqData, Context).

delete_resource(ReqData, Context) ->
    VHost = rabbit_mgmt_util:id(vhost, ReqData),
    Reply =
        case rabbit_mgmt_util:id(name, ReqData) of
            none ->
                false;
            Name ->
                ok = rabbit_shovel_dyn_worker_sup_sup:stop_child({VHost, Name}),
                {ok, _} = rabbit_shovel_dyn_worker_sup_sup:start_link(),
                true
        end,
    {Reply, ReqData, Context}.

%%--------------------------------------------------------------------

filter_vhost_req(List, ReqData) ->
    case rabbit_mgmt_util:vhost(ReqData) of
        none      -> List;
        VHost     -> [I || I <- List,
                           pget(vhost, I) =:= VHost]
    end.

%% Allow users to see things in the vhosts they are authorised. But
%% static shovels do not have a vhost, so only allow admins (not
%% monitors) to see them.
filter_vhost_user(List, _ReqData, #context{user = User = #user{tags = Tags}}) ->
    VHosts = rabbit_mgmt_util:list_login_vhosts_names(User, undefined),
    [I || I <- List, case pget(vhost, I) of
                         undefined -> lists:member(administrator, Tags);
                         VHost     -> lists:member(VHost, VHosts)
                     end].

status(ReqData, Context) ->
    filter_vhost_user(
      lists:append([status(Node) || Node <- [node() | nodes()]]),
      ReqData, Context).

status(Node) ->
    case rpc:call(Node, rabbit_shovel_status, status, [], infinity) of
        {badrpc, {'EXIT', _}} ->
            [];
        Status ->
            [format(Node, I) || I <- Status]
    end.

format(Node, {Name, Type, Info, TS}) ->
    [{node, Node}, {timestamp, format_ts(TS)}] ++
        format_name(Type, Name) ++
        format_info(Info).

format_name(static,  Name)          -> [{name,  Name},
                                        {type,  static}];
format_name(dynamic, {VHost, Name}) -> [{name,  Name},
                                        {vhost, VHost},
                                        {type,  dynamic}].

format_info(starting) ->
    [{state, starting}];

format_info({running, Props}) ->
    [{state, running}] ++ Props;

format_info({terminated, Reason}) ->
    [{state,  terminated},
     {reason, print("~p", [Reason])}].

format_ts({{Y, M, D}, {H, Min, S}}) ->
    print("~w-~2.2.0w-~2.2.0w ~w:~2.2.0w:~2.2.0w", [Y, M, D, H, Min, S]).

print(Fmt, Val) ->
    list_to_binary(io_lib:format(Fmt, Val)).
