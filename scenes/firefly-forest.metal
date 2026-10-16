// =====================================================================
//  Firefly Forest — ground-level night view into a clearing of an
//  old-growth fir forest. The moon sits out of frame (upper-left, in
//  front of the camera) so the fog is back-lit: shafts slant down
//  through canopy gaps, low ground fog drifts across the floor, and
//  ~64 fireflies drift on closed paths and pulse with staggered
//  rhythms.
//
//  Technique: 12 depth planes (2.4 .. 100 m) composited front to back.
//  Near planes carry hand-placed trunks with fissured bark + bump
//  shading, far planes are procedural fir silhouettes. Between planes
//  the fog volume (height haze + loop-safe ground fog) is integrated
//  with jittered sub-steps; moon light is shadowed by a canopy-gap
//  function projected along the moon direction (true volumetric god
//  rays). A thin-lens circle of confusion (focus ~12 m) softens near
//  silhouettes and bark, and fireflies bokeh accordingly. Fireflies
//  are composited inside the plane loop so they are occluded by trunks
//  and attenuated by fog physically.
// =====================================================================

constant float DEG = 0.017453292519943295;

constant float3 FF_L     = float3(-0.5014, 0.6217, -0.6017);  // toward the moon
constant float3 FF_RO    = float3(0.0, 1.02, 0.0);
constant float  FF_PITCH = 1.6;
constant float  FF_FOV   = 50.0;
constant float  FF_HC    = 23.0;           // canopy shadow plane (m)
constant float  FF_SIGH  = 0.0135;          // haze extinction at ground (1/m)
constant float  FF_HAZEH = 15.0;           // haze scale height
constant float  FF_SIGG  = 0.155;           // ground-fog peak extinction
constant float  FF_EM    = 3.45;            // moon irradiance — deep midnight (owner: darker, always)
constant float3 FF_MOONC = float3(0.66, 0.80, 1.00);
constant float3 FF_FOGA  = float3(0.48, 0.78, 0.86);   // fog albedo (blue-green)
constant float3 FF_AMB   = float3(0.0145, 0.0290, 0.0585);// ambient radiance in fog (halved for midnight)
constant float3 FF_FFCOL = float3(0.86, 1.00, 0.30);   // firefly colour (mean)
constant float3 FF_FFWARM= float3(1.00, 0.80, 0.24);   // amber end of the range
constant float3 FF_FFCOOL= float3(0.60, 1.00, 0.34);   // green end of the range
constant float  FF_FFP   = 3200.0;                     // firefly power
constant float  FF_EXPO  = 1.45;
constant float  FF_FOCUS = 6.4;           // focus distance (m)
constant float  FF_APER  = 9.0;           // CoC px at 1600p for 1/m defocus

constant int   FF_NROW   = 26;
constant float FF_Z[26]   = { 1.15, 1.45, 1.80, 2.20, 2.40, 2.90, 3.40, 3.80, 4.40, 5.00, 5.50,
                              6.30, 7.20, 8.00, 9.20, 11.5, 13.0, 16.0, 18.5, 22.0, 26.0, 30.0,
                              41.0, 56.0, 75.0, 100.0 };
constant float FF_W[26]   = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
                              3.8, 3.7, 3.6, 3.55, 3.5, 3.45, 3.4, 3.3, 3.2, 3.0, 3.0 };
constant float FF_DEN[26] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                              0.55, 0.575, 0.60, 0.63, 0.66, 0.69, 0.72, 0.80, 0.86, 0.92, 0.96 };
// which plane each hand-placed near trunk lives on
constant int FF_NEARP[8] = { 4, 7, 10, 10, 13, 13, 13, 13 };
// hand-placed near trunks: x, radius, lean, seed
constant float4 FF_NEAR[8] = {
    float4(-2.16, 0.46,  0.020, 1.0),
    float4( 2.62, 0.41, -0.015, 2.0),
    float4(-4.30, 0.38,  0.010, 3.0), float4( 5.70, 0.35, -0.020, 4.0),
    float4(-7.60, 0.40,  0.000, 5.0), float4(-2.90, 0.30,  0.030, 6.0),
    float4( 7.00, 0.36, -0.010, 7.0), float4(10.60, 0.30,  0.000, 8.0) };
constant int FF_NFF = 72;

// ---------------------------------------------------------------- light
inline float ff_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * c, 1.5));
}
// canopy openness above the forest, sampled in the canopy plane (x, z)
inline float ff_gap(float2 xz, float hgt) {
    float n1 = fbm(xz * 0.048 + float2(3.1, 7.7), 3);          // broad boughs
    // the clutter layer shears with height, so a shaft is not a perfect prism
    float n2 = fbm(xz * 0.185 + float2(9.2, 1.3) + float2(0.021, -0.014) * hgt, 2);
    // Main canopy opening, placed so its shafts land in the clearing ahead.
    float2 cq = (xz - float2(-20.0, -36.0)) * float2(0.62, 0.42);
    float pool = 1.0 - smoothstep(1.0, 13.0, length(cq));
    // a smaller second window, right of the first
    float2 cr = (xz - float2(-4.0, -30.0)) * float2(0.80, 0.55);
    float pool2 = 0.62 * (1.0 - smoothstep(0.5, 6.5, length(cr)));
    float sky = max(pool, pool2);
    float open  = smoothstep(-0.02, 0.38, n1) * (0.07 + 0.93 * sky);
    float holes = smoothstep(0.28, 0.50, n2) * (0.10 + 0.90 * sky);
    float g = max(open, holes);
    g = smoothstep(0.02, 0.62, g);                              // crisp shaft edges
    g = 0.012 + 0.988 * g * g;
    // turbulence along the shaft: the haze inside a beam is never uniform
    float tb = gnoise(float2(xz.x * 0.33 + hgt * 0.30, xz.y * 0.33 - hgt * 0.21));
    return g * (0.79 + 0.46 * smoothstep(-0.70, 0.70, tb));
}
// direct moon-light factor at a point below the canopy (shadow + fog path)
inline float ff_moon(float3 p) {
    float h = max(FF_HC - p.y, 0.0) / FF_L.y;
    float2 q = p.xz + FF_L.xz * h;
    float od = FF_SIGH * FF_HAZEH * (exp(-max(p.y, 0.0) / FF_HAZEH) - exp(-FF_HC / FF_HAZEH)) / FF_L.y;
    return ff_gap(q, p.y) * exp(-0.6 * od);
}

// ---------------------------------------------------------------- fog
inline float ff_haze(float y) { return FF_SIGH * exp(-max(y, 0.0) / FF_HAZEH); }
inline float ff_gfog(float3 p, float t) {
    float h = smoothstep(2.9, -0.15, p.y);
    if (h <= 0.0) return 0.0;
    float2 q = p.xz * 0.20;
    float w = abs(2.0 * fract(t) - 1.0);
    float2 drift = float2(3.0, 1.2) * 0.20;
    float nA = fbmLoop(q + drift * fract(t), t, 2, 1);
    float nB = fbmLoop(q + drift * fract(t + 0.5) + float2(31.7, 12.3), t, 2, 1);
    float n = mix(nA, nB, w) / sqrt(w * w + (1.0 - w) * (1.0 - w));
    float big = fbm(q * 0.30 + float2(1.7, 4.2), 2);
    float dens = smoothstep(-0.50, 0.62, n + 0.65 * big + 0.12);
    // wisps: thin, stretched filaments riding on the banks
    float wisp = 0.5 + 0.5 * sin(7.5 * (q.x * 0.45 + q.y) + 6.5 * n + 3.0 * big);
    dens *= 0.58 + 0.70 * wisp * smoothstep(0.05, 0.85, dens);
    float lay = 0.50 + 0.50 * smoothstep(2.1, 0.20, p.y);      // denser right at the floor
    lay *= 1.0 + 0.85 * smoothstep(0.0, 1.2, -p.z * 0.06) * (1.0 - smoothstep(30.0, 70.0, -p.z));
    dens *= 0.78 + 0.44 * smoothstep(-0.40, 0.45, gnoise(float2(q.x * 1.05, q.y * 5.0) + 17.0));
    return FF_SIGG * h * h * lay * (0.08 + 0.92 * dens);
}

