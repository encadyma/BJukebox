-module(jb_websocket).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

-record(state, {name}).

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init(_Type, Req, _Opts) ->
    io:fwrite("Got websocket connection~n", []),
    {ok, Req, just_connected}.

websocket_handle({text, Msg}, Req, just_connected) ->
    Name = binary_to_list(Msg),
    case validate_name(Name) of
	true ->
	    case gen_server:call(manager, join) of
		ok ->
		    {reply, [{text, <<"ok">>}], Req, #state{name=Name}};
		_ ->
		    {reply, [{text, <<"error">>}], Req, just_connected}
	    end;
	_ ->
	    {reply, [{text, <<"error invalid">>}], Req, just_connected}
    end;

websocket_handle({text, Msg}, Req, State) when is_record(State, state) ->
    LMsg = binary_to_list(Msg),
    case string:tokens(LMsg, " ") of
	["queue" | _] ->
	    % Fetch the song, and wait to get a result back.
	    % When it does come back, it will come in the form of a
	    % {match, Songtuple} raw message, handled in websocket_info.
	    fetch_song_sup:get_metadata(
	      string:substr(LMsg, string:len("queue") + 2)),
	    {ok, Req, State};
	["remove", QueuePos] ->
	    gen_server:cast(manager,
			    {remove, State#state.name, list_to_integer(QueuePos)}),
	    {ok, Req, State};
	["ping"] ->
	    {reply, [{text, <<"pong">>}], Req, State};
	["skipme"] ->
	    gen_server:cast(manager, skipme),
	    {ok, Req, State}; 
	["volup"] ->
	    gen_server:cast(jb_mpd, {voldelta, 2}),
	    {ok, Req, State};
	["voldown"] ->
	    gen_server:cast(jb_mpd, {voldelta, -2}),
	    {ok, Req, State};
	["volumevote", OnTxt] ->
	    VoteVar = case OnTxt of
			  "novote" ->
			      novote;
			  VoteNumber ->
			      list_to_integer(VoteNumber)
		      end,
	    gen_server:cast(manager, {volumevote, State#state.name, VoteVar}),
	    {ok, Req, State};
	_ ->
    	    {ok, Req, State}
    end;
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.

websocket_info({match, Match}, Req, State) ->
    gen_server:cast(manager, {queue, State#state.name, Match}),
    {reply, [{text, <<"ok">>}], Req, State};
websocket_info({nomatch, _}, Req, State) ->
    {reply, [{text, <<"error">>}], Req, State};

websocket_info({manager_state, {Current, Queues}}, Req, State) ->
    CurrentJson = case Current of
		      {CurrentPlayer, CurrentSong} ->
			  [<<"{\"name\":">>, string_to_bitjson(CurrentPlayer),
			   <<",\"song\":">>, songtuple_to_bitjson(CurrentSong),
			   <<"}">>];
		      noone ->
			  string_to_bitjson("noone");
		      disconnected ->
			  string_to_bitjson("disconnected")
		  end,
    {reply, [{text, [<<"{\"current\":">>, CurrentJson,
		     <<",\"queues\":">>, list_to_bitjson(fun queueentry_to_bitjson/1, Queues),
		     <<"}">>]}], Req, State};

websocket_info({announce_vol, Volume}, Req, State) ->
    {reply, [{text, [<<"vol ">>,
		     integer_to_binary(round(Volume))]}],
     Req, State};

websocket_info(Info, Req, State) ->
    io:fwrite("Client got unknown data ~p~n", [Info]),
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, State) ->
    io:fwrite("Websocket client ~p disconnected.~n", [State]),
    ok.

list_to_bitjson(Func, [First | Rest]) ->
    [<<"[">>, Func(First), lists:map(fun(Term) -> [<<",">>, Func(Term)] end, Rest), <<"]">>];
list_to_bitjson(_Func, []) ->
    <<"[]">>.

queueentry_to_bitjson({Name, Songs}) ->
    [<<"{\"name\":">>, string_to_bitjson(Name), <<",\"songs\":">>, list_to_bitjson(fun songtuple_to_bitjson/1, Songs), <<"}">>].

songtuple_to_bitjson({Songname, Thumbnail, Songurl}) ->
    [<<"{\"title\":">>, string_to_bitjson(Songname),
     <<",\"thumb\":">>, string_to_bitjson(Thumbnail),
     <<",\"url\":">>, string_to_bitjson(Songurl),
     <<"}">>].

string_to_bitjson(String) ->
    [<<"\"">>, re:replace(String, "[\"\\\\]", "\\\\&", [global, {return, binary}]), <<"\"">>].

validate_name(Name) ->
    % ugly if statements
    if length(Name) =:= 0 -> false;
       length(Name) > 20 -> false;
       true ->
	   case re:run(Name, "^[a-zA-Z0-9]*$") of
	       nomatch -> false;
	       _ -> true
	   end
    end.

