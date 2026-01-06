//// Claude Code provider for starlet.
////
//// Uses Claude Code CLI in non-interactive mode (`-p`) to interact with Claude
//// through a Max subscription. This provider spawns the `claude` CLI as a
//// subprocess rather than making direct API calls.
////
//// ## Prerequisites
////
//// - Claude Code CLI must be installed and in PATH
//// - Authenticated with a Claude Max subscription (no ANTHROPIC_API_KEY set)
////
//// ## Usage
////
//// ```gleam
//// import starlet
//// import starlet/claude_code
////
//// let client = claude_code.new()
////
//// starlet.chat(client, "claude-sonnet-4-20250514")
//// |> starlet.user("Hello!")
//// |> starlet.send()
//// ```
////
//// ## Multi-turn Conversations
////
//// For multi-turn conversations, use `--continue` or `--resume`:
////
//// ```gleam
//// let client = claude_code.new()
//// |> claude_code.continue_session(session_id)
////
//// starlet.chat(client, "claude-sonnet-4-20250514")
//// |> starlet.user("Follow-up question...")
//// |> starlet.send()
//// ```
////
//// ## Limitations
////
//// - No streaming support (waits for full response)
//// - Tool calling is handled internally by Claude Code, not exposed
//// - Large stdin inputs (7000+ chars) may cause issues
//// - Requires Claude Code CLI to be installed locally

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import starlet.{
  type Chat, type Client, type ContentPart, type Message, type Request,
  type Response, type StarletError, AssistantMessage, Chat, ProviderConfig,
  Response, TextPart, ToolResultMessage, UserMessage,
}

/// Claude Code provider extension type.
@internal
pub type Ext {
  Ext(
    /// Session ID for multi-turn conversations.
    session_id: Option(String),
    /// Continue from the last session automatically.
    continue_last: Bool,
    /// Custom system prompt to append.
    append_system: Option(String),
    /// Working directory for Claude Code.
    working_dir: Option(String),
  )
}

/// Creates a new Claude Code client.
///
/// Uses the `claude` CLI in PATH. Requires authentication via Claude Max.
pub fn new() -> Client(Ext) {
  let config =
    ProviderConfig(
      name: "claude-code",
      base_url: "",
      send: fn(req, ext) { send_request(req, ext) },
    )
  let default_ext =
    Ext(
      session_id: None,
      continue_last: False,
      append_system: None,
      working_dir: None,
    )
  starlet.from_provider(config, default_ext)
}

/// Continue a conversation from a previous session ID.
pub fn continue_session(
  chat: Chat(t, f, s, Ext),
  session_id: String,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, session_id: Some(session_id)))
}

/// Continue from the last session automatically.
pub fn continue_last(chat: Chat(t, f, s, Ext)) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, continue_last: True))
}

/// Append to the system prompt (in addition to any system prompt set via starlet.system()).
pub fn append_system_prompt(
  chat: Chat(t, f, s, Ext),
  prompt: String,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, append_system: Some(prompt)))
}

/// Set the working directory for Claude Code.
pub fn working_directory(
  chat: Chat(t, f, s, Ext),
  dir: String,
) -> Chat(t, f, s, Ext) {
  Chat(..chat, ext: Ext(..chat.ext, working_dir: Some(dir)))
}

/// Reset session state for a fresh conversation.
pub fn reset_session(chat: Chat(t, f, s, Ext)) -> Chat(t, f, s, Ext) {
  Chat(
    ..chat,
    ext: Ext(..chat.ext, session_id: None, continue_last: False),
  )
}

