-module(pgsql_codec).
-export([
    new/3,
    new/2,
    update_parameters/2,
    update_types/2,
    has_types/2,
    encode/3,
    decode/3
]).
-export_type([
    codec/0
]).


-callback init(params(), options()) -> state().
-callback encodes(state()) -> [atom()].
-callback encode(type(), Value :: any(), codec(), state()) -> iodata().
-callback decodes(state()) -> [atom()].
-callback decode(type(), binary(), codec(), state()) -> any().
-optional_callbacks([init/2]).


-record(codec, {
    parameters :: map(),
    options :: map(),
    states = [] :: [{module(), state()}],
    types = ordsets:new() :: ordsets:ordset(pgsql_types:oid()),
    encoders = [] :: [{pgsql_types:oid(), module(), type()}],
    decoders = [] :: [{pgsql_types:oid(), module(), type()}]
}).
-type oid() :: pgsql_types:oid().
-type type() :: pgsql_types:type().
-type types() :: [type()].
-type params() :: map().
-type options() :: map().
-type state() :: any().
-opaque codec() :: codec().

-include("../../include/types.hrl").
-define(default_codecs, [
    pgsql_codec_array,
    pgsql_codec_binary,
    pgsql_codec_bool,
    pgsql_codec_date,
    pgsql_codec_datetime,
    pgsql_codec_enum,
    pgsql_codec_float4,
    pgsql_codec_float8,
    pgsql_codec_hstore,
    pgsql_codec_int2,
    pgsql_codec_int4,
    pgsql_codec_int8,
    pgsql_codec_interval,
    pgsql_codec_json,
    pgsql_codec_network,
    pgsql_codec_oid,
    pgsql_codec_record,
    pgsql_codec_text,
    pgsql_codec_time,
    pgsql_codec_uuid,
    pgsql_codec_void
]).


-spec new(params(), options(), [module()]) -> codec().
new(Parameters, Options, ExtraCodecs) ->
    Modules = ExtraCodecs ++ ?default_codecs,
    #codec{
        parameters = Parameters,
        options = Options,
        states = [{Module, mod_init(Module, Parameters, Options)} || Module <- Modules]
    }.

new(Parameters, Options) ->
    new(Parameters, Options, []).

mod_init(Module, Parameters, Options) ->
    case erlang:function_exported(Module, init, 2) of
        true ->
            Module:init(Parameters, Options);
        false ->
            Options
    end.

-spec update_parameters(params(), codec()) -> codec().
update_parameters(Parameters, #codec{options = Options, states = States} = Codec) ->
    Codec#codec{
        parameters = Parameters,
        states = [{Module, mod_init(Module, Parameters, Options)} || {Module, _} <- States]
    }.

-spec update_types(types(), codec()) -> codec().
update_types(Types, #codec{states = States} = Codec) ->
    Codec#codec{
        types = ordsets:from_list([Oid || #pgsql_type_info{oid = Oid} <- Types]),
        encoders = lists:foldl(fun (#pgsql_type_info{oid = Oid, send = Send} = Type, Acc) ->
            case find_encoder(Send, States) of
                {ok, Encoder} -> [{Oid, Encoder, Type} | Acc];
                error -> Acc
            end
        end, [], Types),
        decoders = lists:foldl(fun (#pgsql_type_info{oid = Oid, recv = Recv} = Type, Acc) ->
            case find_decoder(Recv, States) of
                {ok, Decoder} -> [{Oid, Decoder, Type} | Acc];
                error -> Acc
            end
        end, [], Types)
    }.

-spec has_types([oid()], codec()) -> boolean().
has_types(Types, #codec{types = Known}) ->
    ordsets:is_subset(ordsets:from_list(Types), Known).

find_encoder(_, []) ->
    error;
find_encoder(Send, [{Module, State} | Codecs]) ->
    case lists:member(Send, Module:encodes(State)) of
        true -> {ok, Module};
        false -> find_encoder(Send, Codecs)
    end.

find_decoder(_, []) ->
    error;
find_decoder(Recv, [{Module, State} | Codecs]) ->
    case lists:member(Recv, Module:decodes(State)) of
        true -> {ok, Module};
        false -> find_decoder(Recv, Codecs)
    end.

-spec encode(oid(), any(), codec()) -> binary().
encode(Oid, Value, #codec{states = States, encoders = Encoders} = Codec) ->
    case lists:keyfind(Oid, 1, Encoders) of
        {Oid, Module, Type} ->
            {Module, State} = lists:keyfind(Module, 1, States),
            Module:encode(Type, Value, Codec, State);
        false ->
            exit({no_encoder, Oid})
    end.

-spec decode(oid(), binary(), codec()) -> binary().
decode(Oid, Value, #codec{states = States, decoders = Decoders} = Codec) ->
    case lists:keyfind(Oid, 1, Decoders) of
        {Oid, Module, Type} ->
            {Module, State} = lists:keyfind(Module, 1, States),
            Module:decode(Type, Value, Codec, State);
        false ->
            exit({no_decoder, Oid})
    end.
