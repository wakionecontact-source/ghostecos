#version 320 es

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;

// These values mirror site/liquid.js:
//   feDisplacementMap scale="75"
//   d = max(8, batch(min(w, h) * 0.1))
// The first two uniforms are reserved by ImageFilter.shader (size + sampler).
uniform float u_radius_px;
uniform float u_displacement_scale;
uniform float u_depth_fraction;
uniform float u_min_depth_px;
uniform float u_geometry_batch_px;

out vec4 frag_color;

float batch_value(float value, float quantum) {
  return floor(value / quantum + 0.5) * quantum;
}

// Signed distance to a rounded rectangle centred at the origin.
// This replaces the SVG rounded rects in lensMap() while retaining their
// important property: the straight side field spans the complete side, and
// only the corner transition is curved.
float rounded_rect_sdf(vec2 point, vec2 half_size, float radius) {
  vec2 q = abs(point) - (half_size - vec2(radius));
  return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

vec2 rounded_rect_normal(vec2 point, vec2 half_size, float radius) {
  vec2 q = abs(point) - (half_size - vec2(radius));
  vec2 point_sign = vec2(
    point.x < 0.0 ? -1.0 : 1.0,
    point.y < 0.0 ? -1.0 : 1.0
  );

  if (q.x > 0.0 && q.y > 0.0) {
    return normalize(q) * point_sign;
  }
  if (q.x > q.y) {
    return vec2(point_sign.x, 0.0);
  }
  return vec2(0.0, point_sign.y);
}

void main() {
  // Keep the same coordinate convention as Flutter's own stretch shader:
  // flip only the final sample on GLES, never the geometry calculation.
  vec2 uv = FlutterFragCoord().xy / u_size;
  vec2 half_size = u_size * 0.5;

  float radius = batch_value(max(u_radius_px, 0.0), u_geometry_batch_px);
  radius = min(radius, min(half_size.x, half_size.y));

  float depth = max(
    u_min_depth_px,
    batch_value(min(u_size.x, u_size.y) * u_depth_fraction, u_geometry_batch_px)
  );

  vec2 point = FlutterFragCoord().xy - half_size;
  float signed_distance = rounded_rect_sdf(point, half_size, radius);

  // The SVG map is neutral in the inner rounded rectangles and reaches its
  // full channel value at the outer boundary. A smooth band is the analytic
  // equivalent of those blurred neutral rectangles.
  float inside_distance = max(-signed_distance, 0.0);
  float edge_band = 1.0 - smoothstep(0.0, depth, inside_distance);
  vec2 normal = rounded_rect_normal(point, half_size, radius);

  // lensMap() uses a red X-gradient and a green Y-gradient. Both ends of
  // each gradient are bright, so channel displacement is positive on either
  // side, just as in the SVG feDisplacementMap source.
  float x_channel = 0.5 + 0.5 * edge_band * abs(normal.x);
  float y_channel = 0.5 + 0.5 * edge_band * abs(normal.y);
  vec2 displacement = vec2(
    (x_channel - 0.5) * u_displacement_scale / max(u_size.x, 1.0),
    (y_channel - 0.5) * u_displacement_scale / max(u_size.y, 1.0)
  );

  vec2 sample_uv = clamp(uv + displacement, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  sample_uv.y = 1.0 - sample_uv.y;
#endif

  frag_color = texture(u_texture, sample_uv);
}
