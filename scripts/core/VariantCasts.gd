extends RefCounted
class_name VariantCasts

static func to_bool(value: Variant, default_value: bool = false) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_NIL:
			return default_value
		TYPE_INT:
			return int(value) != 0
		TYPE_FLOAT:
			return absf(float(value)) > 0.000001
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(value).strip_edges().to_lower()
			if s == "true" or s == "1" or s == "yes" or s == "on":
				return true
			if s == "false" or s == "0" or s == "no" or s == "off" or s == "":
				return false
			return default_value
		_:
			return default_value
