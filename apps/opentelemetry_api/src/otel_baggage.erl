%%%------------------------------------------------------------------------
%% Copyright 2019, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc Baggage is used to annotate telemetry, adding context and
%% information to metrics, traces, and logs. It is represented by a set
%% of name/value pairs describing user-defined properties.
%% @end
%%%-------------------------------------------------------------------------
-module(otel_baggage).

-export([set/1,
         set/2,
         set/3,
         get_all/0,
         get_all/1,
         clear/0,
         clear/1,
         get_text_map_propagators/0]).

%% keys and values are UTF-8 binaries
-type key() :: unicode:unicode_binary().
-type value() :: unicode:unicode_binary().

-type t() :: #{key() => value()}.

-export_type([t/0,
              key/0,
              value/0]).

-define(DEC2HEX(X),
        if ((X) >= 0) andalso ((X) =< 9) -> (X) + $0;
           ((X) >= 10) andalso ((X) =< 15) -> (X) + $A - 10
        end).

-define(BAGGAGE_KEY, '$__otel_baggage_ctx_key').
-define(BAGGAGE_HEADER, <<"baggage">>).

-spec set(#{key() => value()} | [{key(), value()}]) -> otel_ctx:t().
set(KeyValues) when is_list(KeyValues) ->
    set(maps:from_list(KeyValues));
set(KeyValues) when is_map(KeyValues) ->
    Baggage = otel_ctx:get_value(?BAGGAGE_KEY, #{}),
    otel_ctx:set_value(?BAGGAGE_KEY, maps:merge(Baggage, KeyValues)).

%% Ctx will never be a list or binary so we can tell if a context is passed by checking that
-spec set(otel_ctx:t() | key(), #{key() => value()} | [{key(), value()}] | value()) -> otel_ctx:t().
set(Key, Value) when is_list(Key) ; is_binary(Key) ->
    Baggage = otel_ctx:get_value(?BAGGAGE_KEY, #{}),
    otel_ctx:set_value(?BAGGAGE_KEY, Baggage#{Key => Value});
set(Ctx, KeyValues) when is_list(KeyValues) ->
    set(Ctx, maps:from_list(KeyValues));
set(Ctx, KeyValues) when is_map(KeyValues) ->
    Baggage = otel_ctx:get_value(Ctx, ?BAGGAGE_KEY, #{}),
    otel_ctx:set_value(Ctx, ?BAGGAGE_KEY, maps:merge(Baggage, KeyValues)).

-spec set(otel_ctx:t(), key(), value()) -> otel_ctx:t().
set(Ctx, Key, Value) ->
    Baggage = otel_ctx:get_value(Ctx, ?BAGGAGE_KEY, #{}),
    otel_ctx:set_value(Ctx, ?BAGGAGE_KEY, Baggage#{Key => Value}).

-spec get_all() -> t().
get_all() ->
    otel_ctx:get_value(?BAGGAGE_KEY, #{}).

-spec get_all(otel_ctx:t()) -> t().
get_all(Ctx) ->
    otel_ctx:get_value(Ctx, ?BAGGAGE_KEY, #{}).

-spec clear() -> ok.
clear() ->
    otel_ctx:set_value(?BAGGAGE_KEY, #{}).

-spec clear(otel_ctx:t()) -> otel_ctx:t().
clear(Ctx) ->
    otel_ctx:set_value(Ctx, ?BAGGAGE_KEY, #{}).

-spec get_text_map_propagators() -> {otel_propagator:text_map_extractor(), otel_propagator:text_map_injector()}.
get_text_map_propagators() ->
    ToText = fun(Baggage) when is_map(Baggage) ->
                     case maps:fold(fun(Key, Value, Acc) ->
                                            [$,, [encode_key(Key), "=", encode_value(Value)] | Acc]
                                    end, [], Baggage) of
                         [$, | List] ->
                             [{?BAGGAGE_HEADER, unicode:characters_to_binary(List)}];
                         _ ->
                             []
                     end;
                (_) ->
                     []
             end,
    FromText = fun(Headers, CurrentBaggage) ->
                       case lookup(?BAGGAGE_HEADER, Headers) of
                           undefined ->
                               CurrentBaggage;
                           String ->
                               Pairs = string:lexemes(String, [$,]),
                               lists:foldl(fun(Pair, Acc) ->
                                                   [Key, Value] = string:split(Pair, "="),
                                                   Acc#{decode_key(Key) =>
                                                            decode_value(Value)}
                                           end, CurrentBaggage, Pairs)
                       end
               end,
    Inject = otel_ctx:text_map_injector(?BAGGAGE_KEY, ToText),
    Extract = otel_ctx:text_map_extractor(?BAGGAGE_KEY, FromText),
    {Extract, Inject}.

%% find a header in a list, ignoring case
lookup(_, []) ->
    undefined;
lookup(Header, [{H, Value} | Rest]) ->
    case string:equal(Header, H, true, none) of
        true ->
            Value;
        false ->
            lookup(Header, Rest)
    end.

encode_key(Key) ->
    form_urlencode(Key, [{encoding, utf8}]).

encode_value(Value) ->
    form_urlencode(Value, [{encoding, utf8}]).

decode_key(Key) ->
    uri_string:percent_decode(string:trim(unicode:characters_to_binary(Key))).

decode_value(Value) ->
    uri_string:percent_decode(string:trim(unicode:characters_to_binary(Value))).

%% HTML 5.2 - 4.10.21.6 URL-encoded form data - WHATWG URL (10 Jan 2018) - UTF-8
%% HTML 5.0 - 4.10.22.6 URL-encoded form data - encoding (non UTF-8)
form_urlencode(Cs, [{encoding, latin1}]) when is_list(Cs) ->
    B = convert_to_binary(Cs, utf8, utf8),
    html5_byte_encode(base10_encode(B));
form_urlencode(Cs, [{encoding, latin1}]) when is_binary(Cs) ->
    html5_byte_encode(base10_encode(Cs));
form_urlencode(Cs, [{encoding, Encoding}])
  when is_list(Cs), Encoding =:= utf8; Encoding =:= unicode ->
    B = convert_to_binary(Cs, utf8, Encoding),
    html5_byte_encode(B);
form_urlencode(Cs, [{encoding, Encoding}])
  when is_binary(Cs), Encoding =:= utf8; Encoding =:= unicode ->
    html5_byte_encode(Cs);
form_urlencode(Cs, [{encoding, Encoding}]) when is_list(Cs); is_binary(Cs) ->
    throw({error,invalid_encoding, Encoding});
form_urlencode(Cs, _) ->
    throw({error,invalid_input, Cs}).


%% For each character in the entry's name and value that cannot be expressed using
%% the selected character encoding, replace the character by a string consisting of
%% a U+0026 AMPERSAND character (&), a "#" (U+0023) character, one or more ASCII
%% digits representing the Unicode code point of the character in base ten, and
%% finally a ";" (U+003B) character.
base10_encode(Cs) ->
    base10_encode(Cs, <<>>).
%%
base10_encode(<<>>, Acc) ->
    Acc;
base10_encode(<<H/utf8,T/binary>>, Acc) when H > 255 ->
    Base10 = convert_to_binary(integer_to_list(H,10), utf8, utf8),
    base10_encode(T, <<Acc/binary,"&#",Base10/binary,$;>>);
base10_encode(<<H/utf8,T/binary>>, Acc) ->
    base10_encode(T, <<Acc/binary,H>>).


html5_byte_encode(B) ->
    html5_byte_encode(B, <<>>).
%%
html5_byte_encode(<<>>, Acc) ->
    Acc;
html5_byte_encode(<<$ ,T/binary>>, Acc) ->
    html5_byte_encode(T, <<Acc/binary,$+>>);
html5_byte_encode(<<H,T/binary>>, Acc) ->
    case is_url_char(H) of
        true ->
            html5_byte_encode(T, <<Acc/binary,H>>);
        false ->
            <<A:4,B:4>> = <<H>>,
            html5_byte_encode(T, <<Acc/binary,$%,(?DEC2HEX(A)),(?DEC2HEX(B))>>)
    end;
html5_byte_encode(H, _Acc) ->
    throw({error,invalid_input, H}).


%% Return true if input char can appear in form-urlencoded string
%% Allowed chararacters:
%%   0x2A, 0x2D, 0x2E, 0x30 to 0x39, 0x41 to 0x5A,
%%   0x5F, 0x61 to 0x7A
is_url_char(C)
  when C =:= 16#2A; C =:= 16#2D;
       C =:= 16#2E; C =:= 16#5F;
       16#30 =< C, C =< 16#39;
       16#41 =< C, C =< 16#5A;
       16#61 =< C, C =< 16#7A -> true;
is_url_char(_) -> false.

%% Convert to binary
convert_to_binary(Binary, InEncoding, OutEncoding) ->
    case unicode:characters_to_binary(Binary, InEncoding, OutEncoding) of
        {error, _List, RestData} ->
            throw({error, invalid_input, RestData});
        {incomplete, _List, RestData} ->
            throw({error, invalid_input, RestData});
        Result ->
            Result
    end.