// integrate fog along the ray from s0 to s1 (front to back)
inline void ff_fogSeg(thread float3 &col, thread float &T, float3 ro, float3 rd, float s0, float s1,
                      float t, float jit, float phase) {
    float len = s1 - s0;
    if (len <= 1e-4) return;
    float stepLen = 0.36 + 0.050 * s0;
    int n = clamp(int(len / stepLen) + 1, 1, 17);
    float ds = len / float(n);
    for (int i = 0; i < n; i++) {
        float j = mix(0.5, fract(jit + float(i) * 0.6180339887), 0.70);   // decorrelated jitter
        float sm = s0 + ds * (float(i) + j);
        float3 p = ro + rd * sm;
        float sig = ff_haze(p.y) + ff_gfog(p, t);
        float mn = ff_moon(p);
        float3 light = FF_MOONC * (FF_EM * phase * mn) + FF_AMB;
        float3 alb = mix(float3(0.46, 0.80, 0.78), FF_FOGA, smoothstep(0.0, 7.0, p.y));
        // colour-temperature drift across the volume: warmer where the moon
        // pools through a gap, cooler in the deep shade
        alb *= mix(float3(0.93, 0.99, 1.06), float3(1.12, 1.02, 0.88),
                   smoothstep(0.08, 0.80, mn));
        float tr = exp(-sig * ds);
        col += T * alb * light * (1.0 - tr);
        T *= tr;
    }
}

// ---------------------------------------------------------------- fireflies
struct FFly { float3 pos; float bright; };
inline FFly ff_fly(int i, float t) {
    float fi = float(i) + 0.5;
    float4 h1 = hash44(float4(fi, 1.3, 2.7, 9.1));
    float4 h2 = hash44(float4(fi, 5.9, 7.3, 3.7));
    float4 h3 = hash44(float4(fi, 8.1, 0.4, 6.6));
    // three depth bands: two hero lights right under the lens (big bokeh
    // discs low in frame), a near group, and the scattered mid/far cloud
    bool hero = i < 2;
    bool near = i < 18;
    float cz = hero ? (1.28 + 0.62 * h1.x)
             : near ? (1.9 + 3.4 * h1.x)
                    : 3.2 * exp(h1.x * 2.32);         // 1.0 .. 33 m
    // spread wider and biased left: the right third stays calm for icons
    float sx = h1.y - 0.56;
    float cx = sx * ((hero ? 3.4 : near ? 5.2 : 7.4) + 0.62 * cz);
    if (hero) cx = (h1.y < 0.5 ? -1.0 : 1.0) * (0.85 + 1.35 * h1.y);
    float cy = hero ? (0.86 + 0.52 * h1.z) : (0.24 + 3.30 * pow(h1.z, 1.75));
    cy *= 1.0 - 0.64 * smoothstep(0.5, 8.0, cx);       // keep the top-right calm
    int k2 = 2 + int(h2.w * 2.0);
    float a1 = TAU * (t + h2.x), a2 = TAU * (float(k2) * t + h2.y), a3 = TAU * (t + h2.z);
    float r1 = 0.45 + 0.75 * h3.x;
    float3 p = float3(cx, cy, -cz);
    p += float3(r1 * cos(a1), 0.35 * r1 * sin(a3), 0.7 * r1 * sin(a1));
    p += 0.2 * float3(sin(a2), 0.5 * cos(a2 + 1.0), cos(a2));
    int kp = 1 + int(h3.y * 2.0);
    float u = fract(float(kp) * t + h3.z);
    float on = 0.30 + 0.22 * h3.w;
    float env = smoothstep(0.0, 0.15, u) * (1.0 - smoothstep(on, on + 0.24, u));
    env = env * env * (3.0 - 2.0 * env);
    FFly f; f.pos = p; f.bright = env * (0.55 + 1.15 * h1.w * h1.w) * (hero ? 1.45 : 1.0);
    return f;
}
inline float3 ff_glow(float2 dpx, float R, float flux, float3 fc) {
    float r2 = dot(dpx, dpx);
    float rmax = 46.0 + 6.0 * R;
    if (r2 > rmax * rmax) return float3(0.0);
    float r = sqrt(r2);
    // defocused disc with a slightly brighter rim (real bokeh); the disc edge
    // lands at a marginally different radius per channel — lens CA
    float soft = max(1.05, R * 0.38);
    float3 Rc = R * float3(1.022, 1.000, 0.980);
    float3 disc = float3(1.0) - smoothstep(Rc - soft, Rc + soft, float3(r));
    float rim  = R > 3.0 ? 1.0 + 0.34 * smoothstep(R * 0.52, R * 0.97, r) : 1.0;
    float3 core = flux / (PI * R * R + 2.6) * disc * rim;
    // bloom: a tight halo plus a wide veil, both rolled off with disc area so
    // a big near bokeh blooms softly instead of blowing out
    float a2 = R * R + 11.0;
    float amp = flux / (1.0 + R * R / 17.0);
    float halo = amp * 0.0148 / (1.0 + r2 / a2);
    float veil = amp * 0.0033 / (1.0 + r2 / (a2 * 7.0));
    float fade = 1.0 - smoothstep(rmax * 0.42, rmax, r);
    return mix(fc, float3(1.0), 0.15) * core + fc * (halo + veil) * fade;
}
// per-firefly bioluminescent colour: amber .. yellow-green
inline float3 ff_flyCol(int i) {
    float h = hash12(float2(float(i) * 1.7 + 0.31, 12.77));
    return mix(FF_FFWARM, FF_FFCOOL, h * h);
}
// warm light from nearby fireflies on a surface
inline float3 ff_flyLight(float3 P, float3 n, thread float4 *fp) {
    float3 acc = float3(0.0);
    for (int i = 0; i < FF_NFF; i++) {
        float4 f = fp[i];
        if (f.w <= 0.001) continue;
        float3 d = f.xyz - P;
        float d2 = dot(d, d);
        if (d2 > 4.0) continue;
        float ndl = max(dot(n, d * rsqrt(d2)), 0.0);
        float fall = 1.0 - d2 / 4.0;
        acc += f.w * ndl / (d2 + 0.12) * fall * fall;
    }
    return acc * FF_FFCOL * 0.045;
}

