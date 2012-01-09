%%%-------------------------------------------------------------------
%%% @author Adrian <adrian@adrianUbuntu>
%%% @copyright (C) 2012, id3as Ltd
%%% Created :  2 Jan 2012 by Adrian <adrian@id3as.co.uk>
%%%-------------------------------------------------------------------
-module(lager_mongo).

-behaviour(gen_event).

%% gen_event callbacks
-export([init/1, 
	 handle_event/2, 
	 handle_call/2, 
	 handle_info/2, 
	 terminate/2, 
	 code_change/3,
	 test_/0]).

-define(SERVER, ?MODULE). 
-define(SECONDS_TO_EPOCH, 62167219200). %% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})

-record(state, {
	  level,
	  db_name,
	  db_pool,
	  server,
	  tag}).

-record(log, {datetime, 
	      level, 
	      tag,
	      location,
	      pid,
	      module,
	      function,
	      line,
	      message}).

-define(RECORDS, [
		  {log, record_info(fields, log)}
		 ]).


%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init(Params) ->
    process_flag(trap_exit, true),

    io:format(user, "Params ~p~n", [Params]),

    LogServer = config_val(log_server, Params, "127.0.0.1"),
    LogDB = config_val(log_database, Params, log),
    LogLevel = config_val(log_level, Params, debug),
    Tag = config_val(tag, Params, undefined),
    
    application:start(mongodb),

    Pool = resource_pool:new(mongo:connect_factory(LogServer), 1),

    {ok, #state{level = lager_util:level_to_num(LogLevel),
		server = LogServer,
		db_name = LogDB,
		db_pool = Pool,
		tag = Tag}}.

handle_event({log, MsgLevel, {Date, Time}, 
	      [_LevelStr, Location, Message]}, 
	     State = #state{level = LogLevel, 
			    db_pool = Pool, 
			    db_name = DB,
			    tag = Tag}) when MsgLevel =< LogLevel ->
    
    Entry = (parse_location(Location))#log{
	      datetime = parse_datetime(lists:flatten(Date), lists:flatten(Time)),
	      level = MsgLevel,
	      message = Message,
	      tag = Tag},

    Record = map_to_db(Entry, ?RECORDS),
    case resource_pool:get(Pool) of
	{ok, Conn} ->
	    mongo:do(unsafe, slave_ok, Conn, DB, 
		     fun() ->
			     mongo:insert(lager_log, Record)
		     end);
	_ ->
	    ok
    end,
    {ok, State};

handle_event(_, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% handle_call
%%--------------------------------------------------------------------
handle_call({set_loglevel, Level}, State) ->
    {ok, ok, State#state{level = lager_util:level_to_num(Level) }};
    
handle_call(get_loglevel, State = #state{level = Level}) ->
    {ok, Level, State}.

handle_info(not_implemented, State) ->
    {ok, State}.

terminate(_Reason, #state{db_pool = Pool}) ->
    resource_pool:close(Pool),    
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
config_val(C, Params, Default) ->
  case lists:keyfind(C, 1, Params) of
    {C, V} -> V;
    _ -> Default
  end.
	
map_to_db(Record, RecordInfos) ->

    {_, Fields} = lists:keyfind(element(1, Record), 1, RecordInfos),

    map_inner(tl(tuple_to_list(Record)), Fields, RecordInfos).


map_inner(Values, Fields, RecordInfos) ->
    list_to_tuple(zip(Fields, Values, RecordInfos)).


zip([], [], _RecordInfos) ->
    [];

zip([_Field | Fields], [undefined | Values], RecordInfos) ->
    zip(Fields, Values, RecordInfos);

zip([Field | Fields], [Value | Values], RecordInfos) ->
    [Field, zip_value(Value) | zip(Fields, Values, RecordInfos)].


zip_value(Value) when is_list(Value) ->
    bson:utf8(Value);

zip_value(Value) when is_atom(Value) ->
    bson:utf8(atom_to_list(Value));
    
zip_value(Value) ->
    Value.


parse_location(Location) ->
    io:format("Location ~p~n", [Location]),
    case string:tokens(Location, "@") of
	[Pid] ->
	    #log{pid = Pid};
	[Pid, FileInfo] ->
	    case string:tokens(FileInfo, ": ") of
		[[Module], [Function], [Line]] ->
		    io:format("M ~p~nF ~p~nL ~p~n", [Module, Function, Line]),
		    #log{pid = Pid,
			 module = Module,
			 function = Function,
			 line = list_to_integer(Line)};
		_ ->
		    #log{location = Location}
	    end;
	_ ->
	    #log{pid = Location}
    end.

parse_datetime(Date, Time) ->
    [YY, MM, DD] = string:tokens(Date, "-"),
    [HH, MN, SS, Frac] = string:tokens(Time, ":."),
    io:format(user, "YY ~p, MM ~p, DD ~p, HH ~p, MN ~p, SS ~p~n", [YY, MM, DD, HH, MN, SS]),
    EpochSecs = to_epoch_seconds({{list_to_integer(YY), list_to_integer(MM), list_to_integer(DD)},
				  {list_to_integer(HH), list_to_integer(MN), list_to_integer(SS)}}),
    {EpochSecs div 1000000, EpochSecs rem 1000000, list_to_integer(Frac)}.
     
    

to_epoch_seconds(Datetime) ->
    calendar:datetime_to_gregorian_seconds(Datetime) - ?SECONDS_TO_EPOCH.

		    

%%--------------------------------------------------------------------
%%% Tests
%%--------------------------------------------------------------------
%% -ifdef(TEST).
%% -include_lib("eunit/include/eunit.hrl").
%% -compile(export_all).

test_() ->
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend, debug}, 
					  {lager_mongo, [{log_database, adrian}, {tag, "my tag"}]}, 
					  {lager_file_backend, 
					   [{"error.log", error, 10485760, "$D0", 5},
					    {"console.log", info, 10485760, "$D0", 5}]}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(lager),
    lager:log(info, self(), "Test INFO message"),
    lager:log(debug, self(), "Test DEBUG message"),
    lager:log(error, self(), "Test ERROR message"),
    lager:warning([{a,b}, {c,d}], "Hello", []),
    lager:info("Info ~p", ["variable"]).

%% -endif.
