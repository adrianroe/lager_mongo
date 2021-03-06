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
	 code_change/3]).

%% API
-export([update_params/1,
	 test_/0]).

-define(SERVER, ?MODULE). 
-define(SECONDS_TO_EPOCH, 62167219200). %% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})

-record(state, {
	  level = info,
	  db_name = log,
	  db_pool,
	  collection = lager_log,
	  server ="127.0.0.1",
	  node = true,
	  tag}).

-record(log, {datetime, 
	      level, 
	      tag,
	      location,
	      pid,
	      module,
	      function,
	      line,
	      node,
	      message}).

-define(RECORDS, [
		  {log, record_info(fields, log)}
		 ]).



%%%===================================================================
%%% API
%%%===================================================================
update_params(Params) ->
    case whereis(lager_event) of
        undefined ->
            %% lager isn't running
            {error, lager_not_running};
        Pid ->
            gen_event:notify(Pid, {lager_mongo_options, Params})
    end.    

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init(Params) ->
    process_flag(trap_exit, true),


    State = state_from_params(#state{}, Params),

    application:start(mongodb),
    Pool = resource_pool:new(mongo:connect_factory(State#state.server), 1),

    {ok, State#state{db_pool = Pool}}.

handle_event({log, MsgLevel, {Date, Time}, 
	      [_LevelStr, Location, Message]}, 
	     State = #state{level = LogLevel, 
			    db_pool = Pool, 
			    db_name = DB,
			    collection = Collection,
			    node = NodeName,
			    tag = Tag}) when MsgLevel =< LogLevel ->
    

    Entry = (parse_location(Location))#log{
	      datetime = parse_datetime(lists:flatten(Date), lists:flatten(Time)),
	      level = MsgLevel,
	      message = Message,
	      node = NodeName,
	      tag = Tag},

    Record = map_to_db(Entry, ?RECORDS),
    case resource_pool:get(Pool) of
	{ok, Conn} ->
	    mongo:do(unsafe, slave_ok, Conn, DB, 
		     fun() ->
			     mongo:insert(Collection, Record)
		     end);
	_ ->
	    ok
    end,
    {ok, State};

handle_event({lager_mongo_options, Params}, State) ->
    {ok, state_from_params(State, Params)};

handle_event(_X, State) ->
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
    case string:tokens(Location, "@") of
	[Pid] ->
	    #log{pid = string:strip(Pid)};
	[Pid, FileInfo] ->
	    case string:tokens(FileInfo, ": ") of
		[[Module], [Function], [Line]] ->
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
    EpochSecs = to_epoch_seconds({{list_to_integer(YY), list_to_integer(MM), list_to_integer(DD)},
				  {list_to_integer(HH), list_to_integer(MN), list_to_integer(SS)}}),
    {EpochSecs div 1000000, EpochSecs rem 1000000, list_to_integer(Frac)}.
     
    

to_epoch_seconds(Datetime) ->
    calendar:datetime_to_gregorian_seconds(Datetime) - ?SECONDS_TO_EPOCH.


state_from_params(OrgState = #state{server = OldServer,
				    level = OldLevel,
				    db_name = OldDatabase,
				    collection = OldCollection,
				    node = OldNode,
				    tag = OldTag}, Params) ->
    LogServer = config_val(log_server, Params, OldServer),
    LogDB = config_val(log_database, Params, OldDatabase),
    LogLevel = config_val(log_level, Params, OldLevel),
    Collection = config_val(collection, Params, OldCollection),
    Node = config_val(node, Params, OldNode),
    Tag = config_val(tag, Params, OldTag),
   
    LogLevelNum = case is_atom(LogLevel) of
		      true -> lager_util:level_to_num(LogLevel);
		      _ -> LogLevel
		  end,
    NodeName = case Node of
		   true -> 
		       node();
		   false ->
		       undefined;
		   Name ->
		       Name
	       end,
    OrgState#state{level = LogLevelNum,
		   server = LogServer,
		   db_name = LogDB,
		   collection = Collection,
		   node = NodeName,
		   tag = Tag}.
		    

%%--------------------------------------------------------------------
%%% Tests
%%--------------------------------------------------------------------
%% -ifdef(TEST).
%% -include_lib("eunit/include/eunit.hrl").
%% -compile(export_all).

test_() ->
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend, debug}, 
					  {lager_mongo, [{log_database, test_log_database}, 
							 {tag, "my tag"},
							 {node, false},
							 {log_level, debug},
							 {collection, test_collection}]}, 
					  {lager_file_backend, 
					   [{"error.log", error, 10485760, "$D0", 5},
					    {"console.log", info, 10485760, "$D0", 5}]}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(lager),
    lager:log(info, self(), "Test INFO message"),
    lager:log(debug, self(), "Test DEBUG message"),
    lager_mongo:update_params([{tag, "Updated tag"}, {node, true}]),
    lager:log(error, self(), "Test ERROR message"),
    lager:warning([{a,b}, {c,d}], "Hello", []),
    lager:info("Info ~p", ["variable"]).

%% -endif.
