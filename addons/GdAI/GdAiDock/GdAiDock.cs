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
		// Connect the 'Pressed' signal to method
		_ChatButton.Pressed += OnChatButtonPressed;
		_HistoryButton.Pressed += OnHistoryButtonPressed;
		
		_UserInputBox.TextChanged += OnUserInputBoxTextChanged;
		_SendButton.Pressed += OnSendButtonPressed;
		_UserInputBox.GuiInput += OnInputGuiInput;
		
		var bar = _ChatScroll.GetVScrollBar();
		bar.Changed += () => _ChatScroll.ScrollVertical = (int)bar.MaxValue;
	}
	
	private void OnChatButtonPressed()
	{
		_ChatMenu.Visible = true;
		_HistoryMenu.Visible = false;
	}
	
	private void OnHistoryButtonPressed()
	{
		_HistoryMenu.Visible = true;
		_ChatMenu.Visible = false;
	}
	
	private void OnUserInputBoxTextChanged()
	{
		_SendButton.Visible = true;
		
		if (string.IsNullOrWhiteSpace(_UserInputBox.Text))
		{
			_SendButton.Visible = false;
		}
	}
	
	private void OnInputGuiInput(InputEvent @event)
	{
		if (@event is InputEventKey key && key.Pressed && !key.Echo
			&& (key.Keycode == Key.Enter || key.Keycode == Key.KpEnter))
		{
			// Stop TextEdit from handling this key itself.
			_UserInputBox.AcceptEvent();
			
			if (key.ShiftPressed)
			{
				_UserInputBox.InsertTextAtCaret("\n");
			}
			else
			{
				// Fires the same signal a real click would.
				_SendButton.EmitSignal(BaseButton.SignalName.Pressed);
			}
		}
	}
	
	private void OnSendButtonPressed()
	{
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
	
	private MessageBox AddMessage(string text, bool isUser)
	{
		var message = GD.Load<PackedScene>("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
			.Instantiate<MessageBox>();
		
		message.SetMessageText(text);
		_MessageList.AddChild(message);
		
		return message; // keep this to stream into it
	}
}
