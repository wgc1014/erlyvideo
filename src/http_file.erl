-module(http_file).
-include("log.hrl").

% Application API
-export([start/2, stop/1, config_change/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([open/2, pread/3, close/1]).

-export([cache_path/2, add_client/2]).

-export([start/0, stop/0, start_link/2, reload/0, archive/0]).

-behaviour(gen_server).

-record(http_file, {
  url,
  cache_file,
  temp_path,
  path,
  request_id,
  options,
  streams = [],
  requests = [],
  size,
  file_cached = false,
  clients = []
}).


-define(COVER_LIMIT, 100000).

start() ->
  inets:start(),
  application:start(http_file).

stop() ->
  application:stop(http_file),
  application:unload(http_file).
  

reload() ->
  {ok, Modules} = application:get_key(http_file,modules),
  [begin
    code:soft_purge(Module),
    code:load_file(Module)
  end || Module <- Modules].



archive() ->
  make:all([load]),
  application:load(http_file),
  {ok, Version} = application:get_key(http_file,vsn),
  zip:create("http_file-"++Version++".ez", ["http_file/ebin"], [{cwd, "../"},{compress,all},{uncompress,[".beam",".app"]},verbose]).


  
%%--------------------------------------------------------------------
%% @spec (Type::any(), Args::list()) -> any()
%% @doc Starts RTMP library
%% @end 
%%--------------------------------------------------------------------

start(_Type, _Args) -> 
  http_file_sup:start_link().



%%--------------------------------------------------------------------
%% @spec (Any::any()) -> ok()
%% @doc Stop RTMP library
%% @end 
%%--------------------------------------------------------------------
stop(_S) ->
  ok.


%%--------------------------------------------------------------------
%% @spec (Any::any(),Any::any(),Any::any()) -> any()
%% @doc Reload ErlMedia Application config
%% @end 
%%--------------------------------------------------------------------
config_change(_Changed, _New, _Remove) ->
  ok.
  

%%%%%%%%% File API  %%%%%%%%%%%%


open(URL, Options) ->
  % {ok, CachePath} = application:get_env(http_file, cache_path),
  % http_file_sup:start_file(URL, [{cache_path,CachePath}|Options]).
  http_file_tracker:open(URL, Options).
  
  
add_client(File, Opener) ->
  gen_server:call(File, {add_client, Opener}).

pread({cached,File}, Offset, Limit) ->
  file:pread(File, Offset, Limit);

pread(File, Offset, Limit) ->
  % ?D({"Requesting", Offset, Limit}),
  gen_server:call(File, {pread, Offset, Limit}, infinity).

close({cached,File}) ->
  file:close(File);
  
close(File) ->
  gen_server:call(File, {close, self()}).

%%%%%%%%%% Gen server API %%%%%%%%

cache_path(CachePath, URL) ->
  "http://" ++ ClearedName = URL,
  filename:join(CachePath, ClearedName).


start_link(URL, Options) ->
  gen_server:start_link(?MODULE, [URL, Options], []).

init([URL, Options]) ->
  Path = cache_path(proplists:get_value(cache_path, Options), URL),
  TempPath = Path ++ ".tmp",
  filelib:ensure_dir(Path),
  {ok, CacheFile} = file:open(TempPath, [write, read, binary]),
  ?D({"Storing",URL,to,Path, Options}),
  self() ! start_download,
  {ok, #http_file{url = URL, cache_file = CacheFile, path = Path, temp_path = TempPath, options = Options}}.
  

handle_call({pread, Offset, _Limit}, _From, #http_file{size = Size} = File)
  when Offset >= Size ->
  {reply, eof, File};


handle_call({pread, Offset, Limit}, From, #http_file{size = Size} = File) when Offset + Limit > Size ->
  handle_call({pread, Offset, Size - Offset}, From, File);

handle_call({pread, Offset, Limit}, From, #http_file{streams = Streams} = File) ->
  case is_data_cached(Streams, Offset, Limit) of
    true ->
      % ?D({"Data ok"}),
      {reply, fetch_cached_data(File, Offset, Limit), File};
    false ->
      ?D({"No data, waiting"}),
      File1 = schedule_request(File, {From, Offset, Limit}),
      {noreply, File1}
  end;    


handle_call({add_client, Opener}, _From, #http_file{clients = Clients} = State) ->
  Clients1 = case proplists:get_value(Opener, Clients) of
    undefined ->
      Ref = erlang:monitor(process, Opener),
      [{Opener,Ref}|Clients];
    _ ->
      Clients
  end,
  {reply, ok, State#http_file{clients = Clients1}};


handle_call({close, Client}, _From, #http_file{clients = Clients, file_cached = Cached} = State) ->
  case lists:keytake(Client, 1, Clients) of
    {value, Client, NewClients} ->
      ?D({"closing for", Client}),
      {reply, ok, State#http_file{clients = NewClients}};
    {value, Client, []} when Cached == true ->
      {stop, normal, State#http_file{clients = []}};
    _ ->  
    {reply, ok, State}
  end;
  
handle_call(Unknown, From, File) ->
  ?D({"Unknown call:", Unknown, From, File}),
  {stop, {error, unknown_call, Unknown}, File}.
  

handle_cast(_, State) ->
  {noreply, State}.  


handle_info(start_download, #http_file{url = URL} = State) ->
  {ok, {_, Headers, _}} = httpc:request(head, {URL, []}, [], []),
  ?D(Headers),
  Length = proplists:get_value("content-length", Headers),
  {ok, FirstRequest} = http_file_sup:start_request(self(), URL, 0),
  erlang:monitor(process, FirstRequest),
  {noreply, State#http_file{streams = [{FirstRequest, 0, 0}], size = list_to_integer(Length)}};

handle_info({bin, Bin, Offset, Stream}, #http_file{cache_file = Cache, streams = Streams, requests = Requests, size = Size} = State) ->
  case lists:keyfind(Stream, 1, Streams) of
    false -> 
      % ?D({"Got message from dead process", {bin, size(Bin), Offset, Stream}}),
      {noreply, State};
    _ -> 
      ok = file:pwrite(Cache, Offset, Bin),
      % ?D({"Got bin", Offset, size(Bin), Request, Streams}),
      NewStreams1 = update_map(Streams, Stream, Offset, size(Bin)),
      {NewStreams2, Removed} = glue_map(NewStreams1),
      % ?D({"Removing streams", NewStreams2, Removed}),
      lists:foreach(fun(OldStream) ->
        OldStream ! stop
      end, Removed),
      {NewRequests, Replies} = match_requests(Requests, NewStreams2),
      % ?D({"Matching requests", NewRequests, Replies}),
      lists:foreach(fun({From, Position, Limit}) ->
        {ok, Data} = file:pread(Cache, Position, Limit),
        ?D({"Replying to", From, Offset, Limit}),
        gen_server:reply(From, {ok, Data})
      end, Replies),
      
      NewStreams = NewStreams2,
      
      FileCached = case NewStreams of
        [{_,0,Size}] ->
          ?D({"File is fully downloaded", State#http_file.temp_path, State#http_file.path}),
          file:rename(State#http_file.temp_path, State#http_file.path),
          true;
        _ ->
          false
      end,
      stop_if_no_clients(State#http_file{streams = NewStreams, requests = NewRequests, file_cached = FileCached})
  end;
  
handle_info({'DOWN', _,process, Stream, _Reason}, #http_file{streams = Streams, clients = Clients} = State) ->
  case lists:keytake(Stream, 1, Streams) of
    {value, Stream, NewStreams} ->
      stop_if_no_clients(State#http_file{streams = NewStreams});
    _ ->
      case lists:keytake(Stream, 1, Clients) of
        {value, Stream, NewClients} ->
          stop_if_no_clients(State#http_file{clients = NewClients});
        _ ->
          ?D({unknown_died, Stream, State}),
          {noreply, State}
      end
  end;
  

handle_info(Message, State) ->
  ?D({"Some message:", Message}),
  {noreply, State}.


stop_if_no_clients(#http_file{file_cached = true, clients = []} = State) ->
  {stop, normal, State};
  
stop_if_no_clients(State) ->
  {noreply, State}.
  
terminate(_Reason, _State) ->
  ok.
  
code_change(_Old, State, _Extra) ->
  {ok, State}.
  
%%%----------------------------
  
  
schedule_request(#http_file{requests = Requests, streams = Streams, url = URL} = File, {_From, Offset, Limit} = Request) ->
  NewStreams = case has_covering_stream(Streams, Request) of
    true -> Streams;
    false ->
      {ok, Stream} = http_file_sup:start_request(self(), URL, Offset),
      erlang:monitor(process, Stream),
      ?D({"Starting new stream for", URL, Offset, Limit, Stream}),
      lists:ukeymerge(1, [{Stream, Offset, 0}], Streams)
  end,
  File#http_file{streams = NewStreams, requests = lists:ukeymerge(1, [Request], Requests)}.
  
  
has_covering_stream([{_Stream, RequestOffset, _Size} | _], {_Client, Offset, _Limit}) 
  when RequestOffset =< Offset andalso RequestOffset >= Offset - ?COVER_LIMIT ->
  true;
has_covering_stream([_Stream|Streams], Request) -> has_covering_stream(Streams, Request);
has_covering_stream([], _Request) -> false.

  
fetch_cached_data(#http_file{cache_file = Cache}, Offset, Limit) ->
  file:pread(Cache, Offset, Limit).
  
update_map(Streams, Stream, Offset, Size) ->
  {value, Entry, Streams1} = lists:keytake(Stream, 1, Streams),
  {Stream, OldOffset, OldSize} = Entry,
  Offset = OldOffset + OldSize,
  NewEntry = {Stream, OldOffset, OldSize + Size},
  lists:keysort(2, lists:ukeymerge(1, [NewEntry], Streams1)).
  
  
glue_map(Streams) ->
  Sorted = lists:keysort(2, Streams),
  glue_map(Sorted, [], []).

glue_map([Stream], NewStreams, Removed) ->
  {lists:keysort(2, [Stream|NewStreams]), lists:keysort(2, Removed)};

glue_map([Stream1, Stream2 | Streams], NewStreams, Removed) ->
  case intersect(Stream1, Stream2) of
    {leave, R1, R2} ->
      glue_map([R2|Streams], [R1 | NewStreams], Removed);
    {remove, R1, Key} ->
      glue_map([R1|Streams], NewStreams, [Key|Removed])
  end.

%%   Start1....End1   Start2...End2  
intersect({_Key1, Offset1, Size1} = R1, {_Key2, Offset2, _Size2} = R2) 
                                       when Offset1 + Size1 < Offset2 ->
  {leave, R1, R2};

%%   Start1....Start2...End1...End2
intersect({Key1, Offset1, Size1}, {Key2, Offset2, Size2}) 
  when Offset1 + Size1 >= Offset2 andalso Offset1 + Size1 < Offset2 + Size2 ->
  {remove, {Key2, Offset1, Offset2 + Size2 - Offset1}, Key1};


%%   Start1....Start2...End2...End1
intersect({_Key1, Offset1, Size1} = R1, {Key2, Offset2, Size2}) 
  when Offset1 + Size1 >= Offset2 andalso Offset1 + Size1 >= Offset2 + Size2 ->
  {remove, R1, Key2}.


match_requests(Requests, Streams) ->
  match_requests(Requests, Streams, [], []).

match_requests([], _Streams, NewRequests, Replies) ->
  {NewRequests, Replies};
  
match_requests([{From, Offset, Size}|Requests], Streams, NewRequests, Replies) ->
  case is_data_cached(Streams, Offset, Size) of
    true ->
      match_requests(Requests, Streams, NewRequests, [{From, Offset, Size}|Replies]);
    false ->
      match_requests(Requests, Streams, [{From, Offset, Size}|NewRequests], Replies)
  end.


is_data_cached([], _Offset, _Size) ->
  false;
  
is_data_cached([{_Request, CurrentOffset, CurrentSize} | _], Offset, Size) 
  when Offset >= CurrentOffset andalso Offset + Size =< CurrentOffset + CurrentSize ->
  true;

is_data_cached([_ | Streams], Offset, Size) ->
  is_data_cached(Streams, Offset, Size).
  

%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").

update_map1_test() ->
  Map1 = [{a, 0, 10}],
  ?assertEqual([{a, 0, 20}], update_map(Map1, a, 10, 10)).

update_map2_test() ->
  Map1 = [{a, 0, 10}, {b, 15, 15}],
  ?assertEqual([{a, 0, 20},{b, 15, 15}], update_map(Map1, a, 10, 10)).
  

is_data_cached_test() ->
  Map1 = [{a, 0, 10}, {b, 15, 15}],
  ?assertEqual(true, is_data_cached(Map1, 0, 10)),
  ?assertEqual(true, is_data_cached(Map1, 17, 5)),
  ?assertEqual(false, is_data_cached(Map1, 0, 25)),
  ?assertEqual(false, is_data_cached(Map1, 9, 2)),
  ?assertEqual(true, is_data_cached(Map1, 9, 1)).
 
 
 
intersect_test() ->
  ?assertEqual({remove, {b, 0, 30}, a}, intersect({a, 0, 20}, {b, 20, 10})),
  ?assertEqual({leave, {a, 0, 18}, {b, 20, 10}}, intersect({a, 0, 18}, {b, 20, 10})),
  ?assertEqual({remove, {a, 0, 45}, b}, intersect({a, 0, 45}, {b, 20, 10})).

glue_map1_test() ->
  Map = [{a, 0, 20}, {b, 20, 10}],
  ?assertEqual({[{b, 0, 30}], [a]}, glue_map(Map)).


glue_map2_test() ->
  Map = [{a, 0, 25}, {b, 20, 10}],
  ?assertEqual({[{b, 0, 30}], [a]}, glue_map(Map)).


glue_map3_test() ->
  Map = [{a, 0, 45}, {b, 20, 10}, {c, 32, 6}],
  ?assertEqual({[{a, 0, 45}], [b,c]}, glue_map(Map)).

glue_map4_test() ->
  Map = [{a, 0, 31}, {b, 20, 10}, {c, 35, 100}],
  ?assertEqual({[{a, 0, 31}, {c, 35, 100}], [b]}, glue_map(Map)).










 
  