// ---------------------------------------------------------------- trunks
// fissured conifer bark: vertical ridges, broken plates, fine grain
// fissured conifer bark: deep vertical furrows broken into plates, fine grain
inline float ff_barkTex(float u, float y, float seed) {
    float lf = gnoise(float2(u * 1.15 + seed * 2.0, y * 0.42 + seed));   // furrow density drifts
    float2 q = float2(u * (7.5 + 2.6 * lf) + seed * 3.0, y * (1.5 + 0.55 * lf) + seed * 1.7);
    float fis = ridged(q, 3);
    fis = pow(clamp(fis, 0.0, 1.0), 0.52);
    // plates: worley cells elongated along the trunk, split by cross checks
    float2 wc = worley(float2(u * 6.5 + seed * 2.3, y * 0.85 + seed * 3.1));
    float plateEdge = smoothstep(0.0, 0.16, wc.y - wc.x);
    float cross = ridged(float2(y * 6.0 + seed * 4.3, u * 2.2) * float2(1.0, 0.42), 2);
    float grain = 0.5 + 0.5 * gnoise(float2(u * 42.0 + seed * 9.0, y * 7.0));
    float fine  = 0.5 + 0.5 * gnoise(float2(u * 150.0, y * 22.0 + seed * 5.0));
    float b = fis * 0.80 + 0.26 * gnoise(float2(u * 3.4 + seed * 2.1, y * 0.85 + seed));
    b = smoothstep(0.06, 0.74, b);
    b *= 0.26 + 0.74 * plateEdge;                       // deep splits between plates
    b *= 0.78 + 0.22 * smoothstep(0.20, 0.72, cross);
    b = b * (0.84 + 0.16 * grain) + 0.045 * fine;
    return clamp(b, 0.0, 1.2);
}
// signed half-width of a trunk silhouette at height y (metres)
inline float ff_trunkW(float y, float r0, float seed) {
    float w = r0 * (1.0 - 0.012 * y) + r0 * 0.92 * exp(-max(y, 0.0) * 1.35);   // root flare
    w *= 1.0 + 0.070 * gnoise(float2(y * 2.3 + seed * 5.0, seed * 7.0))
             + 0.038 * gnoise(float2(y * 7.1 + seed * 3.0, seed * 2.0))
             + 0.018 * gnoise(float2(y * 19.0 + seed * 11.0, seed * 13.0));
    // buttress ribs swelling out of the base
    w *= 1.0 + 0.16 * exp(-max(y, 0.0) * 2.2)
             * (0.5 + 0.5 * gnoise(float2(y * 3.0, seed * 21.0)));
    return w;
}
inline float3 ff_trunkShade(float3 P, float nx, float w, float seed, float fp,
                            thread float4 *fp4, bool detail, float soft) {
    float nz = sqrt(max(1.0 - nx * nx, 0.0));
    float3 n = float3(nx, 0.0, nz);
    float sharp = 1.0 / (1.0 + 0.22 * soft);      // defocus softens micro contrast
    // base bark colour: grey-brown, drifting reddish in patches
    float4 ch = hash24(float2(seed * 13.7 + 1.3, 7.9));
    float3 alb = mix(float3(0.128, 0.098, 0.072), float3(0.108, 0.094, 0.085), ch.x);
    float b0 = 0.5, shadow = 1.0, ao = 1.0;
    if (detail) {
        float u = asin(clamp(nx, -1.0, 1.0)) * w;
        float e = max(0.0035, fp * 0.8);
        b0 = ff_barkTex(u, P.y, seed);
        float b1 = ff_barkTex(u + e, P.y, seed);
        float b2 = ff_barkTex(u, P.y + e, seed);
        float3 tang = float3(nz, 0.0, -nx);
        float bump = 0.24 * sharp;
        n = normalize(n - tang * ((b1 - b0) / e) * bump
                        - float3(0.0, 1.0, 0.0) * ((b2 - b0) / e) * bump * 0.5);
        // horizon self-shadowing: a furrow is dark because the ridge beside it
        // blocks the moon. Step along the light in bark space and compare.
        float step1 = ff_barkTex(u - 0.020, P.y + 0.024, seed);
        float step2 = ff_barkTex(u - 0.045, P.y + 0.055, seed);
        float occ = max(step1 - b0, (step2 - b0) * 0.7);
        shadow = 1.0 - clamp(occ * 3.4, 0.0, 0.94) * sharp;
        ao = (0.13 + 0.87 * clamp(b0 * 1.25, 0.0, 1.0));      // crevices darker
        float bLow = 0.5 + 0.5 * fbm(float2(u * 2.2 + seed * 3.0, P.y * 0.60 + seed), 3)
                   + 0.30 * gnoise(float2(u * 0.9, P.y * 0.22 + seed * 2.0));
        alb *= (0.42 + 0.88 * mix(bLow, b0, sharp)) * (0.70 + 0.62 * bLow);
        // lichen / moss: pale green-grey crusts, favouring the damp shaded side
        float lich = smoothstep(0.40, 0.76, fbm(float2(u * 2.6 + seed * 9.0, P.y * 0.95), 3))
                   * smoothstep(-0.2, 0.7, nx) * smoothstep(5.0, 0.4, P.y);
        alb = mix(alb, float3(0.128, 0.140, 0.104), lich * 0.60 * (0.45 + 0.55 * sharp));
        // knots where limbs were shed: a swirl of grain around a dark eye
        float2 kc = float2(u * 1.6 + seed * 4.0, P.y * 0.55 + seed * 2.0);
        float2 kf = floor(kc);
        float4 kh = hash24(kf + 0.5);
        if (kh.w > 0.76) {
            float2 kd = (kc - kf - float2(0.30 + 0.4 * kh.x, 0.30 + 0.4 * kh.y));
            float kr = length(kd * float2(1.0, 1.9));
            float knot = 1.0 - smoothstep(0.06, 0.22, kr);
            alb = mix(alb, float3(0.052, 0.040, 0.030), knot * 0.85);
            ao *= 1.0 - 0.45 * knot;
            n = normalize(n + float3(nz, 0.0, -nx) * kd.x * knot * 2.2
                            + float3(0.0, 1.0, 0.0) * kd.y * knot * 1.4);
        }
        // dark rain streaks running down the furrows
        float streak = smoothstep(0.55, 0.95, fbm(float2(u * 16.0 + seed, P.y * 0.55), 2));
        alb *= 1.0 - 0.34 * streak * (0.5 + 0.5 * sharp);
    }
    float moon = ff_moon(P);
    float ndl = max(dot(n, FF_L), 0.0);
    // wrapped terminator: bark is rough, so the falloff is broad, not Lambert-hard
    float wrapD = clamp((dot(n, FF_L) + 0.28) / 1.28, 0.0, 1.0);
    wrapD *= wrapD * wrapD;
    float3 col = alb * FF_MOONC * (FF_EM * 0.36) * moon * (0.62 * ndl + 0.38 * wrapD) * shadow;
    // the glowing fog is a DIRECTIONAL source: bright on the moon side, dim behind
    float domeD = clamp(0.5 + 0.5 * dot(n, normalize(FF_L + float3(0.0, 0.55, 0.0))), 0.0, 1.0);
    float3 dome = (FF_MOONC * (0.018 + 0.055 * moon)) * (0.16 + 0.84 * domeD * domeD)
                + FF_AMB * (0.42 + 0.50 * domeD);
    col += alb * dome * ao * (0.30 + 0.70 * shadow) * (0.46 + 0.54 * smoothstep(-0.4, 3.4, P.y));
    // the lit fog behind the trunk wraps its edges
    float edge = pow(abs(nx), 7.0) * (0.35 + 0.65 * smoothstep(0.0, -0.8, nx));
    float3 rimc = mix(FF_FOGA, float3(1.0), 0.15);
    col += rimc * (FF_AMB.b * 0.85 + FF_EM * 0.020 * moon) * edge
         * (0.35 + 0.65 * smoothstep(-0.3, 4.0, P.y));
    col += alb * ff_flyLight(P, n, fp4);
    return col;
}

// fir silhouette half-width for procedural rows (tiers above branch height)
inline float ff_firW(float y, float r0, float Hb, float Ht, float4 h, float fp, float reach) {
    // the bole tapers into the leader instead of stopping flat at the top
    float w = ff_trunkW(y, r0, h.x * 10.0) * (1.0 - smoothstep(max(Hb, Ht - 9.0), Ht, y));
    if (y > Hb && y < Ht) {
        float s = Ht - y;
        float taper = 0.122 * (0.70 + 0.62 * h.y);
        float env = taper * (s + 0.4) * (1.0 + 0.22 * gnoise(float2(s * 0.35 + h.x * 40.0, h.y * 13.0)));
        env *= smoothstep(0.0, 0.55, s);                    // the tip comes to a point
        float sp = (0.55 + 0.95 * h.z);
        // whorls are not evenly spaced on a real fir
        float q = s / sp + h.w * 3.0 + 0.95 * gnoise(float2(s * 0.27 + h.x * 40.0, h.y * 11.0));
        float n = floor(q), ph = fract(q);
        float4 wh = hash24(float2(n + h.x * 131.0, h.y * 71.0));
        float Lb = 0.42 + 0.78 * wh.x;
        // a whorl is a ring of limbs, not a plate: its reach fades in and out
        float tier = Lb * (0.34 + 0.66 * pow(ph, 0.45 + 0.5 * wh.y))
                   * (1.0 - 0.42 * smoothstep(0.62 + 0.25 * wh.z, 1.0, ph));
        float det = 1.0 - smoothstep(sp * 0.22, sp * 0.85, fp);
        float dB = 1.0 - smoothstep(0.022, 0.080, fp);      // ~7/m detail
        float dA = 1.0 - smoothstep(0.009, 0.036, fp);      // ~17/m detail
        float rag = gnoise(float2(s * 2.6 + h.z * 17.0, n * 0.37 + h.x * 9.0))
                  + 0.6 * dB * gnoise(float2(s * 7.0 + h.w * 23.0, y * 3.1))
                  + 0.35 * dA * gnoise(float2(s * 17.0 + h.y * 31.0, y * 8.0));
        env *= mix(0.88, tier, det * 0.40) + 0.52 * rag;
        // ragged, gradual crown base — no mushroom cap
        float base = smoothstep(Hb, Hb + 5.5, y);
        base *= 0.70 + 0.30 * smoothstep(-0.4, 0.5, gnoise(float2(y * 0.9 + h.z * 51.0, h.w * 17.0)));
        env *= base;
        w = max(w, min(env, reach));    // never wider than the cell scan can see
    } else if (y >= Ht) {
        w = -0.05 - 0.30 * (y - Ht);                        // soft, AA-able falloff
    }
    return w;
}

