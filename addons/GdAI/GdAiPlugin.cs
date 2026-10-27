#if TOOLS
using Godot;

[Tool]
public partial class GdAiPlugin : EditorPlugin
{
	private EditorDock _dock;

	public override void _EnterTree()
	{
		var scene = GD.Load<PackedScene>("res://addons/GdAI/GdAiDock/GdAiDock.tscn")
			.Instantiate<Control>();

		_dock = new EditorDock();
		_dock.AddChild(scene);
		_dock.Title = "GD AI";

		// LeftUl = left of the editor, upper-left dock.
		_dock.DefaultSlot = EditorDock.DockSlot.LeftUl;

		// Allow horizontal placement and floating.
		_dock.AvailableLayouts = EditorDock.DockLayout.Horizontal | EditorDock.DockLayout.Floating;

		AddDock(_dock);
	}

	public override void _ExitTree()
	{
		RemoveDock(_dock);
		_dock.QueueFree();
		_dock = null;
	}
}
#endif
