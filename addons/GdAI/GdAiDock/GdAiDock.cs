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
	
	public override void _Ready()
	{
		// Connect the 'Pressed' signal to your method using +=
		_ChatButton.Pressed += OnChatButtonPressed;
		_HistoryButton.Pressed += OnHistoryButtonPressed;
	}
	
	private void OnChatButtonPressed()
	{
		GD.Print("Viewing Chat");
	}
	
	private void OnHistoryButtonPressed()
	{
		GD.Print("Viewing History");
	}
}