// ---------------------------------------------------------------- undergrowth
// One pinnate frond / blade: thin rachis with leaflets, drooping under gravity.
inline float ff_frond(float2 d, float ang, float L, float w0, float bend, float pinna) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    float axial = max(-u, u - L);                 // distance outside the blade span
    if (axial > 0.25 * L + 0.05) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = clamp(u / L, 0.0, 1.0);
    float vc = bend * L * (k * k * (0.55 + 0.45 * k));      // arcing rachis
    float dv = abs(v - vc);
    float rach = dv - (0.0035 + 0.0075 * L * (1.0 - 0.8 * k));
    if (pinna > 0.0) {
        // lanceolate blade, widest a third of the way out, with fine leaflets
        float shape = pow(1.0 - k, 0.58) * smoothstep(0.0, 0.08, k);
        float lobe = 0.52 + 0.48 * pow(abs(sin(u * pinna)), 0.5);
        return max(min(rach, dv - w0 * shape * lobe), axial);
    }
    float blade = w0 * (1.0 - k) * (0.25 + 0.75 * smoothstep(0.0, 0.10, k));
    return max(min(rach, dv - blade), axial);
}
// min signed distance of an undergrowth cell at (x, y); base at cell centre
// A pinnate frond: arching rachis with discrete leaflets swept toward the tip.
// Only the two leaflet pairs straddling the sample are evaluated.
inline float ff_pinnate(float2 d, float ang, float L, float lmax, float bend, float nlf, float det) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    float axial = max(-u, u - L);                 // distance outside the frond span
    if (axial > 0.25 * L + 0.05) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = clamp(u / L, 0.0, 1.0);
    float vc = bend * L * (k * k * (0.55 + 0.45 * k));
    // rachis; as the frond shrinks under a couple of pixels (det -> 0) the
    // pinnae dissolve into a solid blade so nothing aliases
    float solid = (1.0 - det) * lmax * 0.92 * pow(1.0 - k, 0.55) * smoothstep(0.0, 0.08, k);
    float dm = max(abs(v - vc) - (0.0026 + 0.0050 * L * (1.0 - 0.75 * k) + solid), axial);
    if (det <= 0.03) return dm;
    float sp = L / nlf;
    float base = floor(k * nlf);
    for (int m = -1; m <= 1; m++) {
        float mi = base + float(m);
        for (int sg = 0; sg < 2; sg++) {
            float sv = sg == 0 ? 1.0 : -1.0;
            float ku = (mi + (sg == 0 ? 0.20 : 0.62)) / nlf;    // sub-opposite pairs
            if (ku <= 0.025 || ku >= 0.99) continue;
            float2 hs = hash22(float2(mi * 2.0 + float(sg), nlf + bend * 13.0 + L * 29.0));
            float hl = hs.x, hj = hs.y;
            ku += (hj - 0.5) * 0.46 / nlf;                  // spacing is never even
            if (ku <= 0.025 || ku >= 0.99) continue;
            float uu = ku * L;
            float vv = bend * L * (ku * ku * (0.55 + 0.45 * ku));
            float slope = bend * (1.10 * ku + 1.35 * ku * ku);
            float lf = det * lmax * pow(1.0 - ku, 0.58) * smoothstep(0.0, 0.07, ku)
                     * (0.62 + 0.78 * hl * hl);             // length varies a lot
            float2 q = float2(u - uu, v - vv);
            if (dot(q, q) > (lf + 0.01) * (lf + 0.01)) continue;
            float2 tg = normalize(float2(1.0, slope));
            float2 nm = float2(-tg.y, tg.x);
            float2 ax = normalize(tg * (0.18 + 0.66 * hj * hj) + nm * sv * (0.86 + 0.42 * hl));
            float tt = clamp(dot(q, ax), 0.0, lf);
            float tk = clamp(tt / max(lf, 1e-4), 0.0, 1.0);
            float rr = (0.21 + 0.13 * hj) * sp * pow(1.0 - tk, 0.62) * (0.55 + 0.75 * sqrt(max(tk, 0.02)) * (1.0 - tk) * 2.0)
                     + 0.008 * lf + 0.0004 + 0.0016 * hl;   // lanceolate, pointed
            dm = min(dm, length(q - ax * tt) - rr);
        }
    }
    return max(dm, axial);
}

// one ovate leaf as a tapered, slightly curved blade from the clump centre
inline float ff_leaf(float2 d, float ang, float L, float w0, float bend) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    if (u < 0.0 || u > L) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = u / L;
    float vc = bend * L * k * k;
    float w = w0 * sqrt(max(k, 0.0)) * (1.0 - k) * 2.0;
    return abs(v - vc) - w - 0.003;
}
inline float ff_plantD(float2 d, float4 h, float size, float det) {
    float dm = 1e3;
    float kind = h.x;
    if (kind < 0.72) {
        // --- fern clump: two crowns, long narrow pinnate fronds
        // fronds leave the crown nearly upright and arch outward under their
        // own weight — a shuttlecock, not a star
        int nf = 11;
        float spread = 0.50 + 0.38 * h.y;
        float lean = (h.z - 0.5) * 0.50;
        for (int j = 0; j < nf; j++) {
            float fj = (float(j) + 0.5) / float(nf) - 0.5;      // -0.5 .. 0.5
            float hj = hash12(float2(float(j) + h.y * 40.0, h.z * 90.0));
            float hk = hash12(float2(float(j) * 3.1 + h.w * 20.0, h.x * 70.0));
            float side = fj * 2.0;                               // -1 .. 1
            float ang = PI * 0.5 + 0.26 * side + 0.30 * (hj - 0.5) + lean * 0.35;
            float bend = spread * side * (0.55 + 0.80 * abs(side)) + lean + 0.12 * (hk - 0.5);
            float L = size * (0.50 + 0.40 * hk) * (1.0 - 0.24 * abs(side));
            float2 o = float2(0.09 * size * (hj - 0.5), 0.03 * size * hk);
            float lmax = 0.205 * L * (0.76 + 0.48 * hj * hk);   // pinna length
            float nlf = clamp(floor(L / (0.017 + 0.008 * hj)), 14.0, 52.0);
            dm = min(dm, ff_pinnate(d - o, ang, L, lmax, bend, nlf, det));
        }
    } else {
        // --- grass tuft: fine tapered blades arcing both ways
        int nf = 13;
        for (int j = 0; j < nf; j++) {
            float fj = (float(j) + 0.5) / float(nf);
            float hj = hash12(float2(float(j) + h.y * 40.0, h.z * 90.0));
            float hk = hash12(float2(float(j) * 3.1 + h.w * 20.0, h.x * 70.0));
            float side = (fj - 0.5) * 2.0;
            float ang = PI * 0.5 + 0.18 * side + 0.22 * (hj - 0.5);
            float L = size * (0.38 + 0.52 * hk * hk);
            float2 o = float2(0.16 * size * (hj - 0.5), 0.0);
            // outer blades arc over, but they do not whip: an uncapped bend sent
            // a tapering frond ~2 m sideways and it drew as a wire across frame
            float bend = side * (0.52 + 0.40 * abs(side)) + 0.26 * (hk - 0.5);
            dm = min(dm, ff_frond(d - o, ang, L, 0.026 * size, bend, 0.0));
        }
    }
    return dm;
}

// ---------------------------------------------------------------- grass carpet
// The forest floor is not a plane: it is a canopy of grass sitting on undulating
// soil. We intersect the view ray with that canopy as a height field, so the
// horizon of the grass is ragged, tussocks occlude each other, and the blade
// layer recedes continuously into the distance instead of stopping at a seam.

