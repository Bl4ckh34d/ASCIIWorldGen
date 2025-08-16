extends Control

func _ready():
	# debug removed
	# debug removed
	
	# Create simple UI
	var label = Label.new()
	label.text = "CRASH TEST - IF YOU SEE THIS, BASIC GODOT WORKS"
	label.position = Vector2(50, 50)
	add_child(label)
	
	# debug removed