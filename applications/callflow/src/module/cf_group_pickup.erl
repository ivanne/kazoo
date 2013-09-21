%%%-------------------------------------------------------------------
%%% @copyright (C) 2013, 2600Hz INC
%%% @doc
%%% Pickup a call in the specified group
%%%
%%% data: {
%%%   "group_id":"_id_"
%%% }
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cf_group_pickup).

-include("../callflow.hrl").

-export([handle/2]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module sends an arbitrary response back to the
%% call originator.
%% @end
%%--------------------------------------------------------------------
-spec handle(wh_json:object(), whapps_call:call()) -> any().
handle(Data, Call) ->
    GroupId = wh_json:get_ne_value(<<"group_id">>, Data),

    case find_sip_users(GroupId, Call) of
        [] -> no_users_in_group(Call);
        Usernames -> connect_to_ringing_channel(Usernames, Call)
    end,
    cf_exe:stop(Call).

-spec connect_to_ringing_channel(ne_binaries(), whapps_call:call()) -> 'ok'.
connect_to_ringing_channel(Usernames, Call) ->
    case find_channels(Usernames, Call) of
        [] -> no_channels_ringing(Call);
        Channels -> connect_to_a_channel(Channels, Call)
    end,
    'ok'.

-spec connect_to_a_channel(wh_json:objects(), whapps_call:call()) -> 'ok'.
connect_to_a_channel(Channels, Call) ->
    MyUUID = whapps_call:call_id(Call),
    MyMediaServer = whapps_call:switch_nodename(Call),

    lager:debug("looking for channels on my node ~s that aren't me", [MyMediaServer]),

    case sort_channels(Channels, MyUUID, MyMediaServer) of
        {[], []} ->
            lager:debug("no channels available to pickup"),
            no_channels_ringing(Call);
        {[], [RemoteUUID|_Remote]} ->
            lager:debug("no unanswered calls on my media server, trying ~s", [RemoteUUID]),
            intercept_call(RemoteUUID, Call);
        {[LocalUUID|_Cs], _} ->
            lager:debug("found a call (~s) on my media server", [LocalUUID]),
            intercept_call(LocalUUID, Call)
    end.

-spec sort_channels(wh_json:objects(), ne_binary(), ne_binary()) ->
                           {ne_binaries(), ne_binaries()}.
-spec sort_channels(wh_json:objects(), ne_binary(), ne_binary(), {ne_binaries(), ne_binaries()}) ->
                           {ne_binaries(), ne_binaries()}.
sort_channels(Channels, MyUUID, MyMediaServer) ->
    sort_channels(Channels, MyUUID, MyMediaServer, {[], []}).
sort_channels([Channel|Channels], MyUUID, MyMediaServer, {Local, Remote}=Acc) ->
    case wh_json:is_false(<<"answered">>, Channel) of
        'true' ->
            sort_channels(Channels, MyUUID, MyMediaServer, Acc);
        'false' ->
            UUID = wh_json:get_value(<<"uuid">>, Channel),

            case wh_json:get_value(<<"node">>, Channel) of
                MyMediaServer ->
                    case UUID of
                        MyUUID ->
                            sort_channels(Channels, MyUUID, MyMediaServer, Acc);
                        UUID ->
                            sort_channels(Channels, MyUUID, MyMediaServer, {[UUID | Local], Remote})
                    end;
                _OtherMediaServer ->
                    sort_channels(Channels, MyUUID, MyMediaServer, {Local, [UUID | Remote]})
            end
    end.

-spec intercept_call(ne_binary(), whapps_call:call()) -> 'ok'.
intercept_call(UUID, Call) ->
    _ = whapps_call_command:pickup(UUID, Call),
    case wait_for_pickup(Call) of
        {'error', _E} ->
            lager:debug("failed to pickup ~s: ~p", [UUID, _E]);
        'ok' ->
            lager:debug("call picked up"),
            whapps_call_command:wait_for_hangup(),
            lager:debug("hangup recv")
    end.

-spec wait_for_pickup(whapps_call:call()) ->
                             'ok' |
                             {'error', 'failed'} |
                             {'error', 'timeout'}.
wait_for_pickup(Call) ->
    case whapps_call_command:receive_event(10000) of
        {'ok', Evt} ->
            pickup_event(Call, wh_util:get_event_type(Evt), Evt);
        {'error', 'timeout'}=E ->
            lager:debug("timed out"),
            E
    end.

pickup_event(_Call, {<<"error">>, <<"dialplan">>}, Evt) ->
    lager:debug("error in dialplan: ~s", [wh_json:get_value(<<"Error-Message">>, Evt)]),
    {'error', 'failed'};
pickup_event(_Call, {<<"call_event">>,<<"CHANNEL_BRIDGE">>}, _Evt) ->
    lager:debug("channel bridged to ~s", [wh_json:get_value(<<"Other-Leg-Unique-ID">>, _Evt)]);
pickup_event(Call, _Type, _Evt) ->
    lager:debug("unhandled evt ~p", [_Type]),
    wait_for_pickup(Call).

-spec find_channels(ne_binaries(), whapps_call:call()) -> wh_json:objects().
find_channels(Usernames, Call) ->
    Realm = wh_util:get_account_realm(whapps_call:account_id(Call)),
    lager:debug("finding channels for realm ~s, usernames ~p", [Realm, Usernames]),
    Req = [{<<"Realm">>, Realm}
           ,{<<"Usernames">>, Usernames}
           | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    case whapps_util:amqp_pool_request(Req
                                       ,fun wapi_call:publish_query_user_channels_req/1
                                       ,fun wapi_call:query_user_channels_resp_v/1
                                      )
    of
        {'ok', Resp} -> wh_json:get_value(<<"Channels">>, Resp, []);
        {'error', _E} ->
            lager:debug("failed to get channels: ~p", [_E]),
            []
    end.

-spec find_sip_users(ne_binary(), whapps_call:call()) -> ne_binaries().
find_sip_users(GroupId, Call) ->
    GroupsJObj = cf_attributes:groups(Call),
    case [wh_json:get_value(<<"value">>, JObj)
          || JObj <- GroupsJObj,
             wh_json:get_value(<<"id">>, JObj) =:= GroupId
         ]
    of
        [] -> [];
        [GroupEndpoints] ->
            Ids = wh_json:get_keys(GroupEndpoints),
            sip_users_from_endpoints(find_endpoints(Ids, GroupEndpoints, Call), Call)
    end.

-spec sip_users_from_endpoints(ne_binaries(), whapps_call:call()) -> ne_binaries().
sip_users_from_endpoints(EndpointIds, Call) ->
    lists:foldl(fun(EndpointId, Acc) ->
                        case sip_user_of_endpoint(EndpointId, Call) of
                            'undefined' -> Acc;
                            Username -> [Username|Acc]
                        end
                end, [], EndpointIds).

-spec sip_user_of_endpoint(ne_binary(), whapps_call:call()) -> api_binary().
sip_user_of_endpoint(EndpointId, Call) ->
    case cf_endpoint:get(EndpointId, Call) of
        {'error', _} -> 'undefined';
        {'ok', Endpoint} ->
            wh_json:get_value([<<"sip">>, <<"username">>], Endpoint)
    end.

-spec find_endpoints(ne_binaries(), wh_json:object(), whapps_call:call()) -> ne_binaries().
find_endpoints(Ids, GroupEndpoints, Call) ->
    {DeviceIds, UserIds} =
        lists:partition(fun(Id) ->
                                wh_json:get_value([Id, <<"type">>], GroupEndpoints) =:= <<"device">>
                        end, Ids),
    find_user_endpoints(UserIds, lists:sort(DeviceIds), Call).

-spec find_user_endpoints(ne_binaries(), ne_binaries(), whapps_call:call()) -> ne_binaries().
find_user_endpoints([], DeviceIds, _) -> DeviceIds;
find_user_endpoints([UserId|UserIds], DeviceIds, Call) ->
    UserDeviceIds = cf_attributes:owned_by(UserId, <<"device">>, Call),
    find_user_endpoints(UserIds, lists:merge(lists:sort(UserDeviceIds), DeviceIds), Call).

no_users_in_group(Call) ->
    whapps_call_command:b_say(<<"no users found in group">>, Call).
no_channels_ringing(Call) ->
    whapps_call_command:b_say(<<"no channels ringing">>, Call).