// loop-safe wind: gusts travel across the clearing rather than a uniform sway
inline float ff_gust(float2 xz, float t) {
    float2 q = xz * 0.085;
    float2 dir = float2(0.86, 0.51);
    float w = abs(2.0 * fract(t) - 1.0);
    float a = fbmLoop(q - dir * 1.30 * fract(t), t, 2, 1);
    float b = fbmLoop(q - dir * 1.30 * fract(t + 0.5) + float2(37.2, 9.4), t, 2, 1);
    float n = mix(a, b, w) / sqrt(w * w + (1.0 - w) * (1.0 - w));
    // gust fronts: sharp leading edge, long tail
    return smoothstep(-0.15, 0.55, n);
}
// grass cover 0..1 — broad patchiness plus a worn, trodden lane in the clearing
inline float ff_cover(float2 xz) {
    float p = 0.52 + 0.62 * gnoise(xz * 0.150 + float2(21.0, 5.0))
                   + 0.30 * gnoise(xz * 0.560 + float2(3.7, 11.2));
    float c = smoothstep(0.16, 0.78, p);
    float lane = xz.x - 1.1 + 2.7 * gnoise(float2(xz.y * 0.055, 4.1));
    c *= 1.0 - 0.80 * exp(-lane * lane * 0.30);
    return clamp(c, 0.0, 1.0);
}
// soil relief under the grass
inline float ff_soilH(float2 xz) {
    return 0.20 * gnoise(xz * 0.155 + float2(4.3, 1.9))
         + 0.075 * gnoise(xz * 0.72 + float2(9.1, 7.2));
}
// canopy height above y = 0 (cheap: this is evaluated ~30x per pixel)
// fadeG fades the sward itself (high frequency, aliases early); the soil
// relief underneath is low frequency and survives much further, which keeps
// the grass horizon broken instead of ruler-straight.
inline float ff_grassH(float2 xz, float t, float det, float fadeG, float fadeS) {
    float cov = ff_cover(xz);
    float tuft = 0.5 + 0.5 * gnoise(xz * 2.15 + float2(12.0, 3.1));
    float fine = 0.5 + 0.5 * gnoise(xz * 6.30 + float2(3.0, 19.0));
    float h = cov * (0.105 + 0.400 * tuft * tuft) * (0.52 + 0.48 * fine);
    if (det > 0.01) {
        float g = ff_gust(xz, t);
        float bl = gnoise(xz * 23.0 + float2(0.0, 7.0) + 0.06 * g);
        h += det * cov * 0.020 * bl;
    }
    return ff_soilH(xz) * fadeS + h * fadeG;
}
inline float ff_fadeG(float s) { return 1.0 - smoothstep(34.0, 88.0, s); }
inline float ff_fadeS(float s) { return 1.0 - smoothstep(130.0, 260.0, s); }
inline float ff_detOf(float fp) { return 1.0 - smoothstep(0.0022, 0.0110, fp); }
// ray / canopy intersection. Returns distance, 1e9 if the ray misses.
inline float ff_groundHit(float3 ro, float3 rd, float t, float pixAng) {
    if (rd.y > -2.0e-4) return 1e9;
    float inv = -1.0 / rd.y;
    float sFlat = ro.y * inv;
    float sLo = max((ro.y - 0.98) * inv, 0.03);
    float sHi = min((ro.y + 0.34) * inv, 210.0);
    if (sLo >= sHi) return sFlat;
    float3 p0 = ro + rd * sLo;
    float d0 = p0.y - ff_grassH(p0.xz, t, ff_detOf(sLo * pixAng), ff_fadeG(sLo), ff_fadeS(sLo));
    if (d0 <= 0.0) return sLo;
    const int N = 30;
    float ds = (sHi - sLo) / float(N);
    float sp = sLo;
    for (int i = 1; i <= N; i++) {
        float s = sLo + ds * float(i);
        float3 p = ro + rd * s;
        float d = p.y - ff_grassH(p.xz, t, ff_detOf(s * pixAng), ff_fadeG(s), ff_fadeS(s));
        if (d <= 0.0) {
            float w = d0 / max(d0 - d, 1e-5);
            return sp + w * ds;
        }
        sp = s; d0 = d;
    }
    return sFlat > sHi ? sFlat : 1e9;
}

// band-limited blade streak field: three scales, each faded out as it goes
// sub-pixel, so the carpet keeps micro structure right up to the resolve limit
inline float ff_bladeTex(float2 xz, float2 bd, float fp, float t, thread float &sheen) {
    float2 nrm = float2(-bd.y, bd.x);
    float u = dot(xz, nrm), v = dot(xz, bd);
    float g = ff_gust(xz, t);
    // the lines stay parallel (grass is combed, not swirled); only a slow
    // wander and the gust bend them
    float wob = 0.40 * gnoise(xz * 0.9) + 0.22 * g;
    float s = 0.0; sheen = 0.0;
    float f1 = 1.0 - smoothstep(0.0055, 0.0230, fp);
    float p1 = u * 46.0 + wob * 2.0 + 0.30 * v;
    s += 0.22 * f1 * sin(p1);
    float f2 = 1.0 - smoothstep(0.0014, 0.0068, fp);
    float p2 = u * 185.0 + wob * 5.0 + 0.7 * v + 1.3 * gnoise(xz * 11.0);
    s += 0.17 * f2 * sin(p2);
    // tussock-scale shading (always visible, this is what reads at distance)
    s += 0.30 * gnoise(xz * float2(3.1, 3.1) + 4.0) + 0.18 * gnoise(xz * 9.0 + 1.0);
    sheen = f1 * pow(max(0.5 + 0.5 * sin(p1), 0.0), 8.0)
          + 0.8 * f2 * pow(max(0.5 + 0.5 * sin(p2), 0.0), 10.0);
    return s;
}
// ---------------------------------------------------------------- grass blades
// Real blades, drawn on every depth plane inside the blade-resolving range.
// Their length, width and density follow the same cover/height fields as the
// carpet, so the geometry dissolves into the shaded canopy with no seam.
inline float ff_blades(float3 P, float Z, float fp, float fpB, float t,
                       thread float3 &bcol, thread float4 *fp4) {
    float cw = 0.020 + 0.0030 * Z;                 // blade cell width in x
    float ci = floor(P.x / cw);
    float cov = 0.0;
    float3 acc = float3(0.0);
    for (int di = -1; di <= 1; di++) {
        float cell = ci + float(di);
        for (int sb = 0; sb < 8; sb++) {
            float id = cell * 8.0 + float(sb);
            float4 h  = hash24(float2(id * 1.37 + 0.91, Z * 7.13 + 2.17));
            float4 h2 = hash24(float2(id * 2.71 + 5.33, Z * 3.91 + 8.07));
            float bx = (cell + (float(sb) + 0.5) * 0.125 + 0.11 * (h.x - 0.5)) * cw;
            float2 bxz = float2(bx, P.z);
            float cover = ff_cover(bxz);
            if (h.w > cover * 1.35 + 0.12) continue;
            float y0 = ff_soilH(bxz) - 0.025;
            float tuft = 0.5 + 0.5 * gnoise(bxz * 2.15 + float2(12.0, 3.1));
            float Lb = (0.125 + 0.170 * tuft + 0.50 * h.y * h.y * h.y) * (0.50 + 0.60 * cover);
            float k = (P.y - y0) / Lb;
            if (k < -0.12 || k > 1.10) continue;
            float kk = clamp(k, 0.0, 1.0);
            float g = ff_gust(bxz + float2(0.0, h.z), t);
            // a blade arcs over under its own weight; gusts push the arc further
            float bend = (h2.x - 0.5) * (0.30 + 0.85 * h.y * h.y) + (0.35 + 0.65 * h2.y) * (g - 0.35) * 0.46;
            float xc = bx + bend * Lb * kk * kk * (0.58 + 0.42 * kk);
            float w = (0.0013 + 0.0046 * h2.z * h2.z * h2.z) * (1.0 - 0.78 * kk * kk) * (0.72 + 0.56 * tuft);
            float axial = max(-k * Lb, (k - 1.0) * Lb * 1.6);
            float d = max(abs(P.x - xc) - w, axial);
            float c = clamp(0.5 - d / max(fpB * 0.80, 1e-5), 0.0, 1.0);
            if (c <= 0.001 || cov > 0.996) continue;
            // --- shade this blade
            float nx = clamp((P.x - xc) / max(w, 1e-4), -1.0, 1.0);
            float slope = 2.0 * bend * Lb * kk * (0.58 + 0.42 * kk) / max(Lb, 1e-4);
            float2 tg = normalize(float2(slope, 1.0));
            // blades are folded along the midrib: the normal sweeps across the width
            // blades face every azimuth: the ones turned away from us catch the
            // moon flat-on and flare, the ones facing us glow by transmission
            float face = h2.w < 0.48 ? -1.0 : 1.0;
            float twist = (h2.y - 0.5) * 1.1;
            float3 n = normalize(float3(nx * 0.90 - tg.x * 0.22 + twist * 0.35,
                                        0.26 + 0.34 * tg.y,
                                        (0.30 + 0.62 * abs(h2.x)) * face));
            float moon = ff_moon(P);
            float ndl = max(dot(n, FF_L), 0.0);
            float dry = h.z * h.z * h.z * h.z;
            float3 alb = mix(float3(0.0495, 0.0730, 0.0365), float3(0.0885, 0.0790, 0.0455), dry);
            alb *= 0.30 + 1.15 * h.x * h.x;
            // self-shadowing inside the sward: the base of a blade sees little
            float ao = smoothstep(-0.10, 0.80, kk);
            ao = 0.045 + 0.955 * ao * ao;
            ao *= 0.62 + 0.38 * cover;
            float3 c3 = alb * FF_MOONC * (FF_EM * 0.80) * moon * ndl * (0.12 + 0.88 * ao);
            // specular sliver along the blade — wet, waxy cuticle
            float3 hv = normalize(FF_L + float3(0.0, 0.0, 1.0));
            float spec = pow(max(dot(n, hv), 0.0), 34.0) * (0.35 + 0.65 * h2.z);
            c3 += FF_MOONC * (FF_EM * 0.045) * moon * spec * ao;
            // transmission: thin blades glow where the moon is behind them
            float thin = 0.45 + 0.55 * kk;                 // tips are thinnest
            float back = max(-dot(n, FF_L), 0.0);
            c3 += float3(0.135, 0.235, 0.088) * (FF_EM * 0.095 * moon + FF_AMB.g * 1.1)
                * thin * back * (0.35 + 0.65 * (1.0 - abs(nx))) * (0.18 + 0.82 * ao);
            // bright edge where the blade turns away — the moonlit rim of a blade
            float rim = pow(abs(nx), 4.0) * (0.30 + 0.70 * moon);
            c3 += FF_MOONC * (FF_EM * 0.022) * rim * ao * (0.30 + 0.70 * ndl);
            c3 += alb * (FF_MOONC * (0.016 + 0.052 * moon) + FF_AMB * 0.62) * ao * ao;
            c3 += alb * ff_flyLight(P, n, fp4);
            float a = c * (1.0 - cov);
            acc += a * c3; cov += a;
        }
    }
    if (cov > 0.0) bcol = acc / cov;
    return cov;
}

