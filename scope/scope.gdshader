shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque, shadows_disabled;

const vec3 BLACK = vec3(0.0);
const float NOT_ZERO = 1e-5;


/** Viewport texture from a 2D Scene that will become the reticle */
uniform sampler2D reticle_texture: repeat_disable;
/** Viewport texture from a 3D Camera that will become the scope's view */
uniform sampler2D scope_texture: repeat_disable;
/** Radius for the scope's physical outer radius */
uniform float scope_radius = 0.025;
/** Percentage of the scope_radius that is rendered before the view starts fading to black */
uniform float scope_inner_radius: hint_range(0.0, 1.0, 0.001) = 1.0;
/** Depth before the reticle appears */
uniform float scope_depth = 2.0;
/** Size of the scope view's fade-to-black */
uniform float scope_fade_size: hint_range(0.0, 0.5, 0.001) = .05;
/** Strength of the parallax between the scope's view and reticle */
uniform float scope_parallax_factor: hint_range(0.0, .3, 0.001) = 0.1;


group_uniforms Lens_Distortion;
uniform float lens_bevel_start: hint_range(0.0, 1.0, 0.01) = 0.78;
uniform float lens_curvature: hint_range(0.0, .25, 0.001) = 0.03;


group_uniforms Eyebox;
/** Position of eyebox. When the eye is this distance away it is considered perfect */
uniform float eyebox_position = .15;
/** Forgiveness for user eye positioning. Allows a +- tolerance around "eyebox_position" */
uniform float eyebox_tolerance = 0.005;
/** Specify the distance over which the scope shadow will fade to black */
uniform float eyebox_fade_distance = 0.05;


group_uniforms Scope_Shadow;
uniform float shadow_enabled: hint_range(0.0, 1.0, 1.0) = 1.0;
/**
Percent of the scope that will display before the scope shadow's fade starts.
0.0 is fully dark, 1.0 is fully displayed (except for the scope shadow's fade).*/
uniform float shadow_inner_radius: hint_range(0.0, 1.0, 0.01) = 1.0;
/** Factor for the eyebox's scope shadow */
uniform float shadow_fade_factor = 0.2;
/** Changes how sensitive the scope-shadow is to movement */
uniform float shadow_movement_factor: hint_range(0.5, 1.0, 0.01) = 1.0;


varying vec3 view;


// "Pushes" the scope uv into the scope making it appear deeper inside the scope.
// Returns altered UV
vec2 get_depth_uv(vec2 uv, vec3 direcion) {
	vec2 result = uv - direcion.xy * (scope_depth * 2.0);
	result -= vec2(0.5);
	result *= 0.5;
	return result + 0.5;
}


// Apply a distortion effect near the edge of the lens to simulate bevelled glass.
vec2 get_bevel_uv(vec2 uv) {
	const float MAX_RADIUS = 0.5;
	
	// Inner/ outer bevel radius as a proportion of the scope_inner_radius
	float inner_radius = lens_bevel_start * scope_inner_radius * MAX_RADIUS;
	float outer_radius = scope_inner_radius * MAX_RADIUS;

	// Get the vector from the center of the UV space to the current pixel.
	vec2 to_center = uv - vec2(0.5);
	float current_radius = length(to_center);

	// If the pixel is inside the inner radius, apply no distortion.
	if (current_radius <= inner_radius) {
		return uv;
	}

	// Calculate a normalized factor (0.0 to 1.0) for the transition from the inner to outer radius.
	float transition_factor = (current_radius - inner_radius) / max(NOT_ZERO, outer_radius - inner_radius);
	float smooth_t = smoothstep(0.0, 1.0, transition_factor);

	// Create a "bell curve" effect that peaks in the middle of the bevel.
	float bell_curve = smooth_t * (scope_inner_radius - smooth_t) * 4.0;
	vec2 direction = to_center / max(NOT_ZERO, current_radius);

	// Radial distortion pushes pixels away from or towards the center.
	vec2 radial_offset = direction * (-lens_curvature * bell_curve);

	// Apply both offsets to the UV coordinates and clamp to the [0, 1] range to prevent texture wrapping.
	return clamp(uv + radial_offset, vec2(0.0), vec2(1.0));
}


// Creates the scope shadow effect
vec3 get_scope_shadow_color(vec2 uv, vec4 scope_sample, vec3 view_dir, float eye_distance) {
	float delta = eye_distance - eyebox_position;

	vec2 eye_offset = view_dir.xy / -shadow_movement_factor;
	vec2 shifted_uv = uv - eye_offset;
	float dist = length((shifted_uv - vec2(0.5)) * 2.0);

	// Fade logic for close / far
	float fade_near = smoothstep(-eyebox_tolerance, -eyebox_tolerance - eyebox_fade_distance, delta);
	float fade_far = smoothstep( eyebox_tolerance, eyebox_tolerance + eyebox_fade_distance, delta);
	float distance_fade = max(fade_near, fade_far);

	// Scale scope shadow radius to distance
	float dynamic_radius = mix(0.0, shadow_inner_radius, 1.0 - distance_fade);
	float inner = dynamic_radius - shadow_fade_factor;
	float outer = dynamic_radius;
	float fade = smoothstep(inner, outer, dist);

	return mix(scope_sample.rgb, BLACK, fade*shadow_enabled);
}


// Scope viewport edge fade
vec3 get_scope_fade_color(vec2 adj_uv, vec4 scope_sample) {
	vec2 center_uv = vec2(0.5);
	float dist = length(adj_uv - center_uv);

	// Divide by two, UV max is .5 and scope_inner_radius is 0.0 - 1.0
	float fade_edge_end = scope_inner_radius / 2.0;
	float fade_edge_start = fade_edge_end - scope_fade_size;
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
		vec2 depth_uv = get_depth_uv(UV, view_dir);
		vec2 bevel_uv = get_bevel_uv(depth_uv);

		vec4 scope_sample = texture(scope_texture, bevel_uv);
		scope_sample.rgb = get_scope_shadow_color(UV, scope_sample, view_dir, eye_distance);
		scope_sample.rgb = get_scope_fade_color(depth_uv, scope_sample);

		// This setup seems to cause a parallax-like effect
		// minimize using scope_scope_parallax_factor
		vec2 parallax_uv = mix(depth_uv, UV, scope_parallax_factor);
		vec4 reticle_sample = texture(reticle_texture, parallax_uv);

		// Mask to in-bounds to discard reticle sample "stretching to infinity" at edge of UV
		reticle_sample.a *= get_in_bounds_factor(depth_uv);

		ALPHA = 1.0;
		ALBEDO = mix(scope_sample.rgb, reticle_sample.rgb, reticle_sample.a);

	// Outside radius: Discard to make a perfect circle
	} else {
		discard;
	}
}
