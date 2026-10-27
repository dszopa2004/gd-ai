using Godot;
using System;

[Tool]
public partial class MessageBox : PanelContainer
{
	[Export] private RichTextLabel _Label;

	private string _pendingText = "";

	public override void _Ready()
	{
		_Label.Text = _pendingText; // Set richtextlabel text to inputted user text
	}

	// Setter function to set the message text
	public void SetMessageText(string text)
	{
		_pendingText = text; // Set pending text to inputted user text
		if (_Label != null) _Label.Text = text; // If the label is not null, set the text
	}

	// Function to append message text
	public void AppendMessageText(string chunk)
	{
		_pendingText += chunk;
		if (_Label != null) _Label.AppendText(chunk);
	}
}
