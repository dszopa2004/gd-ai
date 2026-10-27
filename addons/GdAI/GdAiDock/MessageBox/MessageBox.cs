using Godot;
using System;

[Tool]
public partial class MessageBox : PanelContainer
{
	[Export] private RichTextLabel _Label;

	private string _pendingText = "";

	public override void _Ready()
	{
		_Label.Text = _pendingText;
	}

	public void SetMessageText(string text)
	{
		_pendingText = text;
		if (_Label != null) _Label.Text = text;
	}

	public void AppendMessageText(string chunk)
	{
		_pendingText += chunk;
		if (_Label != null) _Label.AppendText(chunk);
	}
}
