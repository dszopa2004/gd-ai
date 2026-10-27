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
	[Export] private TextEdit _UserInputBox;
	[Export] private Button _SendButton;
	
	public override void _Ready()
	{
		// Connect the 'Pressed' signal to method
		_ChatButton.Pressed += OnChatButtonPressed;
		_HistoryButton.Pressed += OnHistoryButtonPressed;
		
		_UserInputBox.TextChanged += OnUserInputBoxTextChanged;
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
}
