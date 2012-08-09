-module(oauth2_redis_backend).


-export([
    start/0,
    stop/0,
    child_spec/1,
    add_user/2,
    delete_user/1,
    add_client/2, add_client/3,
    delete_client/1
]).

-export([
    authenticate_username_password/3,
    authenticate_client/3,
    associate_access_token/2,
    resolve_access_token/1,
    get_redirection_uri/1
]).

-define(POOL, ?MODULE).
-define(ACCESS_TOKEN_TABLE, <<"oauth_access_token">>).
-define(USER_TABLE, <<"oauth_user">>).
-define(CLIENT_TABLE, <<"oauth_client">>).

-record(client, {
    client_id     :: binary(),
    client_secret :: binary(),
    redirect_uri  :: binary()
}).

-record(user, {
    username :: binary(),
    password :: binary()
}).

%%%===================================================================
%%% API
%%%===================================================================

start() ->
    Args = [
        {name, {local, ?POOL}},
        {worker_module, eredis},
        {size, 5}
    ],
    poolboy:start_link(Args).

stop() ->
    poolboy:stop(?POOL).

child_spec(Args) ->
    WorkerModule = {worker_module, eredis},
    PoolName = {name, {local, ?POOL}},
    PoolArgs = lists:keystore(worker_module, 1, Args, WorkerModule),
    PoolArgs1 = lists:keystore(name, 1, PoolArgs, PoolName),
    io:format(PoolArgs1),
    poolboy:child_spec(?POOL, PoolArgs1).

add_user(Username, Password) ->
    put(?USER_TABLE, Username, #user{username = Username, password = Password}).

delete_user(Username) ->
    delete(?USER_TABLE, Username).

add_client(Id, Secret, RedirectUri) ->
    put(?CLIENT_TABLE, Id, #client{client_id = Id,
                                   client_secret = Secret,
                                   redirect_uri = RedirectUri
                                  }).

add_client(Id, Secret) ->
    add_client(Id, Secret, undefined).

delete_client(Id) ->
    delete(?CLIENT_TABLE, Id).

%%%===================================================================
%%% OAuth2 backend functions
%%%===================================================================

authenticate_username_password(Username, Password, _Scope) ->
    case get(?USER_TABLE, Username) of
        {ok, #user{password = UserPw}} ->
            case Password of
                UserPw ->
                    {ok, {<<"user">>, Username}};
                _ ->
                    {error, badpass}
            end;
        Error = {error, notfound} ->
            Error
    end.

authenticate_client(ClientId, ClientSecret, _Scope) ->
    case get(?CLIENT_TABLE, ClientId) of
        {ok, #client{client_secret = ClientSecret}} ->
            {ok, {<<"client">>, ClientId}};
        {ok, #client{client_secret = _WrongSecret}} ->
            {error, badsecret};
        _ ->
            {error, notfound}
    end.

associate_access_token(AccessToken, Context) ->
    put(?ACCESS_TOKEN_TABLE, AccessToken, Context).

resolve_access_token(AccessToken) ->
    %% The case trickery is just here to make sure that
    %% we don't propagate errors that cannot be legally
    %% returned from this function according to the spec.
    case get(?ACCESS_TOKEN_TABLE, AccessToken) of
        Value = {ok, _} ->
            Value;
        Error = {error, notfound} ->
            Error
    end.

get_redirection_uri(ClientId) ->
    case get(?CLIENT_TABLE, ClientId) of
        {ok, #client{redirect_uri = RedirectUri}} ->
            {ok, RedirectUri};
        Error = {error, notfound} ->
            Error
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get(Table, Id) ->
    Key = key(Table, Id),
    txn(fun(C) ->
        case eredis:q(C, ["GET", Key]) of
            {ok, undefined} ->
                {error, notfound};
            {ok, Bin} ->
                {ok, unserialize(Table, Bin)};
            {error, Error} ->
                lager:error(<<"Could not get ~s: ~s">>, [Key, Error])
        end
    end).

put(Table, Id, Value) ->    
    Key = key(Table, Id),
    txn(fun(C) ->
        case eredis:q(C, ["SET", Key, serialize(Table, Value)]) of
            {ok, <<"OK">>} ->
                true;
            {error, Error} ->
                lager:error(<<"Could not put ~s: ~s">>, [Key, Error]),
                false
        end                
    end).

delete(Table, Id) ->    
    Key = key(Table, Id),
    txn(fun(C) ->
        case eredis:q(C, ["DEL", Key]) of
            {ok, <<"1">>} ->
                true;
            {ok, <<"0">>} ->
                lager:warning(<<"Deleted a non-existing object: ~s">>, [Key]),
                true;
            {error, Error} ->
                lager:error(<<"Could not delete ~s: ~s">>, [Key, Error]),
                false
        end
    end).

txn(Fun) ->
    poolboy:transaction(?POOL, Fun).

key(Table, Id) ->
    <<Table/binary, ":", Id/binary>>.

%% object serialization
%% for now we are just shoving binary representations
%% maybe in the future do something else

serialize(_, Value) ->
    term_to_binary(Value).

unserialize(_, Value) ->
    binary_to_term(Value).


%% ----------------------------------------------------------------------------
%%
%% oauth2: Erlang OAuth 2.0 implementation
%%
%% Copyright (c) 2012 KIVRA
%%
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%% DEALINGS IN THE SOFTWARE.
%%
%% ----------------------------------------------------------------------------
