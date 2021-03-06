%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_nfq).
-author("sdhillon").

-dialyzer([{nowarn_function, [init/1,
                              terminate/2,
                              build_send_cfg_msg/4,
                              nfnl_query/2,
                              nfq_unbind_pf/2,
                              nfq_bind_pf/2,
                              nfq_create_queue/2,
                              nfq_set_mode/4,
                              process_nfq_msgs/2,
                              process_nfq_msg/2,
                              process_nfq_packet/2,
                              accept_packet/2
                              ]}
          ]).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).





-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-include("minuteman.hrl").
-define(NFQNL_COPY_PACKET, 2).

-define(SERVER, ?MODULE).

-record(state, {socket = erlang:error() :: gen_socket:socket(), queue = erlang:error() :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(Queue :: non_neg_integer()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Queue) ->
  gen_server:start_link({local, ?SERVER_NAME_WITH_NUM(Queue)}, ?MODULE, [Queue], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([Queue]) ->
  process_flag(min_heap_size, 2000000),
  process_flag(priority, high),
  {ok, Socket} = socket(netlink, raw, ?NETLINK_NETFILTER, []),
  %% Our fates are linked.
  {gen_socket, RealPort, _, _, _, _} = Socket,
  erlang:link(RealPort),
  ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  ok = nfq_unbind_pf(Socket, inet),
  ok = nfq_bind_pf(Socket, inet),
  ok = nfq_create_queue(Socket, Queue),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_RCVBUF, 57108864),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_SNDBUF, 57108864),
  ok = nfq_set_mode(Socket, Queue, ?NFQNL_COPY_PACKET, 65535),
  ok = gen_socket:input_event(Socket, true),
  {ok, #state{socket = Socket, queue = Queue}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({accept_packet, Info}, State) ->
  accept_packet(Info, State),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).

handle_info({Socket, input_ready}, State = #state{socket = Socket}) ->
  case gen_socket:recv(Socket, 8192) of
    {ok, Data} ->
      Msg = netlink:nl_ct_dec(Data),
      process_nfq_msgs(Msg, State);
    Other ->
      lager:debug("Other: ~p~n", [Other])
  end,
  ok = gen_socket:input_event(Socket, true),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
  State :: #state{}) -> term()).
terminate(_Reason, _State = #state{socket = Socket}) ->
  lager:debug("Unbinding socket due to termination"),
  nfq_unbind_pf(Socket, inet),
  gen_socket:close(Socket),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
  Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================



build_send_cfg_msg(Socket, Command, Queue, Pf) ->
  Cmd = {cmd, Command, Pf},
  Msg = {queue, config, [ack, request], 0, 0, {unspec, 0, Queue, [Cmd]}},
  nfnl_query(Socket, Msg).


nfnl_query(Socket, Query) ->
  Request = netlink:nl_ct_enc(Query),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request),
  Answer = gen_socket:recv(Socket, 8192),
  ?MM_LOG("Answer: ~p~n", [Answer]),
  case Answer of
    {ok, Reply} ->
      ?MM_LOG("Reply: ~p~n", [netlink:nl_ct_dec(Reply)]),
      case netlink:nl_ct_dec(Reply) of
        [{netlink, error, [], _, _, {ErrNo, _}}|_] when ErrNo == 0 ->
          ok;
        [{netlink, error, [], _, _, {ErrNo, _}}|_] ->
          {error, ErrNo};
        [Msg|_] ->
          {error, Msg};
        Other ->
          Other
      end;
    Other ->
      Other
  end.


socket(Family, Type, Protocol, Opts) ->
  case proplists:get_value(netns, Opts) of
    undefined ->
      gen_socket:socket(Family, Type, Protocol);
    NetNs ->
      gen_socket:socketat(NetNs, Family, Type, Protocol)
  end.

nfq_unbind_pf(Socket, Pf) ->
  build_send_cfg_msg(Socket, pf_unbind, 0, Pf).

nfq_bind_pf(Socket, Pf) ->
  build_send_cfg_msg(Socket, pf_bind, 0, Pf).

nfq_create_queue(Socket, Queue) ->
  build_send_cfg_msg(Socket, bind, Queue, unspec).

nfq_set_mode(Socket, Queue, CopyMode, CopyLen) ->
  Cmd = {params, CopyLen, CopyMode},
  Msg = {queue, config, [ack, request], 0, 0, {unspec, 0, Queue, [Cmd]}},
  nfnl_query(Socket, Msg).


process_nfq_msgs([], _State) ->
  ok;
process_nfq_msgs([Msg|Rest], State) ->
  ?MM_LOG("NFQ-Msg: ~p~n", [Msg]),
  process_nfq_msg(Msg, State),
  process_nfq_msgs(Rest, State).


process_nfq_msg({queue, packet, _Flags, _Seq, _Pid, Packet}, State) ->
  process_nfq_packet(Packet, State).

process_nfq_packet({Family, _Version, _Queue, Info}, _State = #state{queue = Id})
  when Family == inet; Family == inet6 ->
  minuteman_metrics:update([nfq_packets_dispatched, Id], 1, spiral),
  minuteman_packet_handler:handle(self(), Info);

process_nfq_packet({_Family, _Version, _Queue, Info},
  #state{socket = Socket, queue = Queue}) ->
  {_, Id, _, _} = lists:keyfind(packet_hdr, 1, Info),
  NLA = [{verdict_hdr, ?NF_ACCEPT, Id}],
  lager:warning("NLA: ~p", [NLA]),
  Msg = {queue, verdict, [request], 0, 0, {unspec, 0, Queue, NLA}},
  Request = netlink:nl_ct_enc(Msg),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request).


accept_packet(Info, _State = #state{queue = Queue, socket = Socket}) ->
  minuteman_metrics:update([nfq_packets_accepted, Queue], 1, spiral),
  {_, Id, _, _} = lists:keyfind(packet_hdr, 1, Info),
  NLA = [{verdict_hdr, ?NF_ACCEPT, Id}],
  Msg = {queue, verdict, [request], 0, 0, {unspec, 0, Queue, NLA}},
  Request = netlink:nl_ct_enc(Msg),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request).


