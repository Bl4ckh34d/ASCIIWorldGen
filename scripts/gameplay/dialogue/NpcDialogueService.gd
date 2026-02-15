extends RefCounted
class_name NpcDialogueService

const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

# Dialogue scaffolding:
# - Builds a deterministic context payload for future LLM providers.
# - Returns local fallback lines for now (no network dependency).

enum Provider {
	LOCAL_RULES,
	LOCAL_7B_PLACEHOLDER,
	GEMINI_FLASH_PLACEHOLDER,
}

var provider: int = Provider.LOCAL_RULES

func set_provider_by_name(name: String) -> void:
	var key: String = String(name).to_lower().strip_edges()
	match key:
		"local_7b", "starling_7b", "mistral_7b":
			provider = Provider.LOCAL_7B_PLACEHOLDER
		"gemini_flash", "gemini_2_5_flash":
			provider = Provider.GEMINI_FLASH_PLACEHOLDER
		_:
			provider = Provider.LOCAL_RULES

func provider_name() -> String:
	match provider:
		Provider.LOCAL_7B_PLACEHOLDER:
			return "local_7b"
		Provider.GEMINI_FLASH_PLACEHOLDER:
			return "gemini_2_5_flash"
		_:
			return "local_rules"

func build_context(npc_profile: Dictionary, player_profile: Dictionary, world_context: Dictionary) -> Dictionary:
	return {
		"provider": provider_name(),
		"npc": npc_profile.duplicate(true),
		"player": player_profile.duplicate(true),
		"world": world_context.duplicate(true),
	}

func render_local_stub(context: Dictionary) -> String:
	var npc: Dictionary = context.get("npc", {})
	var world: Dictionary = context.get("world", {})
	var role: String = String(npc.get("role", "resident"))
	var disposition: float = clamp(float(world.get("disposition_hint", npc.get("disposition", 0.0))), -1.0, 1.0)
	var shortage: String = String(world.get("top_shortage", ""))
	var shortage_value: float = clamp(float(world.get("top_shortage_value", 0.0)), 0.0, 1.0)
	var scarcity_pressure: float = clamp(float(world.get("scarcity_pressure", 0.0)), 0.0, 1.0)
	var states_at_war: bool = VariantCasts.to_bool(world.get("states_at_war", false))
	var local_war_pressure: float = clamp(float(world.get("local_war_pressure", 0.0)), 0.0, 1.0)
	var epoch_variant: String = String(world.get("epoch_variant", "stable")).to_lower()
	if role == "shopkeeper":
		if not shortage.is_empty() and (states_at_war or local_war_pressure >= 0.5):
			return "Caravans are getting raided. %s stock is scarce this week." % shortage
		if not shortage.is_empty() and (shortage_value >= 0.55 or scarcity_pressure >= 0.55):
			return "Supplies are tight on %s. Prices rose again." % shortage
		if epoch_variant == "post_collapse":
			return "We only trade essentials now. Keep your coin close."
		return "Welcome. Trade is rough, but I can still sell basics."
	if disposition <= -0.4:
		if states_at_war:
			return "Your banner is not welcome here while this war drags on."
		return "I don't trust you. Keep your distance."
	if not shortage.is_empty() and scarcity_pressure >= 0.65:
		return "People are tense. %s shortages keep getting worse." % shortage
	if epoch_variant == "post_collapse":
		return "Since the collapse, every road feels unsafe."
	if disposition >= 0.4:
		return "Good to see you again. Need help with anything?"
	if states_at_war:
		return "Borders are tense. Patrols doubled this week."
	return "Times are changing. People talk about borders and shortages."

func request_dialogue(context: Dictionary) -> Dictionary:
	# Provider API scaffold: future LLM backends plug in here.
	# For now we always return a deterministic local line.
	return {
		"ok": true,
		"provider": provider_name(),
		"text": render_local_stub(context),
	}
