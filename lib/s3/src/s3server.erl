%%%-------------------------------------------------------------------
%%% File    : s3.erl
%%% Author  : Andrew Birkett <andy@nobugs.org>
%%% Description : 
%%%
%%% Created : 14 Nov 2007 by Andrew Birkett <andy@nobugs.org>
%%%-------------------------------------------------------------------
-module(s3server).

-behaviour(gen_server).
-define(TIMEOUT, 40000).
%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	start_link/1,
	stop/0
	]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include_lib("xmerl/include/xmerl.hrl").
-include("../include/s3.hrl").

-record(state, {ssl,access_key, secret_key, pending, timeout=?TIMEOUT}).
-record(request, {pid, callback, started, code, headers=[], content=[]}).
%%====================================================================
%% External functions
%%====================================================================
%%--------------------------------------------------------------------
%% @doc Starts the server.
%% @spec start_link() -> {ok, pid()} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link([Access, Secret, SSL, Timeout]) ->
    gen_server:start_link(?MODULE, [Access, Secret, SSL, Timeout], []).

%%--------------------------------------------------------------------
%% @doc Stops the server.
%% @spec stop() -> ok
%% @end
%%--------------------------------------------------------------------
stop() ->
    gen_server:cast(?MODULE, stop).

init([Access, Secret, SSL, nil]) ->
    {ok, #state{ssl = SSL,access_key=Access, secret_key=Secret, pending=gb_trees:empty()}};
init([Access, Secret, SSL, Timeout]) ->
    {ok, #state{ssl = SSL,access_key=Access, secret_key=Secret, timeout=Timeout, pending=gb_trees:empty()}}.



%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

% Bucket operations
handle_call({listbuckets}, From, State) ->
    genericRequest(From, State, get, "", "", [],[], <<>>, "", fun xmlToBuckets/2 );

handle_call({ put, Bucket }, From, State) ->
    genericRequest(From, State, put, Bucket, "", [], [], <<>>, "", fun(_,_) -> ok end);

handle_call({delete, Bucket }, From, State) ->
    genericRequest(From, State, delete, Bucket, "", [], [],<<>>, "", fun(_,_) -> ok end);

% Object operations
handle_call({put, Bucket, Key, Content, ContentType, AdditionalHeaders}, From, State) ->
    genericRequest(From, State, put, Bucket, Key, [], AdditionalHeaders, Content, ContentType, fun(_X, Headers) -> 
            {value,{"ETag",ETag}} = lists:keysearch( "ETag", 1, Headers ),
            ETag
        end);
    

handle_call({ list, Bucket, Options }, From, State) ->
    Headers = lists:map( fun option_to_param/1, Options ),
    genericRequest(From, State, get, Bucket, "", Headers, [], <<>>, "",  fun parseBucketListXml/2 );

handle_call({ get, Bucket, Key, Etag}, From, State) ->
    genericRequest(From, State, get,  Bucket, Key, [], [{"If-None-Match", Etag}], <<>>, "", fun(B, H) -> {B,H} end);
handle_call({ get, Bucket, Key}, From, State) ->
    genericRequest(From, State, get,  Bucket, Key, [], [], <<>>, "", fun(B, H) -> {B,H} end);

handle_call({ head, Bucket, Key }, From, State) ->
    genericRequest(From, State, head,  Bucket, Key, [], [], <<>>, "", fun(_, H) -> H end);

handle_call({delete, Bucket, Key }, From, State) ->
    genericRequest(From, State, delete, Bucket, Key, [], [], <<>>, "", fun(_,_) -> ok end);

handle_call({link_to, Bucket, Key, Expires}, _From, #state{access_key=Access, secret_key=Secret, ssl=SSL}=State)->
    Exp = integer_to_list(s3util:unix_time(Expires)),
    QueryParams = [{"AWSAccessKeyId", Access},{"Expires", Exp}],
    Url = buildUrl(Bucket,Key,QueryParams, SSL),
    Signature = s3util:url_encode(
                sign( Secret,
		        stringToSign( "GET", "", 
				    Exp, Bucket, Key, "" ))),
    {reply, Url++"&Signature="++Signature, State};
    
handle_call({policy, {obj, Attrs}=Policy}, _From, #state{access_key=Access, secret_key=Secret}=State)->
  Conditions = proplists:get_value("conditions", Attrs, []),
  Attributes = 
    lists:foldl(fun([<<"content-length-range">>, Min,Max], Acc) when is_integer(Min) andalso is_integer(Max) ->
                        Acc; %% ignore not used for building the form 
                  ([_, DolName, V], Acc) ->
                    [$$|Name] = binary_to_list(DolName),
                    [{Name, V}|Acc];
                   ({obj,[{Name, V}]}, Acc) ->
                     [{Name, V}| Acc]
      end, [], Conditions),
  Enc =base64:encode(
        rfc4627:encode(Policy)),
  Signature = base64:encode(crypto:sha_mac(Secret, Enc)),
  {reply, [{"AWSAccessKeyId",list_to_binary(Access)},
           {"Policy", Enc}, 
           {"Signature", Signature}
          |Attributes] ++
          [{"file", <<"">>}], 
          State}.
  
%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({ibrowse_async_headers,RequestId,Code,Headers },State = #state{pending=P}) ->
    %%?DEBUG("******* Response :  ~p~n", [Response]),
	case gb_trees:lookup(RequestId,P) of
		{value,#request{}=R} -> 
			{noreply,State#state{pending=gb_trees:enter(RequestId,R#request{code = Code, headers=Headers},P)}};
		none -> 
		    {noreply,State}
			%% the requestid isn't here, probably the request was deleted after a timeout
	end;
handle_info({ibrowse_async_response,_RequestId,{chunk_start, _N} },State) ->
    {noreply, State};
handle_info({ibrowse_async_response,_RequestId,chunk_end },State) ->
    {noreply, State};	
    
handle_info({ibrowse_async_response,RequestId,Body },State = #state{pending=P}) when is_list(Body)->
    %?DEBUG("******* Response :  ~p~n", [Response]),
	case gb_trees:lookup(RequestId,P) of
		{value,#request{content=Content}=R} -> 
			{noreply,State#state{pending=gb_trees:enter(RequestId,R#request{content=Content ++ Body}, P)}};
		none -> {noreply,State}
			%% the requestid isn't here, probably the request was deleted after a timeout
	end;
handle_info({ibrowse_async_response_end,RequestId}, State = #state{pending=P})->
    case gb_trees:lookup(RequestId,P) of
		{value,#request{started=_Started}=R} -> 
		    handle_http_response(R),
		    %io:format("Query took ~p ms~n", [timer:now_diff(now(), Started)/1000]),
		    io:format("Finished : pending size : ~p~n", [gb_trees:size(P)-1]),
			{noreply,State#state{pending=gb_trees:delete(RequestId, P)}};
		none -> {noreply,State}
			%% the requestid isn't here, probably the request was deleted after a timeout
	end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
option_to_param( { prefix, X } ) -> 
    { "prefix", X };
option_to_param( { maxkeys, X } ) -> 
    { "max-keys", integer_to_list(X) };
option_to_param( { delimiter, X } ) -> 
    { "delimiter", X }.

handle_http_response(#request{pid=From, code="304"})->
    gen_server:reply(From, {ok, not_modified});
handle_http_response(#request{pid=From, code="404"})-> 
    gen_server:reply(From, {error, not_found, "Not found"});
handle_http_response(#request{pid=From, callback=CallBack, code=Code, headers=Headers, content=Content})
                    when Code =:= "200" orelse Code =:= "204"->
    gen_server:reply(From,{ok, CallBack(Content, Headers)});
handle_http_response(#request{pid=From, content=Content})->
    {Xml, _Rest} = xmerl_scan:string(Content),
    [#xmlText{value=ErrorCode}]    = xmerl_xpath:string("//Error/Code/text()", Xml),
    [#xmlText{value=ErrorMessage}] = xmerl_xpath:string("//Error/Message/text()", Xml),
    gen_server:reply(From,{error, ErrorCode, ErrorMessage}).
    
    
isAmzHeader( Header ) -> lists:prefix("x-amz-", Header).

canonicalizedAmzHeaders( AllHeaders ) ->
    AmzHeaders = [ {string:to_lower(K),V} || {K,V} <- AllHeaders, isAmzHeader(K) ],
    Strings = lists:map( 
		fun s3util:join/1, 
		s3util:collapse( 
		  lists:keysort(1, AmzHeaders) ) ),
    s3util:string_join( lists:map( fun (S) -> S ++ "\n" end, Strings), "").
    
canonicalizedResource ( "", "" ) -> "/";
canonicalizedResource ( Bucket, "" ) -> "/" ++ Bucket ++ "/";
canonicalizedResource ( Bucket, Path ) -> "/" ++ Bucket ++ "/" ++ Path.

stringToSign ( Verb, ContentType, Date, Bucket, Path, OriginalHeaders ) ->
    Parts = [ Verb, proplists:get_value("Content-MD5", OriginalHeaders, ""), ContentType, Date, canonicalizedAmzHeaders(OriginalHeaders)],
    s3util:string_join( Parts, "\n") ++ canonicalizedResource(Bucket, Path).
    
sign (Key,Data) ->
    %io:format("Data being signed is ~s~n", [Data]),
    binary_to_list( base64:encode( crypto:sha_mac(Key,Data) ) ).

queryParams( [] ) -> "";
queryParams( L ) -> 
    Stringify = fun ({K,V}) -> K ++ "=" ++ V end,
    "?" ++ s3util:string_join( lists:sort(lists:map( Stringify, L )), "&" ).
    
buildUrl(Bucket,Path,QueryParams, false) -> 
    "http://s3.amazonaws.com" ++ canonicalizedResource(Bucket,Path) ++ queryParams(QueryParams);

buildUrl(Bucket,Path,QueryParams, true) -> 
    "https://s3.amazonaws.com"++ canonicalizedResource(Bucket,Path) ++ queryParams(QueryParams).

buildContentHeaders( <<>>, _ContentType, AdditionalHeaders ) -> AdditionalHeaders;
buildContentHeaders( Contents, ContentType, AdditionalHeaders ) -> 
    ContentMD5 = crypto:md5(Contents),
    [{"Content-MD5", binary_to_list(base64:encode(ContentMD5))},
     {"Content-Type", ContentType},
     | AdditionalHeaders].
buildOptions(<<>>, _ContentType, SSL)->
    [{stream_to, self()}, {is_ssl, SSL}, {ssl_options, []}];
buildOptions(Content, ContentType,SSL)->
    [{content_length, content_length(Content)},
    {content_type, ContentType},
    {is_ssl, SSL},{ssl_options, []},
    {stream_to, self()}].
    
content_length(Content) when is_binary(Content)->
    integer_to_list(size(Content));
content_length(Content) when is_list(Content)->
    integer_to_list(length(Content)).
    
genericRequest(From, #state{ssl=SSL, access_key=AKI, secret_key=SAK, timeout=Timeout, pending=P }=State, 
                Method, Bucket, Path, QueryParams, AdditionalHeaders,Contents, ContentType, Callback ) ->
    Stack = gb_trees:size(P),
    if Stack  > 100 ->
        {reply, retry, State};
    true ->
        Date = httpd_util:rfc1123_date(),
        MethodString = string:to_upper( atom_to_list(Method) ),
        Url = buildUrl(Bucket,Path,QueryParams, SSL),
        OriginalHeaders = buildContentHeaders( Contents, ContentType, AdditionalHeaders ),
        Signature = sign( SAK,
	    	      stringToSign( MethodString,  ContentType, 
	    			    Date, Bucket, Path, OriginalHeaders )),
        
        Headers = [ {"Authorization","AWS " ++ AKI ++ ":" ++ Signature },
	    	        {"Host", "s3.amazonaws.com" },
	    	        {"Date", Date } 
	                | OriginalHeaders ],
        Options = buildOptions(Contents, ContentType, SSL), 
        %io:format("Sending request ~p~n", [Url]),
        
        case ibrowse:send_req(Url, Headers,  Method, Contents,Options, Timeout) of
            {ibrowse_req_id,RequestId} ->
                Pendings = gb_trees:insert(RequestId,#request{pid=From,started=now(), callback=Callback},P),
                io:format("New query pending size : ~p~n", [gb_trees:size(P)]),
                {noreply, State#state{pending=Pendings}};
            {error,E} when E =:= retry_later orelse E =:= conn_failed ->
                io:format("Waiting on retry Error : ~p, Pid : ~p~n", [E, self()]),
                {reply, retry, State};
                %s3util:sleep(10),
                %genericRequest(From, State,Method, Bucket, Path, QueryParams, AdditionalHeaders,Contents, ContentType, Callback );
            {error, E} ->
                io:format("Error : ~p, Pid : ~p~n", [E, self()]),
                {reply, {error, E, "Error Occured"}, State}
        end
    end.

    


parseBucketListXml (XmlDoc, _H) ->
    {Xml, _Rest} = xmerl_scan:string(XmlDoc),
    ContentNodes = xmerl_xpath:string("/ListBucketResult/Contents", Xml),

    GetObjectAttribute = fun (Node,Attribute) -> 
		      [Child] = xmerl_xpath:string( Attribute, Node ),
		      {Attribute, s3util:string_value( Child )}
	      end,

    NodeToRecord = fun (Node) ->
			   #object_info{ 
			 key =          GetObjectAttribute(Node,"Key"),
			 lastmodified = GetObjectAttribute(Node,"LastModified"),
			 etag =         GetObjectAttribute(Node,"ETag"),
			 size =         GetObjectAttribute(Node,"Size")}
		   end,
    lists:map( NodeToRecord, ContentNodes ).


xmlToBuckets( Body, _H) ->
    {Xml, _Rest} = xmerl_scan:string(Body),
    TextNodes       = xmerl_xpath:string("//Bucket/Name/text()", Xml),
    lists:map( fun (#xmlText{value=T}) -> T end, TextNodes).

