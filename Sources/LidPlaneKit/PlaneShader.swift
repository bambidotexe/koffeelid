enum PlaneShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Uniforms { float angle; float blurStrength; float zoom; float perspective; float edgeSoftness; float shading; float4 voidColor; };

    vertex VOut planeVertex(uint id [[vertex_id]]) {
        // one triangle covering the viewport: ids 0,1,2 -> (-1,-1) (3,-1) (-1,3)
        float2 p = float2((id << 1) & 2, id & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);          // y grows downward like the texture
        return o;
    }

    // smoothstep whose zero-width edge is a step, like PlaneRemap.smoothstep.
    static float melt(float width, float d) {
        return width > 0.0 ? smoothstep(0.0, width, d) : step(0.0, d);
    }

    // Mirrors PlaneRemap ("inner screen"): the desktop stands upright at the hinge; a display row at
    // height h shows the desktop at h·cos(a)^zoom, so it is magnified from the hinge and cropped at the
    // top. Perspective narrows the inner screen toward the top (| | → / \) with straight edges: the
    // visible half-width is linear in h, from 0.5 at the hinge to 0.5/topNarrowing at the top row.
    // `coverage` is 0 in the void beside the inner screen; the sides melt into it over
    // 0.35·softness·h·sin(a) display widths and the top row over 0.08·softness·sin(a) display heights
    // (crisp at the hinge, widest at the top corners), so the outline never ends on a hard line.
    static float2 remap(float2 uv, float a, float zoom, float perspective, float softness, thread float &coverage) {
        float h = 1.0 - uv.y;
        float cosA = max(cos(a), 1e-4), sinA = fabs(sin(a));
        float m = pow(cosA, -zoom);
        float top = 1.0 + 2.0 * (1.0 - cosA) * perspective;
        float halfWidth = 0.5 * (1.0 - h * (1.0 - 1.0 / top));
        float x = 0.5 + (uv.x - 0.5) * 0.5 / halfWidth;
        coverage = melt(0.35 * softness * h * sinA, halfWidth - fabs(uv.x - 0.5))
                 * melt(0.08 * softness * sinA, 1.0 - h);
        return float2(x, 1.0 - min(1.0, h / m));
    }

    fragment float4 planeFragment(VOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> b1  [[texture(1)]],
                                  texture2d<float> b2  [[texture(2)]],
                                  texture2d<float> b3  [[texture(3)]],
                                  texture2d<float> b4  [[texture(4)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float coverage;
        float2 uv = remap(in.uv, u.angle, u.zoom, u.perspective, u.edgeSoftness, coverage);
        if (coverage <= 0.0) return u.voidColor;

        // gap between the glass and the inner screen: h·sin(a); blur and shading both grow with it
        float h = 1.0 - in.uv.y;
        float gap = h * fabs(sin(u.angle));
        float radius = u.blurStrength * gap * 65.0;
        float shade = max(0.0, 1.0 - 0.55 * u.shading * gap);

        float4 c0 = src.sample(s, uv), c1 = b1.sample(s, uv), c2 = b2.sample(s, uv),
               c3 = b3.sample(s, uv), c4 = b4.sample(s, uv);
        float4 color;
        if (radius < 2.0)       color = mix(c0, c1, radius / 2.0);
        else if (radius < 6.0)  color = mix(c1, c2, (radius - 2.0) / 4.0);
        else if (radius < 16.0) color = mix(c2, c3, (radius - 6.0) / 10.0);
        else                    color = mix(c3, c4, clamp((radius - 16.0) / 24.0, 0.0, 1.0));
        return mix(u.voidColor, float4(color.rgb * shade, color.a), coverage);
    }
    """#
}
