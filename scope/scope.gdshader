shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque, shadows_disabled;


const vec3 BLACK = vec3(0.0);

/** Viewport texture from a 2D Scene that will become the reticle */
uniform sampler2D reticle_texture: repeat_disable;
/** Viewport texture from a 3D Camera that will become the scope's view */
uniform sampler2D scope_texture: repeat_disable;
/** Radius for the scope's physical outer radius */
uniform float scope_radius = 0.025;
/** Percentage of the scope_radius that is rendered before the view starts fading to black */
uniform float scope_inner_radius: hint_range(0.0, 1.0, 0.001) = 1.0;
/** Depth before the reticle appears */
uniform float reticle_depth = 2.0;
uniform float parallax_factor: hint_range(0.0, .3, 0.001) = 0.1;
uniform float view_edge_fade_factor: hint_range(0.0, 0.5, 0.001) = .05;


group_uniforms Eyebox;
/**
Position of eyebox. When the eye is this distance away it is considered perfect */
uniform float eyebox_position = .15;
/**
Forgiveness for user eye positioning. Allows a +- tolerance around "eyebox_position" */
uniform float eyebox_tolerance = 0.005;
/** Specify the distance over which the scope shadow will fade to black */
uniform float eyebox_fade_distance = 0.05;


group_uniforms Scope_Shadow;
/**
Percent of the scope that will display before the scope shadow's fade starts.
0.0 is fully dark, 1.0 is fully displayed (except for the scope shadow's fade).*/
uniform float shadow_inner_radius: hint_range(0.0, 1.0, 0.01) = 1.0;
/**
Factor for the eyebox's scope shadow */
uniform float shadow_fade_factor = 0.2;

/**
Changes how sensitive the scope-shadow is to movement */
uniform float shadow_movement_factor: hint_range(0.5, 1.0, 0.01) = 1.0;


varying vec3 view;


// "Pushes" the scope uv into the scope making it appear deeper inside the scope.
// Returns altered UV
vec2 get_depth_effect(vec2 uv, vec3 direcion, float depth) {
	vec2 result = uv - direcion.xy * (depth * 2.0);
	result -= vec2(0.5);
	result *= 0.5;
	return result + 0.5;
}


// Creates the scope shadow effect
// Returns color
vec3 get_scope_shadow_effect(vec2 uv, vec4 scope_sample, vec3 view_dir, float eye_distance) {
	float delta = eye_distance - eyebox_position;

	vec2 eye_offset = view_dir.xy / -shadow_movement_factor;
	//((uv - vec2(0.5)) / 2.0)
	vec2 shifted_uv = uv - eye_offset;
	float dist = length((shifted_uv - vec2(0.5)) * 2.0);

	// Fade logic for close / far
	float fade_near = smoothstep(-eyebox_tolerance, -eyebox_tolerance - eyebox_fade_distance, delta);
	float fade_far  = smoothstep( eyebox_tolerance,  eyebox_tolerance + eyebox_fade_distance, delta);
	float distance_fade = max(fade_near, fade_far);

	// Scale scope shadow radius to distance
	float dynamic_radius = mix(0.0, shadow_inner_radius, 1.0 - distance_fade);
	float inner = dynamic_radius - shadow_fade_factor;
	float outer = dynamic_radius;
	float fade = smoothstep(inner, outer, dist);

	return mix(scope_sample.rgb, BLACK, fade);
}


// Scope viewport edge fade
// Returns color
vec3 get_scope_edge_fade_effect(vec2 adj_uv, vec4 scope_sample) {
	vec2 center_uv = vec2(0.5);
	float dist = length(adj_uv - center_uv);

	// Divide by two, UV max is .5 and scope_inner_radius is 0.0 - 1.0
	float fade_edge_end = scope_inner_radius / 2.0;
	float fade_edge_start = fade_edge_end - view_edge_fade_factor;
	float fade_edge = smoothstep(fade_edge_start, fade_edge_end, dist);
	return mix(scope_sample.rgb, BLACK, fade_edge);
}


float get_in_bounds_factor(vec2 uv) {
	const float lower = 0.01;
	const float upper = 0.99;
	return step(lower, uv.x) * step(uv.x, upper) * step(lower, uv.y) * step(uv.y, upper);
}


void vertex() {
	view = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz - (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}


void fragment() {
	float eye_distance = length(NODE_POSITION_WORLD - CAMERA_POSITION_WORLD);
	vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET) * mat3(TANGENT, -BINORMAL, NORMAL));

	// Inside of scope
	if (length(view) <= scope_radius) {
		vec2 adj_uv = get_depth_effect(UV, view_dir, reticle_depth);

		// This setup seems to cause a parallax-like effect
		// minimize using parallax_factor
		vec2 parallax_uv = mix(adj_uv, UV, parallax_factor);

		vec4 scope_sample = texture(scope_texture, adj_uv);
		scope_sample.rgb = get_scope_shadow_effect(UV, scope_sample, view_dir, eye_distance);
		scope_sample.rgb = get_scope_edge_fade_effect(adj_uv, scope_sample);

		vec4 reticle_sample = texture(reticle_texture, parallax_uv);

		// Mask to in-bounds to discard reticle sample "stretching to infinity" at edge of UV
		reticle_sample.a *= get_in_bounds_factor(adj_uv);

		ALPHA = 1.0;
		ALBEDO = mix(scope_sample.rgb, reticle_sample.rgb, reticle_sample.a);

	// Outside radius: Discard to make a perfect circle
	} else {
		discard;
	}
}