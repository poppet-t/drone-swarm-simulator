shader_type spatial;

// Emissive marker shader for per-drone identification and selection rings.
// The colour is a per-INSTANCE uniform, so every drone shares this one
// material — no per-drone material or texture duplication.

instance uniform vec4 marker_color : source_color = vec4(1.0, 0.8, 0.1, 1.0);

void fragment() {
	ALBEDO = marker_color.rgb;
	EMISSION = marker_color.rgb;
	ROUGHNESS = 0.6;
}