fn send_request(
  req: Request,
  ext: Ext,
) -> Result(#(Response, Ext), StarletError) {
  // Build the prompt from the last user message
  let prompt = build_prompt(req.messages)

  // Build command arguments
  let args = build_args(req, ext, prompt)

  // Execute claude CLI
  case execute_claude(args, req.timeout_ms) {
    Ok(output) -> {
      case decode_response(output) {
        Ok(#(response, session_id)) -> {
          let new_ext = Ext(..ext, session_id: session_id)
          Ok(#(response, new_ext))
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

/// Extracts the prompt text from the most recent user message.
fn build_prompt(messages: List(Message)) -> String {
  // Get the last user message
  let user_messages =
    list.filter(messages, fn(msg) {
      case msg {
        UserMessage(_) -> True
        _ -> False
      }
    })

  case list.last(user_messages) {
    Ok(UserMessage(content)) -> content_to_text(content)
    _ -> ""
  }
}

/// Converts content parts to plain text.
fn content_to_text(parts: List(ContentPart)) -> String {
  list.filter_map(parts, fn(part) {
    case part {
      TextPart(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

/// Builds command line arguments for the claude CLI.
fn build_args(req: Request, ext: Ext, prompt: String) -> List(String) {
  let args = ["-p", prompt, "--output-format", "json"]

  // Add model if specified (not default)
  let args = case req.model {
    "" -> args
    model -> list.append(args, ["--model", model])
  }

  // Add system prompt
  let args = case req.system_prompt {
    Some(system) -> list.append(args, ["--system-prompt", system])
    None -> args
  }

  // Add append system prompt from ext
  let args = case ext.append_system {
    Some(append) -> list.append(args, ["--append-system-prompt", append])
    None -> args
  }

  // Add session continuation
  let args = case ext.session_id {
    Some(id) -> list.append(args, ["--resume", id])
    None ->
      case ext.continue_last {
        True -> list.append(args, ["--continue"])
        False -> args
      }
  }

  // Add working directory
  let args = case ext.working_dir {
    Some(dir) -> list.append(args, ["--cwd", dir])
    None -> args
  }

  // Add max tokens
  let args = case req.max_tokens {
    Some(n) -> list.append(args, ["--max-turns", int_to_string(n)])
    None -> args
  }

  args
}

/// Simple int to string conversion.
fn int_to_string(n: Int) -> String {
  case n < 0 {
    True -> "-" <> int_to_string(-n)
    False ->
      case n {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        9 -> "9"
        _ -> {
          let quot = n / 10
          let rem = n % 10
          int_to_string(quot) <> int_to_string(rem)
        }
      }
  }
}

/// Execute the claude CLI and return stdout.
/// This is a placeholder - actual implementation depends on Gleam's process API.
@external(erlang, "starlet_claude_code_ffi", "execute_command")
fn execute_claude(
  args: List(String),
  timeout_ms: Int,
) -> Result(String, StarletError)

/// Decodes the JSON response from Claude Code.
/// Returns the response text and optional session ID.
@internal
pub fn decode_response(
  body: String,
) -> Result(#(Response, Option(String)), StarletError) {
  // Claude Code JSON output format:
  // {
  //   "type": "result",
  //   "result": { "content": [{"type": "text", "text": "..."}] },
  //   "session_id": "..."
  // }

  let content_decoder = {
    use type_ <- decode.field("type", decode.string)
    case type_ {
      "text" -> {
        use text <- decode.field("text", decode.string)
        decode.success(text)
      }
      _ -> decode.success("")
    }
  }

  let decoder = {
    use session_id <- decode.optional_field("session_id", None, {
      use id <- decode.then(decode.string)
      decode.success(Some(id))
    })
    use result <- decode.optional_field("result", None, {
      use content <- decode.field("content", decode.list(content_decoder))
      decode.success(Some(string.join(content, "")))
    })
    let text = option.unwrap(result, "")
    decode.success(#(text, session_id))
  }

  case json.parse(body, decoder) {
    Ok(#(text, session_id)) ->
      Ok(#(Response(text: text, tool_calls: []), session_id))
    Error(err) ->
      Error(starlet.Decode(
        "Failed to decode Claude Code response: " <> string.inspect(err),
      ))
  }
}