// shading of the grass canopy / forest floor
inline float3 ff_groundShade(float3 P, float3 rd, float s, float fp, float t, thread float4 *fp4) {
    float2 xz = P.xz;
    float cov = ff_cover(xz);
    float det  = ff_detOf(fp);
    float fade = ff_fadeG(s);
    float fadS = ff_fadeS(s);
    // canopy normal by finite difference at the pixel's own footprint
    float e = max(0.045, fp * 2.2);
    float h0 = ff_grassH(xz, t, 0.0, fade, fadS);
    float hx = ff_grassH(xz + float2(e, 0.0), t, 0.0, fade, fadS);
    float hz = ff_grassH(xz + float2(0.0, e), t, 0.0, fade, fadS);
    float3 n = normalize(float3(-(hx - h0) / e, 1.0, -(hz - h0) / e));
    // per-clump blade orientation, hue and dryness
    float4 ch = hash24(floor(xz * 3.1) + 0.5);
    float ang = ch.x * TAU + 0.9 * gnoise(xz * 0.8);
    float2 bd = float2(cos(ang), sin(ang));
    float sheen = 0.0;
    float bt = ff_bladeTex(xz, bd, fp, t, sheen);
    float2 nrm = float2(-bd.y, bd.x);
    n = normalize(n + float3(nrm.x, 0.0, nrm.y) * bt * 0.22 * fade
                    + float3(0.0, 0.05 * abs(bt), 0.0));

    // --- litter / soil showing through thin cover
    float litter = 0.38 + 0.62 * fbm(xz * 4.5, 4);
    litter *= 1.0 - 0.34 * det * smoothstep(0.40, 0.88, ridged(xz * float2(23.0, 9.0) + 4.0, 2));
    litter *= 0.88 + 0.24 * det * fbm(xz * 13.0 + 21.0, 2);
    float twig = smoothstep(0.66, 0.86, ridged(xz * 2.2 + 13.0, 2));
    float clod = 0.62 + 0.38 * fbm(xz * 1.4 + 7.0, 3);
    litter *= 1.0 - 0.45 * twig;
    float moss = smoothstep(0.08, 0.52, fbm(xz * 0.55 + 3.0, 2));
    float3 floorAlb = mix(float3(0.088, 0.066, 0.045), float3(0.058, 0.094, 0.041), moss)
                    * litter * clod;
    // --- grass albedo: green through to late-summer straw, per clump
    float dry = ch.y * ch.y * ch.y;
    float3 gAlb = mix(float3(0.0460, 0.0655, 0.0345), float3(0.0810, 0.0730, 0.0430), dry);
    gAlb *= 0.68 + 0.46 * (0.5 + 0.5 * bt);
    gAlb *= 0.82 + 0.36 * (0.5 + 0.5 * gnoise(xz * 1.35 + 5.0));
    // stubble: band-limited speckle standing in for blades the pixel cannot
    // resolve individually — this is what stops the sward reading as a dune
    float fs1 = 1.0 - smoothstep(0.006, 0.030, fp);
    float fs2 = 1.0 - smoothstep(0.0018, 0.0090, fp);
    float stub = 0.62 * fs1 * gnoise(xz * float2(37.0, 22.0) + float2(3.0, 8.0))
               + 0.44 * fs2 * gnoise(xz * float2(95.0, 58.0) + float2(11.0, 2.0))
               + 0.30 * fs1 * gnoise((xz + float2(0.3, -0.2)) * float2(19.0, 61.0));
    float3 alb = mix(floorAlb, gAlb, smoothstep(0.04, 0.42, cov));
    alb *= max(1.0 + 0.62 * stub, 0.04);          // stubble and litter grain alike
    // clod / tussock micro relief on the normal, at the pixel's own scale
    float eN = max(0.016, fp * 2.0);
    float c0 = fbm(xz * 7.5, 3), cx2 = fbm((xz + float2(eN, 0.0)) * 7.5, 3),
          cz2 = fbm((xz + float2(0.0, eN)) * 7.5, 3);
    float mic = (1.0 - smoothstep(0.010, 0.048, fp)) * 0.030;
    n = normalize(n - float3((cx2 - c0) / eN, 0.0, (cz2 - c0) / eN) * mic
                    + float3(nrm.x, 0.0, nrm.y) * stub * 0.34 * fade);

    float mn = ff_moon(P);
    float ndl = max(dot(n, FF_L), 0.0);
    // tussock AO: troughs between clumps see less of the glowing fog dome
    float ao = 0.18 + 0.82 * smoothstep(-0.10, 0.34, h0 - ff_soilH(xz) * fadS);
    ao *= 0.62 + 0.38 * (0.5 + 0.5 * bt) * (1.0 + 0.5 * stub);
    float3 col = alb * FF_MOONC * (FF_EM * 0.66) * mn * ndl;
    // anisotropic blade sheen — the silvery streak a moonlit lawn actually has
    col += FF_MOONC * (FF_EM * 0.020) * mn * sheen * (0.25 + 0.75 * ndl) * fade * cov;
    // back-lit transmission through the blades toward the camera
    float bk = smoothstep(0.10, 0.95, dot(rd, FF_L));
    col += float3(0.150, 0.230, 0.095) * (FF_EM * 0.045 * mn + FF_AMB.g * 1.2)
         * bk * cov * (0.35 + 0.65 * fade);
    // sky / fog dome
    float3 dome = FF_MOONC * (0.022 + 0.075 * mn) + FF_AMB * 0.78;
    col += alb * dome * ao;
    col += alb * ff_flyLight(P, n, fp4);
    return col;
}

// ---------------------------------------------------------------- sky
inline float3 ff_sky(float3 rd, float t) {
    float3 sky = float3(0.010, 0.020, 0.048) * (1.0 + 0.7 * max(rd.y, 0.0));
    float c = dot(rd, FF_L);
    sky += FF_MOONC * 0.035 * pow(max(c, 0.0), 5.0);
    float2 sp = float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0))) * 14.0;
    sky += ws_stars(sp, 6.0, t, 0.22) * 0.45;
    return sky;
}

