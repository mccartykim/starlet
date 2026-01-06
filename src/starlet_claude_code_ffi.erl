-module(starlet_claude_code_ffi).
-export([execute_command/2]).

%% Execute the claude CLI with given arguments and timeout.
%% Returns {ok, Output} on success, or {error, {transport, Message}} on failure.
execute_command(Args, TimeoutMs) ->
    %% Build the command
    Command = build_command(Args),

    %% Execute with timeout
    try
        Port = open_port({spawn, Command}, [
            stream,
            exit_status,
            binary,
            stderr_to_stdout,
            {line, 1024 * 1024}  % 1MB line buffer
        ]),
        collect_output(Port, <<>>, TimeoutMs)
    catch
        error:Reason ->
            {error, {transport, iolist_to_binary(io_lib:format("Failed to spawn claude: ~p", [Reason]))}}
    end.

%% Build the shell command from arguments.
build_command(Args) ->
    %% Escape each argument for shell
    EscapedArgs = lists:map(fun escape_arg/1, Args),
    %% Join with spaces
    "claude " ++ string:join(EscapedArgs, " ").

%% Escape a single argument for shell use.
escape_arg(Arg) when is_binary(Arg) ->
    escape_arg(binary_to_list(Arg));
escape_arg(Arg) when is_list(Arg) ->
    %% Single-quote the argument, escaping any single quotes within
    "'" ++ escape_single_quotes(Arg) ++ "'".

%% Escape single quotes within a string for shell.
escape_single_quotes([]) -> [];
escape_single_quotes([$' | Rest]) -> "'\\''" ++ escape_single_quotes(Rest);
escape_single_quotes([C | Rest]) -> [C | escape_single_quotes(Rest)].

%% Collect output from the port until exit or timeout.
collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} ->
            collect_output(Port, <<Acc/binary, Line/binary, "\n">>, TimeoutMs);
        {Port, {data, {noeol, Line}}} ->
            collect_output(Port, <<Acc/binary, Line/binary>>, TimeoutMs);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {transport, iolist_to_binary(io_lib:format("claude exited with status ~p: ~s", [Status, Acc]))}};
        {'EXIT', Port, Reason} ->
            {error, {transport, iolist_to_binary(io_lib:format("Port closed: ~p", [Reason]))}}
    after TimeoutMs ->
        port_close(Port),
        {error, {transport, <<"claude command timed out">>}}
    end.
