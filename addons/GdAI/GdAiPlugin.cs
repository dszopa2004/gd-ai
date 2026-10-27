#if TOOLS
using Godot;

[Tool]
public partial class GdAiPlugin : EditorPlugin
{
	private EditorDock _dock;

	public override void _EnterTree()
	{
		// Instantiate scene
		var scene = GD.Load<PackedScene>("res://addons/GdAI/GdAiDock/GdAiDock.tscn")
			.Instantiate<Control>();

		// Add scene as editor dock
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
		RemoveDock(_dock); // Remove GD AI dock on exit tree
		_dock.QueueFree();
		_dock = null;
	}
}
#endif