// ================================================================= scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float t = fract(ctx.t);
    float2 res = ctx.res;
    float3 ro = FF_RO;
    float3 fwd = float3(0.0, sin(FF_PITCH * DEG), -cos(FF_PITCH * DEG));
    float3 rd = ws_camRay(fragCoord, res, ro, ro + fwd, FF_FOV);
    float3 right = float3(1.0, 0.0, 0.0);
    float3 up = cross(right, fwd);
    float k = tan(FF_FOV * DEG * 0.5);
    float pixAng = 2.0 * k / res.y;
    float rscale = res.y / 1600.0;
    float jit = hash12(fragCoord + float2(0.37, 1.91));
    float phase = 0.62 * ff_hg(dot(rd, FF_L), 0.55) + 0.38 / (4.0 * PI);

    // ---- fireflies (positions, projections)
    float4 fP[72];   // world pos, brightness
    float4 fS[72];   // pixel x, y, bokeh radius, flux
    for (int i = 0; i < FF_NFF; i++) {
        FFly f = ff_fly(i, t);
        fP[i] = float4(f.pos, f.bright);
        float3 v = f.pos - ro;
        float d = dot(v, fwd);
        float2 sp = float2(dot(v, right), dot(v, up)) / (d * k);
        float2 px = (sp * res.y + res) * 0.5;
        float R = max(2.05 * rscale, FF_APER * rscale * abs(1.0 / d - 1.0 / FF_FOCUS) * 2.3);
        float flux = FF_FFP * f.bright / pow(d, 1.75) * rscale * rscale;
        flux *= 0.17 + 0.83 * smoothstep(0.6, 3.8, d);   // keep near bokeh soft, not blown
        float2 nuv = px / res;
        flux *= 1.0 - 0.80 * smoothstep(0.66, 0.96, nuv.y);          // calm menu-bar strip
        flux *= 1.0 - 0.55 * smoothstep(0.56, 0.86, nuv.x)           // calm icon corner
                    * smoothstep(0.42, 0.78, nuv.y);
        fS[i] = float4(px, R, flux);
    }

    float3 col = float3(0.0);
    float T = 1.0;
    float sPrev = 0.0, zPrev = 0.0;
    float sG = ff_groundHit(ro, rd, t, pixAng);      // grass canopy hit
    bool done = false;

    for (int kx = 0; kx < FF_NROW && !done; kx++) {
        float Z = FF_Z[kx];
        float s = Z / max(-rd.z, 1e-4);
        // ground before this plane?
        if (sG < s) {
            ff_fogSeg(col, T, ro, rd, sPrev, sG, t, jit, phase);
            for (int i = 0; i < FF_NFF; i++) {
                float D = -fP[i].z;
                if (D > zPrev && D <= sG * (-rd.z) && fP[i].w > 0.001)
                    col += T * ff_glow(fragCoord - fS[i].xy, fS[i].z, fS[i].w, ff_flyCol(i));
            }
            float3 G = ro + rd * sG;
            col += T * ff_groundShade(G, rd, sG, sG * pixAng, t, fP);
            T = 0.0;
            done = true;
            break;
        }
        ff_fogSeg(col, T, ro, rd, sPrev, s, t, jit, phase);
        // fireflies between the previous plane and this one
        for (int i = 0; i < FF_NFF; i++) {
            float D = -fP[i].z;
            if (D > zPrev && D <= Z && fP[i].w > 0.001)
                col += T * ff_glow(fragCoord - fS[i].xy, fS[i].z, fS[i].w, ff_flyCol(i));
        }
        sPrev = s; zPrev = Z;
        if (T < 0.004) { done = true; break; }

        float3 P = ro + rd * s;
        float fp = s * pixAng;
        // thin-lens circle of confusion at this depth, in world units at that depth
        float cocPx = FF_APER * rscale * abs(1.0 / s - 1.0 / FF_FOCUS);
        // silhouette anti-aliasing width: the circle of confusion when the
        // plane is defocused, but never less than ~2.3 px, so near-focus
        // trunk edges resolve smoothly instead of staircasing
        float fpB = fp * max(1.0 + cocPx, 2.30) * (1.0 + 0.030 * Z);
        float soft = cocPx;
        float cov = 0.0;
        float3 rc = float3(0.0);
        bool detail = Z < 12.0;

        // ---- trunks / trees
        if (P.y >= -0.05) {
            if (Z < 11.0) {
                for (int j = 0; j < 8; j++) {
                    if (FF_NEARP[j] != kx) continue;
                    float4 tr = FF_NEAR[j];
                    float cx = tr.x + tr.z * P.y;
                    float w = ff_trunkW(P.y, tr.y, tr.w);
                    float dx = P.x - cx;
                    float c = clamp(0.5 - (abs(dx) - w) / fpB, 0.0, 1.0);
                    if (c > 0.0) {
                        float nx = clamp(dx / w, -1.0, 1.0);
                        float3 sc = ff_trunkShade(P, nx, w, tr.w, fp, fP, true, soft);
                        rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                        cov = max(cov, c);
                    }
                }
            } else {
                float W = FF_W[kx];
                float ci = floor(P.x / W);
                for (int di = -1; di <= 1; di++) {
                    float cell = ci + float(di);
                    float4 h = hash24(float2(cell * 7.3 + 1.1, Z * 13.7 + 2.9));
                    // clearing mask
                    float cx = (cell + 0.5 + 1.42 * (h.x - 0.5)) * W;
                    float cw = 7.5 * smoothstep(5.0, 12.0, Z) * (1.0 - smoothstep(28.0, 60.0, Z)) + 2.5 * (1.0 - smoothstep(5.0, 12.0, Z));
                    float clr = 1.0 - smoothstep(cw * 0.6, cw * 1.4, abs(cx - 1.0));
                    if (h.y > FF_DEN[kx] * (1.0 - clr)) continue;
                    float4 h2 = hash24(float2(cell * 3.1 + 5.7, Z * 5.3 + 7.1));
                    float r0 = 0.15 + 0.46 * h.z * h.z;
                    float lean = (h.w - 0.5) * 0.06;
                    float Hb = mix(15.5, 3.0, smoothstep(20.0, 42.0, Z)) + 7.0 * h2.x;
                    float Ht = (h2.w > 0.86 ? 11.0 + 9.0 * h2.y        // a few short, suppressed trees
                                             : 20.0 + 19.0 * h2.y * h2.y);
                    float cxy = cx + lean * P.y;
                    float w = ff_firW(P.y, r0, Hb, Ht, h2, fp, W * 1.35);
                    // anti-alias the silhouette in 2D: normalise the horizontal
                    // footprint by the slope of the edge, so shallow crown and
                    // leader edges get the same softness as vertical ones
                    float dyh = max(fpB, 0.015);
                    float wU = ff_firW(P.y + dyh, r0, Hb, Ht, h2, fp, W * 1.35);
                    float sl = (w - wU) / dyh;
                    float aaw = fpB * clamp(sqrt(1.0 + sl * sl), 1.0, 9.0);
                    if (w <= -aaw) continue;
                    float dx = P.x - cxy;
                    float c = clamp(0.5 - (abs(dx) - w) / aaw, 0.0, 1.0);
                    // feather the crown edge with needle-scale noise: a fir
                    // does not end at a line, it frays into single needles
                    if (c > 0.0 && P.y > Hb - 1.0) {
                        float ed = clamp((w - abs(dx)) / max(aaw * 2.6, 1e-4), 0.0, 1.0);
                        float nd = 0.5 + 0.5 * gnoise(float2(P.x * 26.0 + cell * 9.0,
                                                             P.y * 21.0 + cell * 4.0));
                        float nd2 = 0.5 + 0.5 * gnoise(float2(P.x * 63.0, P.y * 51.0 + cell));
                        float m = mix(clamp(nd * 1.35 + nd2 * 0.45 - 0.30, 0.0, 1.0), 1.0, ed);
                        c *= m;
                    }
                    if (c > 0.0) {
                        float nx = clamp(dx / w, -1.0, 1.0);
                        float3 sc;
                        if (detail && P.y <= Hb) {
                            sc = ff_trunkShade(P, nx, w, h.x * 10.0, fp, fP, true, soft);
                        } else {
                            // cheap far-tree shading: bole and crown share one
                            // graded material so the crown base is not a hard line
                            float mn = ff_moon(P);
                            float lat = 0.34 + 0.66 * smoothstep(0.9, -1.0, nx);   // moon on the left
                            float vg  = 0.30 + 0.70 * smoothstep(-0.8, 9.0, P.y);  // dark at the base
                            float crown = smoothstep(Hb - 2.0, Hb + 3.0, P.y);
                            // structure: bough clumping + bark banding, faded out
                            // as the row shrinks so nothing shimmers
                            float dt = 1.0 - smoothstep(0.018, 0.085, fp);
                            float bn = fbm(float2(P.y * 0.85 + cell * 6.1,
                                                  nx * 1.9 + cell * 2.3), 3);
                            float bk = gnoise(float2(P.y * 5.5 + cell * 17.0, nx * 4.0 + cell));
                            float tx = 0.80 + 0.46 * bn * (0.45 + 0.55 * dt)
                                     + 0.15 * bk * dt * (1.0 - crown);
                            // limbs catch the moon on their upper faces
                            float lit = 1.0 + 0.55 * crown * dt
                                      * smoothstep(0.15, 0.85, bn) * smoothstep(0.1, 0.9, mn);
                            float3 balb = mix(float3(0.128, 0.108, 0.086),
                                              float3(0.052, 0.072, 0.044), crown);
                            // bough clusters: the upper faces catch the moon,
                            // the undersides stay in their own shadow
                            float bough = smoothstep(-0.25, 0.60, fbm(float2(P.y * 1.9 + cell * 3.7,
                                                                             nx * 2.6 + cell * 1.1), 3));
                            float selfSh = 0.30 + 0.70 * bough;
                            sc = balb * tx * (FF_AMB * (0.95 + 0.7 * vg) * (0.55 + 0.45 * bough)
                                 + FF_MOONC * (FF_EM * 0.34) * mn * lat * vg * lit * selfSh);
                            // needles transmit a little of the moon behind the crown
                            sc += float3(0.020, 0.030, 0.018) * crown
                                * (FF_EM * 0.055 * mn + FF_AMB.g * 1.4) * (0.35 + 0.65 * bough);
                            // aerial perspective: distant rows lose saturation and
                            // contrast and pick up a cool haze veil
                            float aer = smoothstep(11.0, 78.0, Z);
                            float lum = ws_luma(sc);
                            sc = mix(sc, float3(lum) * float3(0.84, 0.97, 1.16), 0.58 * aer);
                            sc = mix(sc, float3(lum), 0.22 * aer);
                            sc += FF_MOONC * FF_AMB.b * 0.95 * aer * (0.5 + 0.5 * mn);
                        }
                        rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                        cov = max(cov, c);
                    }
                }
            }
        }
        // ---- undergrowth (ferns / grass)
        if (Z < 34.0 && P.y < 1.8 && P.y > -0.4 && cov < 0.999) {
            float Wu = 0.82 + 0.058 * Z;
            float ci = floor(P.x / Wu);
            for (int di = -2; di <= 2; di++) {
                float cell = ci + float(di);
                for (int sb = 0; sb < 2; sb++) {
                float sc2 = cell * 2.0 + float(sb);
                float4 h = hash24(float2(sc2 * 11.3 + 0.7, Z * 3.7 + 19.1));
                if (h.w < 0.74) continue;
                float bx = (cell + 0.25 + 0.5 * float(sb) + 0.34 * (h.y - 0.5)) * Wu;
                float by = -0.34 + 0.52 * h.z * h.z;
                float size = (0.20 + 1.15 * h.x * h.x * h.x) * mix(1.0, 1.20, smoothstep(2.4, 22.0, Z));
                size = min(size, 1.30 * Wu);        // must stay inside the scanned cells
                float2 d = float2(P.x - bx, P.y - by);
                if (abs(d.x) > size * 1.50 || d.y > size * 1.55 || d.y < -0.12) continue;
                float det = 1.0 - smoothstep(0.0040, 0.0165, fp);
                float sd = ff_plantD(d, hash24(float2(sc2 * 5.1 + 3.3, Z * 7.9 + 1.7)), size, det);
                float c = clamp(0.5 - sd / (fpB * 2.1), 0.0, 1.0);
                if (c > 0.0) {
                    float mn = ff_moon(P);
                    // every frond sits at its own angle to the light: without
                    // this a fern is a flat black stamp
                    float lv = fbm(float2(P.x * 7.0 + cell, P.y * 7.0 + Z * 3.0), 3);
                    float lf = fbm(float2(P.x * 31.0 + cell * 3.0, P.y * 27.0), 2);
                    float up = 0.45 + 0.55 * smoothstep(-0.6, 0.7, lv);
                    float tilt = (h.x - 0.5) * 1.3 + 0.55 * lv;
                    float3 n = normalize(float3(0.42 * lv + 0.30 * lf, 0.26 + 0.60 * up,
                                                (h.y < 0.42 ? -1.0 : 1.0) * (0.42 + 0.44 * abs(tilt))));
                    // fronds vary from fresh green to tired olive
                    float3 palb = mix(float3(0.0345, 0.0515, 0.0250), float3(0.0480, 0.0430, 0.0225),
                                      h.z * h.z);
                    palb *= (0.55 + 0.80 * up) * (0.80 + 0.40 * lf);
                    palb *= 1.0 - 0.30 * smoothstep(6.0, 20.0, Z);
                    float ndl = max(dot(n, FF_L), 0.0);
                    float3 sc = palb * (FF_MOONC * FF_EM * 0.26 * mn * ndl
                                        + FF_AMB * (0.55 + 0.75 * up) + ff_flyLight(P, n, fP));
                    // a fern leaflet is one cell thick: it glows when the moon
                    // or the lit mist is behind it
                    float back = max(-dot(n, FF_L), 0.0);
                    float edge = 1.0 - smoothstep(0.0, 3.6 * fpB, -sd);
                    sc += float3(0.060, 0.100, 0.048) * (FF_EM * 0.150 * mn + FF_AMB.g * 2.6)
                        * (0.26 + 0.74 * back) * (0.22 + 0.78 * edge)
                        * (1.0 - 0.60 * smoothstep(5.0, 18.0, Z));
                    // pale midrib catching the light along the rachis
                    sc += FF_MOONC * (FF_EM * 0.018) * mn * smoothstep(0.55, 0.95, lf) * ndl;
                    rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                    cov = max(cov, c);
                }
                }
            }
        }
        // ---- grass blades
        if (Z < 32.0 && P.y < 1.15 && P.y > -0.45 && cov < 0.999) {
            float3 bc = float3(0.0);
            float bcv = ff_blades(P, Z, fp, fpB, t, bc, fP);
            if (bcv > cov) { rc = bc; cov = bcv; }
        }
        if (cov > 0.0) {
            col += T * cov * rc;
            T *= (1.0 - cov);
        }
    }
    if (!done && T > 0.002) {
        ff_fogSeg(col, T, ro, rd, sPrev, 240.0, t, jit, phase);
        col += T * ff_sky(rd, t);
    }

    // ---- finish
    col *= FF_EXPO;
    float2 uv = fragCoord / res;
    col *= ws_vignette(uv, 0.24);
    col *= 1.0 - 0.26 * smoothstep(0.66, 1.0, uv.y);          // calm menu-bar strip
    col *= 1.0 - 0.17 * smoothstep(0.17, 0.0, uv.y);          // calm Dock strip
    // low-light colour: let the blue midtones breathe so the warm fireflies
    // read as the focal contrast, and let the grade drift warm/cool slowly
    float tw = fbm(uv * float2(2.3, 1.5) + 4.7, 3);
    col *= mix(float3(0.955, 0.995, 1.045), float3(1.070, 1.010, 0.935),
               smoothstep(-0.45, 0.55, tw));
    col = ws_saturate(col, 0.90);

    float3 o = ws_acesFitted(col);
    // sensor grain: fine luminance noise everywhere plus cooler chroma noise
    // lifted in the shadows, where a real low-light frame is noisiest
    float g1 = ws_grain(fragCoord, 0.0);
    float g2 = ws_grain(fragCoord + float2(53.7, 91.3), 0.0);
    float g3 = ws_grain(fragCoord + float2(117.1, 7.9), 0.0);
    float sh = 1.0 - smoothstep(0.015, 0.30, ws_luma(o));
    o += g1 * 0.0032;
    o += float3(g2, g1, g3) * float3(0.8, 0.6, 1.25) * (0.0016 + 0.0028 * sh);
    return clamp(o, 0.0, 1.0);
}
