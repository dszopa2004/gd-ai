# GdAI

AI assistant for Godot, as an editor plugin. Chat with Meta's models to build scenes, edit nodes, and write scripts — changes apply directly in the editor with full undo support.

<img width="1304" height="421" alt="image" src="https://github.com/user-attachments/assets/6d5f55d7-8c22-4854-8798-b8060a39eeaf" />


## Features

- Chat dock with streaming responses, markdown, and per-turn token usage
- Scene tools: create, delete, rename, and reparent nodes, set properties and anchors
- Script tools: create, read, and edit `.gd` files (reads your live buffer, unsaved changes included)
- Approval cards for deletes and script writes; everything else applies immediately
- `@`-mention any script or scene to attach its contents to a message
- Syntax-highlighted code blocks with per-block copy buttons
- Copy, retry, and delete on messages; retry regenerates the last response
- Chat history with saved sessions
- Sign in with Meta (device flow) or use your own API key
- Settings for model, reasoning effort, endpoint, and loop cap, with unsaved-change indicators

## Requirements

- Godot 4.7
- A Meta Model API key **or** a Meta account (for Sign in with Meta)

## Installation

1. Download or clone this repository.
2. Copy the `addons/GdAI` folder into your project's `addons/` directory.
3. In Godot, open **Project > Project Settings > Plugins**.
4. Check **Enable** next to GdAI. The GdAI dock appears in the editor.

## Authentication

Pick one option. The dock needs a key before it can send messages.

**Option A — Sign in with Meta (recommended)**

1. Open the GdAI dock's **Settings** tab.
2. Press **Sign in**.
3. Open the shown URL in a browser and enter the code.
4. The status label confirms you're signed in. Press the same button to sign out.

<img width="1299" height="412" alt="image" src="https://github.com/user-attachments/assets/028c30be-1d45-480f-a70a-721838691a1f" />

**Option B — Paste an API key**

1. Get a key from the [Meta developer dashboard](https://dev.meta.ai).
2. Open the GdAI dock's **Settings** tab.
3. Paste it into the API key field and press **Save**.

**Option C — Environment variable**

Set `MODEL_API_KEY` before launching Godot, then fully quit and relaunch the editor. This overrides any saved key.

macOS (persists across launches):

```sh
launchctl setenv MODEL_API_KEY "your-key"
```

Windows — Command Prompt (persists for future sessions; relaunch the editor after):

```bat
setx MODEL_API_KEY "your-key"
```

Windows — PowerShell alternative:

```powershell
[System.Environment]::SetEnvironmentVariable('MODEL_API_KEY', 'your-key', 'User')
```

Linux (current terminal session; launch Godot from the same terminal):

```sh
export MODEL_API_KEY="your-key"
```

Linux (persist by adding that line to `~/.bashrc` or `~/.profile`, then open a new terminal).

## Usage

### Chat basics

- Type in the input box and press **Enter** to send (**Shift+Enter** for a new line).
- While a response streams, Send becomes **Cancel**; **Esc** cancels too.
- The AI sees your open scene (tree summary), current selection, and open script automatically.
- Every change is an editor action: **Ctrl+Z** undoes anything the AI did.

### Tools and approvals

The AI can act on your project, not just answer. Available tools:

| Tool | What it does |
|---|---|
| `create_node` | Adds a node of any type under a parent |
| `delete_node` | Deletes a node (**asks approval first**) |
| `rename_node` | Renames a node |
| `reparent_node` | Moves a node under a new parent |
| `set_property` | Sets any property (text, color, offsets…) |
| `set_anchors_preset` | Applies an anchor preset (center, full rect…) |
| `attach_script` | Attaches an existing script to a node |
| `create_script` / `read_script` / `edit_script` | Manages `.gd` files (**writes ask approval first**) |

When approval is needed, an **Approve / Reject** card appears under the message — one click, no typing. Long tasks pause at the loop cap with a **Continue** button instead of running forever.

<img width="1300" height="621" alt="image" src="https://github.com/user-attachments/assets/970764fb-490d-4f95-a110-f493f3948427" />

### Attaching files with @

Type `@` in the input to open the file picker, keep typing to filter, and press **Enter** (or click) to attach. You can also type full paths by hand:

```text
Explain what @res://player/controller.gd does.
```

- Up to 3 scripts/scenes per message; contents are sent with that message only.
- Attaching the already-open script is free — it's already in context.
- Emails and plain `@name` text are ignored; only real `res://` paths attach.

<img width="1302" height="502" alt="image" src="https://github.com/user-attachments/assets/16d41c3a-8aef-4235-b83d-a46fb3974dc4" />

### Settings

| Setting | Notes |
|---|---|
| API key | Pasted key; never shown back or saved into scenes |
| Endpoint | Default `https://api.meta.ai/v1/chat/completions` |
| Model | `muse-spark` family picker |
| Reasoning effort | `minimal`, `low`, `medium`, `high`, `xhigh` (default `low`) |
| Max loop turns | Tool turns per message before pausing with Continue |

An amber dot appears next to any edited setting, and leaving the tab with unsaved edits asks whether to save or discard.

### Messages

- **Copy** on AI responses copies the full text; hover your own messages for copy/delete.
- **Retry** (last AI response only) drops that response and regenerates it from your prompt.
- Code blocks show the language, highlight syntax, and have their own copy button.
- Token usage (`N in · M out`) appears under each finished AI turn.

### History

The **History** tab lists past chats. Open one to resume it, or start fresh with **New chat**. Chats are stored outside your project, so they never end up in version control.

## Examples

Target the open scene by name and prefer one operation per message while learning the ropes.

**Create a titled label**

```text
Within the MainMenu scene:
- create a Label named Title with the text "Main Menu"
```

**Center it (two steps work best)**

```text
Apply full_rect to node "." (the scene root).
```

```text
Center the Title node within the scene.
```

**Wire a button with a script**

```text
In the MainMenu scene:
- create res://scripts/main_menu.gd and attach it to the scene root
- make StartButton print "Hello, world!" when pressed
```

**Understand existing code**

```text
Explain how @res://player/health.gd handles damage.
```

**Iterate conversationally**

```text
Make the title font size 48.
```

```text
Now add a Quit button under the Start button.
```

## Saving tokens while testing

- Keep reasoning effort on `low` or `minimal` for simple edits.
- Send one operation per message; confirm each step before stacking more.
- Attach only the files the task needs — each is re-sent every loop turn.
- Use vague prompts plus follow-ups rather than re-sending big explicit specs.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Invalid or missing API key (Unauthorized)` | Re-copy the key (no quotes/spaces), or press **Sign in**; fully relaunch the editor after changing `MODEL_API_KEY`. |
| Stuck on `Thinking…` | Check the key first; press **Esc** to cancel and retry. |
| `parent node not found` | Use paths relative to the scene root, or `.` for the root itself. |
| Model can't see your edit | Save the file, or attach it with `@` (scripts read the live buffer when open). |

## License

MIT — see [LICENSE](LICENSE).
