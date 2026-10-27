using Godot;
using System;

[Tool]
public partial class GdAiDock : Control
{
	[ExportCategory("Tab Buttons")]
	[Export] private Button _ChatButton;
	[Export] private Button _HistoryButton;
	
	[ExportCategory("Tab Menus")]
	[Export] private Control _ChatMenu;
	[Export] private Control _HistoryMenu;
	
	[ExportCategory("User Input")]
	[Export] private ScrollContainer _ChatScroll;
	[Export] private VBoxContainer _MessageList;
	[Export] private TextEdit _UserInputBox;
	[Export] private Button _SendButton;
	
	public override void _Ready()
	{
		// Tab Button Signals
		_ChatButton.Pressed += OnChatButtonPressed;
		_HistoryButton.Pressed += OnHistoryButtonPressed;

		// User Input Section Signals
		_UserInputBox.TextChanged += OnUserInputBoxTextChanged;
		_SendButton.Pressed += OnSendButtonPressed;
		_UserInputBox.GuiInput += OnInputGuiInput;

		// Set scroll bar to be set at most recent message
		var bar = _ChatScroll.GetVScrollBar();
		bar.Changed += () => _ChatScroll.ScrollVertical = (int)bar.MaxValue;
	}

	// Signal for chat button press
	private void OnChatButtonPressed()
	{
		_ChatMenu.Visible = true;
		_HistoryMenu.Visible = false;
	}

	// Signal for history button press
	private void OnHistoryButtonPressed()
	{
		_HistoryMenu.Visible = true;
		_ChatMenu.Visible = false;
	}

	// Signal for user input in TextEdit 
	private void OnUserInputBoxTextChanged()
	{
		_SendButton.Visible = true;
		
		if (string.IsNullOrWhiteSpace(_UserInputBox.Text))
		{
			_SendButton.Visible = false;
		}
	}

	// Signal to detect keyboard input in TextEdit
	private void OnInputGuiInput(InputEvent @event)
	{
		// Check if Enter was pressed
		if (@event is InputEventKey key && key.Pressed && !key.Echo
			&& (key.Keycode == Key.Enter || key.Keycode == Key.KpEnter))
		{
			// Stop TextEdit from handling this key itself.
			_UserInputBox.AcceptEvent();

			// Add new line if Shift and Enter are pressed at the same time
			if (key.ShiftPressed)
			{
				_UserInputBox.InsertTextAtCaret("\n");
			}
			else
			{
				// Send message by emitting the send button pressed signal 
				_SendButton.EmitSignal(BaseButton.SignalName.Pressed);
			}
		}
	}

	// Signal to handle send button press
	private void OnSendButtonPressed()
	{
		// Trim the text
		string text = _UserInputBox.Text.Trim();
		if (text.Length == 0) return;
		
		// Show the user's message
		AddMessage(text, isUser: true);
		_UserInputBox.Clear();
		_UserInputBox.GrabFocus();
		
		// Create an empty AI message to fill in as the response arrives.
		MessageBox aiMessage = AddMessage("", isUser: false);
		
		// API call goes here, appending to aiMessage as chunks arrive:
		//aiMessage.AppendText(chunk);
		aiMessage.SetMessageText("AI response goes here");
	}

	// Helper function to create a message box
	private MessageBox AddMessage(string text, bool isUser)
	{
		var message = GD.Load<PackedScene>("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
			.Instantiate<MessageBox>(); // Preload and instantiate message box scene

		// Set text and add message to message list
		message.SetMessageText(text);
		_MessageList.AddChild(message);
		
		return message; // keep this to stream into it
	}
}
