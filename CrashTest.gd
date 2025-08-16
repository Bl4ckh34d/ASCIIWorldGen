extends Control

func _ready():
	print("=== CRASH TEST STARTED ===")
	print("Basic Control node working")
	
	# Create simple UI
	var label = Label.new()
	label.text = "CRASH TEST - IF YOU SEE THIS, BASIC GODOT WORKS"
	label.position = Vector2(50, 50)
	add_child(label)
	
	print("=== CRASH TEST COMPLETE ===")