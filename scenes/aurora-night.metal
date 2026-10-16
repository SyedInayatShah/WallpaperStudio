// =====================================================================
//  Aurora Night — aurora borealis over a frozen lake, Iceland/Norway.
//  Units: metres. y = up. Camera looks NORTH (-z); screen right = +x.
//  Internal "northing" w = -z (metres out from the camera).
//  Lake surface at y = 0.  Aurora between 95 km and 330 km.
//
//  The curtains are thin, folded, near-vertical sheets integrated over
//  altitude shells; the high-frequency ray striation is evaluated ONCE
//  per ray per curtain at a representative along-curtain coordinate
//  derived from the sheet's DISTANCE (deriving it from an altitude makes
//  the rays fan out radially; evaluating it per shell bands the sky).
//
//  The range is a raymarched heightfield with footprint-based LOD, a
//  5-tap heightfield shadow along the key direction and a cheap
//  curvature AO, so it reads as lit rock and snow rather than a veil.
// =====================================================================

constant float AN_EYE  = 1.90;        // eye height above the water
constant float AN_HB   = 95000.0;     // nominal lower border
constant float AN_HTOP = 330000.0;    // top of the red tail
constant float AN_DCAP = 1.42e6;      // geometric horizon for a 95 km object
constant float AN_HREF = 145000.0;    // altitude used for the along-curtain coordinate

inline float an_sq(float x) { return x * x; }

// Band-limited fbm.  `lam` is the BASE feature size in metres, `flt` the pixel
// footprint: octaves finer than the footprint fade to their mean instead of
// aliasing.  Gating a 3-octave fbm by its base wavelength alone — which is what
// every shading field here used to do — still leaves octaves 2 and 3 four times
// under-sampled, and on ground met near tangent that is exactly the pixel-scale
// chicken-wire speckle that filled the lower slopes.
inline float an_fbmF(float2 p, int octaves, float lam, float flt) {
    float s = 0.0, a = 0.5, n = 0.0;
    float L = max(lam, 1e-4), f = max(flt, 1e-4);
    for (int i = 0; i < octaves; i++) {
        float w = smoothstep(1.70, 3.90, L / f);
        if (w > 0.004) s += a * w * gnoise(p);
        n += a;
        p = WS_ROT2 * p * 2.02 + float2(17.1, 3.7);
        L *= 0.495; a *= 0.5;
    }
    return s / n;
}

// =====================================================================
//  AURORA
// =====================================================================

// travelling folds of a curtain (metres of northing offset)
// fd scales the short-wavelength folds.  The aerial-perspective sample runs
// the curtain at a fixed elevation, where those terms collapse into a pure
// function of azimuth — i.e. a fine vertical barcode across the landscape.
inline float an_fold(float xi, float t, float sd, float fd) {
    float k;
    k  = 58000.0 * sin(TAU * (xi / 760000.0 - t)       + sd);
    k += 27000.0 * sin(TAU * (xi / 322000.0 + t)       + sd * 2.37) * (0.30 + 0.70 * fd);
    k += 15500.0 * sin(TAU * (xi / 138000.0 - t * 2.0) + sd * 3.71) * fd;
    k +=  6300.0 * sin(TAU * (xi /  57000.0 + t * 3.0) + sd * 5.13) * fd;
    k +=  1600.0 * sin(TAU * (xi /  23000.0 - t * 3.0) + sd * 7.77) * fd;
    return k;
}

// big brightness knots travelling along the curtain (0..1)
inline float an_knots(float xi, float t, float sd) {
    float n = 0.55 * sin(TAU * (xi / 430000.0 + t)       + sd * 1.93)
            + 0.30 * sin(TAU * (xi / 186000.0 - t)       + sd * 3.31)
            + 0.20 * sin(TAU * (xi /  84000.0 + t * 2.0) + sd * 6.11);
    return smoothstep(-0.78, 0.52, n);
}

// Vertical ray striation (0..1).  A bank of sines at fixed wavelengths
// reads as a picket fence, so the coordinate is domain-warped first and
// the structure itself is noise, with a slow envelope that makes some
// stretches of curtain dense with filaments and others smooth.
inline float an_rays(float xi, float t, float sd) {
    float w1 = gnoiseLoop(float2(xi * 0.0000098, sd *  3.0), t, 1);
    float w2 = gnoiseLoop(float2(xi * 0.0000510, sd *  5.0), t, 2);
    float x  = xi + 12500.0 * w1 + 2900.0 * w2;

    // Real rays are FINE — hundreds of filaments across a curtain, not a
    // dozen slabs.  Wavelengths here are ~3.4 km / 1.2 km / 0.42 km at the
    // reference altitude, i.e. roughly 20 / 7 / 2.5 px on a 2560-wide frame.
    float n1 = gnoiseLoop(float2(x * 0.000295, sd *  9.0), t, 2);
    float n2 = gnoiseLoop(float2(x * 0.000840, sd * 13.0), t, 3);
    float n3 = gnoiseLoop(float2(x * 0.002400, sd * 21.0), t, 4);

    float dens = 0.5 + 0.5 * w1;                       // filament density envelope
    float r = 0.5 + 0.38 * n1 + 0.30 * n2 + 0.19 * n3 * (0.35 + 0.65 * dens);
    // a gentler exponent: the old one clipped the field into hard bars
    float e = mix(1.05, 1.95, dens * dens);
    return pow(clamp(r, 0.0, 1.0), e) * (0.70 + 0.52 * dens);
}

struct AnCurt { float w0; float slope; float lean; float amp; float sd; float sig; };

inline AnCurt an_curtain(int i) {
    AnCurt c;
    if (i == 0) {            // main curtain: high on the left, sinking right
        c.w0 = 232000.0; c.slope = 0.26; c.lean = 0.020; c.amp = 1.00; c.sd = 0.90; c.sig = 2400.0;
    } else if (i == 1) {     // second drape, further and softer
        c.w0 = 520000.0; c.slope = 0.34; c.lean = 0.014; c.amp = 0.34; c.sd = 4.31; c.sig = 5200.0;
    } else {                 // distant low band just above the range
        c.w0 = 830000.0; c.slope = -0.10; c.lean = 0.008; c.amp = 0.30; c.sd = 8.13; c.sig = 8000.0;
    }
    return c;
}

// where the curtain fades across the frame (composition control)
// xi spans roughly -0.7*w0 .. +1.0*w0 across the frame (left .. right)
inline float an_env(float xi, float t, float sd, float w0) {
    float u = xi / w0;                                   // -0.75 (left) .. 1.05 (right)
    float e = 0.025 + 1.10 * an_knots(xi, t, sd);
    e *= mix(1.0, 0.030, smoothstep(-0.30, 0.42, u));    // quiet toward screen right
    e *= mix(0.42, 1.0, smoothstep(-1.15, -0.18, u));    // and let it run off the left edge
    return e;
}

inline float3 an_aurora(float3 ro, float3 rd, float t, int NL, float rayAmt = 1.0) {
    const float3 CGRN = float3(0.095, 1.000, 0.505);   // 557.7 nm OI
    const float3 CMAG = float3(1.000, 0.255, 0.470);   // 630.0 nm OI + N2 (magenta lean)
    const float3 CVIO = float3(0.400, 0.250, 1.000);   // 427.8 nm N2+
    float3 acc = float3(0.0);
    if (rd.y < 0.004) return acc;
    float invY = 1.0 / rd.y;
    float fd = 0.06 + 0.94 * rayAmt;
    // Curtains disappear over the geometric horizon, but the cut must be soft:
    // a hard one leaves a horizontal seam across the sky and, through the
    // aerial perspective, across the mountains too.
    float horiz = smoothstep(0.036, 0.155, rd.y);
    if (horiz <= 0.0) return acc;

    for (int ci = 0; ci < 3; ci++) {
        AnCurt c = an_curtain(ci);

        // One representative along-curtain coordinate for the whole ray.
        // It must come from the sheet's DISTANCE (not an altitude), otherwise
        // xi becomes constant along image-radial lines and the vertical rays
        // fan out like a sunburst instead of standing upright.
        float denom = (-rd.z) - c.slope * rd.x;
        if (denom < 0.06) continue;
        float dref = c.w0 / denom;
        if (dref <= 0.0 || dref > AN_DCAP * 1.6) continue;
        float xiR = dref * rd.x + c.lean * (AN_HREF - AN_HB);
        float env = an_env(xiR, t, c.sd, c.w0) * c.amp;
        if (env < 0.004) continue;
        float ray  = mix(0.46, an_rays(xiR, t, c.sd), rayAmt);
        // lateral dispersion: the long-wavelength emission sits a hair off
        float rayR = mix(0.46, an_rays(xiR + 520.0, t, c.sd), rayAmt);
        // The LOWER BORDER is its own thing.  Driving it with the ray noise
        // (as an earlier build did) hangs a row of icicles under the curtain;
        // a real border rolls smoothly over 5-50 km and stays sharp.
        float hb  = AN_HB + 5200.0 * gnoiseLoop(float2(xiR * 0.0000118, c.sd), t, 1)
                          + rayAmt * 2400.0 * gnoiseLoop(float2(xiR * 0.0000560, c.sd + 4.0), t, 2)
                          + rayAmt * 1050.0 * gnoiseLoop(float2(xiR * 0.0001900, c.sd + 9.0), t, 3);

        // STRATIFIED SHELL OFFSET.  A fixed ladder of altitude shells lays a
        // faint horizontal plaid over the brightest part of the curtain — the
        // integration step showing through.  Offsetting the ladder by a
        // per-pixel fraction of one step turns that band structure into a
        // fixed-pattern dither: it is a function of the ray only, so it is
        // identical every frame (no flicker, and free in an inter-coded
        // stream) and the 2x2 supersample averages most of it away.
        float jit = fract(hash12(floor(rd.xy * 4300.0) + float(ci) * 37.0));
        float gA = 0.0, gR = 0.0, rA = 0.0, vA = 0.0;
        float prevF = 1e9, prevH = AN_HB;
        float sigH = c.sig * 3.6;

        for (int j = 0; j < NL; j++) {
            float f = min((float(j) + jit) / float(NL - 1), 1.0);
            float h = AN_HB + (AN_HTOP - AN_HB) * pow(f, 1.62);
            float d = (h - ro.y) * invY;
            if (d > AN_DCAP * 1.9) break;
            float3 p = ro + rd * d;
            float xi = p.x + c.lean * (h - AN_HB);
            float F = (-p.z) - (c.w0 + c.slope * xi + an_fold(xi, t, c.sd, fd));
            float dF = abs(F - prevF); prevF = F;
            float dh = h - prevH; prevH = h;
            if (j == 0) continue;
            if (abs(F) > sigH * 3.5 + dF) continue;

            float sig = sqrt(c.sig * c.sig + an_sq(0.5 * dF));
            float dens = (c.sig / sig) * exp(-0.5 * an_sq(F / sig));
            float sg2 = sqrt(sigH * sigH + an_sq(0.5 * dF));
            float halo = (sigH / sg2) * exp(-0.5 * an_sq(F / sg2)) * 0.040;
            float wgt = (dens + halo) * dh * invY * exp(-pow(d / AN_DCAP, 5.0));
            if (wgt < 1e-3) continue;

            float u = h - hb;
            // The border is sharp, but not a hard step: a razor edge between a
            // bright curtain and a black sky is exactly what an inter-coded
            // 10-bit stream blocks on, and the stair-stepping is visible at 1:1.
            float edge = smoothstep(-4600.0, 10200.0, u);
            float gw = wgt * edge * exp(-max(u - 14000.0, 0.0) / 30000.0);
            gA += gw;
            // The striation lives in the lower third of the green column and
            // washes out with altitude — that gradient is what makes the
            // curtain read as a sheet of rays instead of a barcode.
            gR += gw * exp(-max(u, 0.0) / 24000.0);
            rA += wgt * smoothstep(66000.0, 170000.0, u) * exp(-max(u - 140000.0, 0.0) / 78000.0);
            vA += wgt * edge * exp(-max(u, 0.0) / 6000.0);
        }
        // fade the curtains out toward the zenith so the menu-bar strip
        // and the icon corner stay quiet
        float k = env * 1.12e-4 * horiz * mix(1.0, 0.245, smoothstep(0.20, 0.58, rd.y));
        acc += CGRN * ((gA * 0.20 + gR * (0.05 + 0.74 * ray)) * k)
             + CMAG * (rA * (0.34 + 0.48 * rayR) * k) * 0.25
             + CVIO * (vA * (0.35 + 0.65 * ray) * k) * 0.070;
    }
    return acc;
}

// =====================================================================
//  STARS — a bright layer with halo and faint diffraction flare, plus
//  the dense faint field.  Long exposures never render stars as clean
//  uniform dots; size, colour temperature and bloom all vary.
// =====================================================================
inline float3 an_brightStars(float2 sp, float t) {
    float3 col = float3(0.0);
    for (int layer = 0; layer < 2; layer++) {
        float sc = 11.0 * (1.0 + float(layer) * 2.35);
        float2 q = sp * sc + float(layer) * 23.71;
        float2 id = floor(q);
        float2 f = q - id - 0.5;
        float4 h = hash24(id + float(layer) * 57.0);
        if (h.x > 0.17) continue;
        float2 dv = f - (h.yz - 0.5) * 0.80;
        float d = length(dv);
        float mag = pow(h.w, 3.6);
        float size = 0.019 + 0.030 * mag;
        float core  = exp(-d * d / (size * size * 0.26));
        float halo  = exp(-d / (size * 3.1));
        float spike = exp(-abs(dv.x) / (size * 5.2)) * exp(-an_sq(dv.y / (size * 0.40)))
                    + exp(-abs(dv.y) / (size * 5.2)) * exp(-an_sq(dv.x / (size * 0.40)));
        float tw = 0.80 + 0.20 * sin(TAU * (t * (1.0 + floor(h.y * 3.0)) + h.z));
        float3 tint = mix(float3(1.00, 0.80, 0.64), float3(0.66, 0.78, 1.00),
                          smoothstep(0.04, 0.96, h.z));
        col += tint * (core + 0.085 * halo + 0.075 * spike * mag) * (0.22 + 3.2 * mag) * tw;
    }
    return col;
}

// =====================================================================
//  NIGHT SKY — stars, faint milky way, airglow
// =====================================================================
// Smooth part of the night sky: gradient, Milky Way, low airglow.  Kept
// separate from the point sources because the aerial-perspective haze has to
// sample the sky at a FIXED elevation — and a star field sampled that way is
// constant down every screen column, i.e. a barcode painted over the range.
inline float3 an_airglow(float3 rd, float t, float mwAmt) {
    float el = asin(clamp(rd.y, -1.0, 1.0));
    float az = atan2(rd.x, -rd.z);
    float2 sp = float2(az * cos(el), el);

    float3 base = mix(float3(0.0062, 0.0102, 0.0182),
                      float3(0.0012, 0.0020, 0.0046),
                      smoothstep(0.0, 0.46, rd.y));
    base += float3(0.0028, 0.0048, 0.0064) * exp(-max(rd.y, 0.0) * 24.0);

    // faint milky way band, high and to the right
    float2 mw = float2(sp.x * 0.74 + sp.y * 0.67, -sp.x * 0.67 + sp.y * 0.74) - float2(0.46, 0.30);
    float band = exp(-an_sq(mw.y / 0.28));
    float mwn = fbm(mw * float2(2.2, 5.0) + 11.0, 4);
    float mwd = smoothstep(-0.25, 0.58, mwn);
    base += float3(0.0108, 0.0114, 0.0172) * band * (0.32 + 0.68 * mwd)
          * smoothstep(-0.02, 0.24, rd.y) * mwAmt;

    // Aurora beyond the geometric horizon (a curtain at 95 km disappears past
    // ~1150 km).  Its scattered light still fills the sky right down to the
    // horizon, and without it distant ridges fade into a dark band.
    float low = exp(-an_sq((rd.y - 0.034) / 0.098)) * smoothstep(-0.030, 0.018, rd.y);
    float lowT = 0.52 + 0.48 * (0.62 * sin(TAU * (t + 0.21) + rd.x * 1.7)
                              + 0.38 * sin(TAU * (2.0 * t) + rd.x * 3.9 + 2.1));
    float lowX = mix(1.0, 0.40, smoothstep(-0.30, 0.85, rd.x));
    base += float3(0.0330, 0.1120, 0.0640) * low * lowT * lowX;
    base += float3(0.0210, 0.0086, 0.0148) * low * low * lowT * lowX;   // magenta lift
    return base;
}

inline float3 an_nightsky(float3 rd, float t) {
    float el = asin(clamp(rd.y, -1.0, 1.0));
    float az = atan2(rd.x, -rd.z);
    float2 sp = float2(az * cos(el), el);
    float3 col = an_airglow(rd, t, 1.0);
    float ext = smoothstep(-0.010, 0.105, rd.y);
    // transverse chromatic aberration on the point sources — the one lens
    // artefact that is unmistakable in a real wide-angle night frame
    const float CA = 0.0022;
    float3 s0 = an_brightStars(sp * (1.0 - CA), t);
    float3 s1 = an_brightStars(sp, t);
    float3 s2 = an_brightStars(sp * (1.0 + CA), t);
    col += float3(s0.r, s1.g, s2.b) * 0.60 * ext;
    col += ws_stars(sp * 1.91 + 5.7, 45.0, t, 0.22) * 0.20 * ext;
    return col;
}

inline float3 an_sky(float3 ro, float3 rd, float t, int NL) {
    return an_nightsky(rd, t) + an_aurora(ro, rd, t, NL);
}

// global aurora pulse used to modulate the ground lighting (loop-safe)
inline float an_pulse(float t) {
    return 0.72 + 0.28 * (0.55 * sin(TAU * t + 1.1) + 0.45 * sin(TAU * (2.0 * t) + 3.4));
}
inline float3 an_skyLight(float t) { return float3(0.0215, 0.0760, 0.0540) * an_pulse(t); }
// The bright fold of the curtain stands high and to the LEFT, and — like the
// sheet overhead — a good part of it hangs on the camera's side of the range.
// Putting the key purely behind the peaks (as an earlier build did) leaves
// every face the camera can see completely unlit, so the massif collapses
// into one flat dark mass.  Key: up-left and slightly toward the viewer.
// Fill: the far side of the sheet, which rims the crests from behind.
inline float3 an_keyDir()  { return normalize(float3(-0.44, 0.84, 0.32)); }
inline float3 an_fillDir() { return normalize(float3( 0.54, 0.74, -0.40)); }

// A low gibbous moon over the camera's left shoulder.  The aurora is an
// enormous DIFFUSE overhead source: lit by it alone, a snowfield has no
// highlight-to-shadow falloff at all, which is exactly why the range read as a
// glowing sheet of green silk rather than photographed snow.  Nearly every
// real aurora frame that shows snow texture is moonlit — the moon supplies the
// single coherent direction, the cast shadows that separate one spur from the
// next, and a neutral highlight that keeps the massif out of the curtain's
// own hue family.  22 deg elevation: long shadows, strong lateral modelling.
inline float3 an_moonDir() { return normalize(float3(-0.72, 0.40, 0.57)); }
// Moonlight is very slightly warm of neutral relative to the 557 nm curtain.
// Keeping a neutral highlight in the snow is what stops the massif sitting
// inside the aurora's own hue family.
constant float3 AN_MOON = float3(0.1520, 0.1520, 0.1745);

// =====================================================================
//  TERRAIN — snow range across the lake.  q = (x, w) metres.
// =====================================================================
inline float an_amp(float w) {
    float a =  760.0 * smoothstep(13600.0, 17800.0, w)
           + 2050.0 * smoothstep(17000.0, 26500.0, w)
           -  560.0 * smoothstep(33000.0, 45000.0, w);
    // the valley floor used to have an amplitude of ~0, which is what made the
    // band under the range a dead, textureless plane
    return max(a, 190.0 * smoothstep(13150.0, 14100.0, w));
}

// flt = horizontal filter width in metres (pixel footprint along the ray).
// Detail finer than flt is faded out, otherwise grazing slopes alias badly.
inline float an_height(float2 q, float flt) {
    if (q.y < 13100.0) return 0.0;
    // The range does not run parallel to the shore: it swings away to the
    // north-east, so the right-hand end stands 10 km further off, lower in
    // the frame and deeper in aerial perspective.  One wall of rock at a
    // constant distance is what makes a heightfield read as a backdrop.
    q.y -= 9000.0 * smoothstep(-2000.0, 17000.0, q.x);
    float f1 = smoothstep(1500.0,  420.0, flt);
    float f2 = smoothstep( 520.0,  130.0, flt);
    float f3 = smoothstep( 200.0,   42.0, flt);
    float f4 = smoothstep(  85.0,   22.0, flt);
    float f5 = smoothstep(  40.0,   11.0, flt);
    float f6 = smoothstep(  17.0,    4.5, flt);
    // Anisotropic domain: the field varies faster with NORTHING than with
    // easting, so massifs elongate across the frame and their spurs run down
    // toward the camera.  An isotropic ridged field is exactly what produces
    // the crumpled-foil / brain-coral look this range used to have.
    float2 p = q * float2(0.000112, 0.000216);
    // Wavelength sets the SLOPE: at a fixed amplitude, halving the primary
    // wavelength doubles the face angle.  The old 10 km ridges over 1.6 km of
    // relief were 18 deg hills, which is why the range read as a snowdrift.
    float r1 = ridged(p * 1.05 + float2(4.2, 1.1), 3);
    // a harder exponent: sharp crests over flat-bottomed basins, not lumps
    r1 = pow(r1, 1.55) * 1.80;
    float r2 = ridged(p * 2.80 + float2(17.0, 6.3), 3);
    float lobe = 0.24 + 0.98 * (0.5 + 0.5 * gnoise(p * 0.34 + float2(8.1, 3.3)));
    // range envelope: ~40 km along the strike, so the skyline has a dominant
    // massif and real saddles instead of a row of equal teeth
    float renv = 0.34 + 0.92 * (0.5 + 0.5 * gnoise(float2(q.x * 0.0000262, 2.7)))
                     * (0.66 + 0.52 * (0.5 + 0.5 * gnoise(float2(q.x * 0.0000765, 9.4))));
    // A range is a HIERARCHY — one or two dominant summits, deep saddles,
    // subordinate tops.  Without this envelope the ridged field puts out a
    // row of equal teeth, which reads as a crown, not as mountains.
    renv *= 0.40 + 1.15 * pow(0.5 + 0.5 * gnoise(float2(q.x * 0.0000425, 11.3)), 2.10);
    // the range sinks away toward screen right, so the frame opens out there
    // instead of running a bright ridge straight into the icon corner
    renv *= mix(1.0, 0.34, smoothstep(2500.0, 17500.0, q.x));

    // rising valley floor — broken across x so the front is never a straight
    // silhouette, and steep enough that the eye never grazes it
    float xv = 0.45 + 0.95 * (0.5 + 0.5 * gnoise(float2(q.x * 0.000075, 7.3)));
    // The range rises STEEPLY out of the water.  A long gentle ramp from the
    // shoreline is seen almost edge-on from lake level, and every small rise
    // on it becomes a kilometres-long vertical occlusion edge — the frame
    // fills with hanging vertical streaks that no amount of filtering fixes.
    // Rise and run.  The whole massif has to climb over ~10 km of northing,
    // not 1 km: a heightfield front steeper than about 35 deg presents a
    // near-vertical wall to a camera at lake level, and a vertical face in a
    // heightfield is a vertical extrusion of one contour — every pixel column
    // on it is a streak, which no filtering or shading can repair.
    float base = 860.0 * smoothstep(13300.0, 16800.0, q.y) * xv
               + 980.0 * smoothstep(17500.0, 25000.0, q.y);
    float h = base + an_amp(q.y) * renv * lobe * (r1 * 1.05 + 0.20 * r2 * r2 * f1);
    float hBase = h;   // smooth massif, before spurs — used by the snow fill

    // Foothills between the shoreline and the range.  Without them the ground
    // from 13-16 km is one grazing ramp — a fifth of the frame with no
    // silhouette and no shadow.  Overlapping ridges give it depth.
    float fh = smoothstep(13600.0, 15800.0, q.y) * smoothstep(24000.0, 18000.0, q.y);
    if (fh > 0.002) {
        // NOTE the aspect: these lower slopes fill the whole lower half of
        // the range, and from a camera at lake level a feature stretched
        // along northing projects to a dead-vertical line.  Stretch them
        // ACROSS the strike instead, the way a real foothill ridge runs.
        float fr = ridged(float2(q.x * 0.000230, q.y * 0.000330) + 51.0, 4);
        float fr2 = ridged(float2(q.x * 0.00088, q.y * 0.00132) + 83.0, 3);
        h += fh * (335.0 * pow(fr, 1.35) + 96.0 * pow(fr2, 1.30) * f1);
    }

    // hero massif, left of centre
    float2 k = (q - float2(-5400.0, 21500.0)) * float2(0.000094, 0.0000540);
    // AMPLITUDE vs WAVELENGTH is what sets the face angle, and a heightfield
    // has to stay under about 55 deg or its front faces become vertical
    // extrusions of one contour — the "torn sail" shreds that hang off a crest
    // and that no shading or LOD can repair.  3.5 km of relief modulated at a
    // 1.9 km wavelength was far past that; the modulation now runs long.
    h += 3520.0 * exp(-dot(k, k)) * (0.46 + 0.78 * ridged(p * 1.70 + 3.0, 3));
    float2 ks = (q - float2(-4900.0, 21000.0)) * float2(0.000230, 0.000135);
    h += 1180.0 * exp(-dot(ks, ks)) * (0.46 + 0.76 * ridged(p * 3.6 + 9.0, 3));
    // lower shoulder, right of centre
    float2 k2 = (q - float2(12500.0, 30000.0)) * float2(0.0000600, 0.0000380);
    h += 820.0 * exp(-dot(k2, k2)) * (0.46 + 0.68 * ridged(p * 3.4 + 5.0, 2));

    // Spur ridges.  Every scale below the massif is stretched ~3:1 along
    // northing, so the relief resolves into long buttresses and gullies
    // running down toward the water rather than closed isotropic blobs.
    float det = 0.0;
    float2 pa = float2(q.x * 0.00046, q.y * 0.000560);
    float s2 = ridged(pa + float2(2.0, 0.7), 3);
    det += an_amp(q.y) * renv * 0.300 * (pow(s2, 1.82) - 0.15) * f2;
    float2 pb = float2(q.x * 0.00134, q.y * 0.001630);
    float s3 = ridged(pb + float2(4.0, 8.2), 3);
    det += an_amp(q.y) * renv * 0.150 * (pow(s3, 1.78) - 0.17) * f3;

    // couloirs: deep, narrow gullies cut straight down the faces
    float gul = ridged(float2(q.x * 0.00235, q.y * 0.00255) + 77.0, 3);
    det -= an_amp(q.y) * renv * 0.040 * pow(gul, 1.45) * f3;

    float2 pc = float2(q.x * 0.00470, q.y * 0.00575);
    float s4 = ridged(pc + float2(8.0, 2.4), 3);
    det += an_amp(q.y) * renv * 0.046 * (pow(s4, 1.50) - 0.19) * f4;
    // wind sastrugi — snow relief stretched ACROSS the slope (lee waves)
    float sas = (f5 > 0.003) ? fbm(float2(q.x * 0.0021, q.y * 0.0205) + 61.0, 3) : 0.0;
    det += an_amp(q.y) * renv * 0.0230 * sas * f5;
    if (f6 > 0.003) {   // rock ribs, ~20 m, still elongated down-slope
        det += an_amp(q.y) * renv * 0.0052 * fbm(float2(q.x * 0.052, q.y * 0.026) + 13.0, 3) * f6;
    }

    // SNOW FILL: wind-packed snow drowns the spur relief wherever the smooth
    // massif is not already steep, and leaves it on the faces.  A 1.4 km
    // finite difference of the SMOOTH field is a cheap steepness proxy.
    // It must touch ONLY this detail term — damping the massif with it
    // flattens the whole range into a field of ice blocks.
    float hbx = an_amp(q.y) * renv * lobe * 1.05 * 1.85
              * pow(ridged(float2((q.x + 1400.0) * 0.000112, q.y * 0.000216) * 1.05
                           + float2(4.2, 1.1), 3), 1.55);
    float steep = smoothstep(80.0, 600.0, abs(hbx - (hBase - base)));
    // The front slopes carry less relief than the crests: it keeps the face
    // the camera sees below the angle at which a heightfield degenerates.
    det *= 0.38 + 0.62 * smoothstep(15500.0, 21000.0, q.y);
    h += det * (0.30 + 0.70 * steep);

    // A second range 35-55 km out, showing through the saddles under heavy
    // aerial perspective.  One silhouette across the whole frame reads as a
    // painted backdrop; two layers give the landscape real depth.
    float farb = smoothstep(30500.0, 36000.0, q.y) * smoothstep(60000.0, 45000.0, q.y);
    if (farb > 0.002) {
        float fr = ridged(float2(q.x * 0.0000415, q.y * 0.0000905) + 131.0, 4);
        h += farb * 2750.0 * pow(fr, 1.55)
           * (0.28 + 0.92 * (0.5 + 0.5 * gnoise(float2(q.x * 0.0000188, 5.5))));
    }

    h *= smoothstep(13150.0, 13700.0, q.y);
    return max(h, 0.0);
}

inline float an_fw(float t, float3 rd, float px) {      // footprint width, metres
    return clamp(px * t / max(abs(rd.y), 0.300), px * t, 380.0);
}

inline float an_march(float3 ro, float3 rd, thread float3 &pos, float px) {
    // these two caps must clear the tallest peak by a margin: a too-tight one
    // slices the hero massif off at a constant elevation angle, leaving a
    // perfectly flat, perfectly horizontal mesa top
    if (rd.y > 0.42) return -1.0;
    float tmin = 13150.0;
    float tmax = min(62000.0, rd.y > 0.0004 ? (7000.0 - ro.y) / rd.y : 62000.0);
    if (tmax <= tmin) return -1.0;
    float lt = tmin, t = tmin;
    for (int i = 0; i < 230; i++) {
        float3 p = ro + rd * t;
        float fw = max(an_fw(t, rd, px), 72.0);
        float h = p.y - an_height(float2(p.x, -p.z), fw);
        if (h < 0.0) {
            // bisect the bracket against the real field — linear interpolation
            // alone terraces badly on grazing slopes
            float a = lt, b = t;
            for (int k = 0; k < 6; k++) {
                float m = 0.5 * (a + b);
                float3 q = ro + rd * m;
                float hm = q.y - an_height(float2(q.x, -q.z), max(an_fw(m, rd, px), 46.0));
                if (hm < 0.0) b = m; else a = m;
            }
            float tt = 0.5 * (a + b);
            pos = ro + rd * tt;
            return tt;
        }
        lt = t;
        // step with the LOD footprint: the field carries no detail below it
        t += max(h * 0.58, fw * 0.32) + 16.0;
        if (t > tmax) break;
    }
    return -1.0;
}

// Normal, curvature AO and the true shading filter width.
// The march has to use a conservative footprint (it assumes the surface may
// be near-horizontal), but a mountain FACE seen close to perpendicular has a
// far smaller footprint than that — filtering it at the march width is what
// turned the range into smooth wax.  So: take a coarse normal, work out how
// obliquely the ray meets it, and re-evaluate the field at that width.
inline float3 an_relief(float3 p, float3 rd, float flt, float px, float dist,
                        thread float &ao, thread float &fltS, thread float &gz) {
    float2 q = float2(p.x, -p.z);
    float e0  = clamp(flt * 0.55, 2.0, 900.0);
    float h0  = an_height(q, flt);
    float hx0 = an_height(q + float2(e0, 0.0), flt);
    float hz0 = an_height(q + float2(0.0, e0), flt);
    float3 n0 = normalize(float3(-(hx0 - h0) / e0, 1.0, (hz0 - h0) / e0));

    gz = abs(dot(n0, rd));
    // TRUE footprint.  One pixel projected onto a surface met at incidence
    // angle a covers px*dist/|n.rd| of ground — on the apron in front of this
    // range that is 500-2000 m, not the 43 m the marching LOD assumed.  The old
    // clamp (0.20, and an upper bound of the march filter) under-filtered the
    // field by more than an order of magnitude, and because the undersampling
    // runs along NORTHING — which projects to almost nothing in screen y while
    // easting projects normally — every alias came out as a vertical streak
    // hanging off the ridge.  That, not the shadows or the material, was the
    // drip artefact; the filter simply has to be allowed to open up.
    fltS = clamp(px * dist / clamp(gz, 0.014, 1.0), px * dist * 0.8, 2400.0);
    float e  = clamp(fltS * 0.55, 1.0, 1500.0);
    float h  = an_height(q, fltS);
    float hx = an_height(q + float2(e, 0.0), fltS);
    float hz = an_height(q + float2(0.0, e), fltS);
    float3 n = normalize(float3(-(hx - h) / e, 1.0, (hz - h) / e));

    float R  = max(e * 8.0, 100.0);
    float fR = max(fltS, R * 0.42);
    float a1 = an_height(q + float2( R, 0.0), fR);
    float a2 = an_height(q + float2(-R, 0.0), fR);
    float a3 = an_height(q + float2(0.0,  R), fR);
    float a4 = an_height(q + float2(0.0, -R), fR);
    float curv = (a1 + a2 + a3 + a4) * 0.25 - h;      // > 0 => sitting in a hollow
    ao = clamp(1.0 - max(curv, 0.0) / (0.42 * R), 0.46, 1.0);
    return n;
}

// heightfield shadow: walk toward the light, widening the LOD filter
inline float an_shadow(float3 p, float3 L, float flt, int taps) {
    float2 dir = float2(L.x, -L.z);
    float hl = length(dir);
    if (hl < 1e-3) return 1.0;
    dir /= hl;
    float slope = L.y / hl;
    float2 q = float2(p.x, -p.z);
    float s = 1.0;
    float d = max(flt * 1.3, 70.0);
    for (int i = 0; i < taps; i++) {
        // A WIDE penumbra is not a stylistic choice here.  The lower slopes of
        // the range are met within a few degrees of tangent, so one screen
        // column spans kilometres of ground: a crisp shadow edge there is
        // stretched into a kilometre-long vertical streak.  Softening the test
        // (and filtering the occluder at the step scale) turns those streaks
        // back into the broad tonal modelling a real slope shows.
        float hh = an_height(q + dir * d, max(flt, d * 0.62));
        s = min(s, 1.0 - clamp((hh - (p.y + slope * d)) / (0.48 * d), 0.0, 1.0));
        d *= 2.7;
    }
    return clamp(s, 0.0, 1.0);
}

// Haze colour for aerial perspective.  The curtain light scattered into a
// near-horizontal path comes from the whole curtain overhead, NOT from the
// sky at the ray's own elevation — sampling the latter drags the aurora's
// geometric-horizon fade into the terrain and lays a horizontal dark ledge
// across the range.  So the aurora term is always sampled well above the
// horizon and is therefore free of any elevation-dependent step.
inline float3 an_haze(float3 rd, float t) {
    float3 ro = float3(0.0, AN_EYE, 0.0);
    float3 lo = an_airglow(normalize(float3(rd.x, max(rd.y, 0.030), rd.z)), t, 0.0);
    // The curtain term must be SMOOTH in azimuth.  Running the real model at a
    // pinned elevation turns every structure it has — rays, folds, the lower
    // border — into a pure function of screen x, i.e. a barcode printed down
    // the range, the fog and the lake.  So: sample the curtain once, in one
    // fixed direction, and give it only a broad lateral falloff toward the
    // quiet side of the frame.
    float3 hi = an_aurora(ro, normalize(float3(-0.18, 0.34, -1.0)), t, 6, 0.0);
    float lat = mix(1.30, 0.42, smoothstep(-0.60, 0.70, rd.x));
    return lo + hi * 0.52 * lat + float3(0.0034, 0.0104, 0.0092) * an_pulse(t);
}

// Meso relief for the shading normal: snow flutes and rock ribs at ~190 m
// and ~55 m, both stretched ~3:1 down-slope.  A 2 km massif seen at 13 m/px
// carries no marched detail at these scales, and without them every face
// shades like poured wax.
inline float an_meso(float2 q, float a1, float a2, float flt) {
    float v = 0.0;
    if (a1 > 0.003) v += a1 * an_fbmF(float2(q.x * 0.00480, q.y * 0.00430) +  5.0, 3, 210.0, flt);
    if (a2 > 0.003) v += a2 * an_fbmF(float2(q.x * 0.01660, q.y * 0.01490) + 21.0, 3,  62.0, flt);
    return v;
}

inline float3 an_shadeLand(float3 p, float3 rd, float t, float dist, float px, bool near, float2 fc) {
    float fltM = an_fw(dist, rd, px);
    float ao = 1.0, flt = fltM, gz = 1.0;
    float3 n = an_relief(p, rd, fltM, px, dist, ao, flt, gz);
    float slope = 1.0 - n.y;
    // Distant ground carries less visible texture — LOD and the air between.
    // Without this the low ridge at the far right keeps full-strength relief
    // on almost no underlying shape and reads as a bank of whipped meringue.
    float dfade = mix(1.0, 0.20, smoothstep(18000.0, 31000.0, dist));
    // GRAZING GATE.  The lower two thirds of a range seen from lake level are
    // met almost edge-on: one screen column covers kilometres of ground, so
    // any texture that is not faded out there is smeared into a long vertical
    // streak.  Every noise field below is filtered by the pixel footprint,
    // but the footprint alone does not know about incidence — this does.
    float graze = smoothstep(0.045, 0.235, gz) * dfade;

    // BEDDING — the fix for the one artefact that survived every previous pass.
    // A heightfield's material is a function of (x, northing) only.  Where a
    // face approaches vertical, a whole column of pixels reads very nearly the
    // SAME (x, northing): the texture is extruded straight down and the face
    // fills with long smears hanging off the ridge.  No filter, LOD or normal
    // trick can repair that — the texture has no coordinate to vary along.
    // Real rock has one, and it is the obvious one: faces are BEDDED, and
    // bedding is a function of ALTITUDE.  Keying the material to p.y kills the
    // extrusion and, in the same stroke, puts strata on the faces — the "jagged
    // irregular rock structure" a photograph at this framing would show.
    float bedF = smoothstep(900.0, 120.0, flt) * graze;
    float bed  = mix(0.5, an_fbmF(float2((p.x - p.z * 0.42) * 0.00105, p.y * 0.00760) + 71.0, 3, 900.0, flt),
                     bedF);
    float bed2 = mix(0.5, an_fbmF(float2((p.x * 0.55 + p.z * 0.83) * 0.00330, p.y * 0.00420) + 19.0, 3, 300.0, flt),
                     smoothstep(520.0, 80.0, flt) * graze);
    float rough = mix(0.5, an_fbmF(float2(p.x, -p.z) * 0.00042, 3, 2380.0, flt), 0.30 + 0.70 * graze);
    rough = clamp(rough + 0.30 * (bed2 - 0.5), 0.0, 1.0);
    float patch = an_fbmF(float2(p.x, -p.z) * 0.0038 + 19.0, 3, 263.0, flt) * graze;
    float fdet  = smoothstep(150.0, 30.0, flt);
    float fine  = an_fbmF(float2(p.x, -p.z) * 0.0105, 3, 95.0, flt) * fdet * graze;
    float mesoK = smoothstep(0.035, 0.330, 1.0 - n.y);
    float mf1 = smoothstep(460.0, 95.0, flt) * (0.22 + 0.92 * mesoK) * graze;
    float mf2 = smoothstep(160.0, 32.0, flt) * 0.38 * (0.12 + 1.00 * mesoK) * graze;
    float mf  = max(mf1, mf2);
    // The meso normal must be differenced over AT LEAST the pixel footprint.
    // A sub-footprint difference manufactures a normal field finer than the
    // sampling rate, and a specular lobe on it aliases into pixel speckle no
    // matter how well the underlying height field is band-limited.
    float ex = clamp(flt * 2.10, 9.0, 260.0);
    // Sheared by altitude for the same reason: an unsheared meso field is
    // constant down a steep face and its normal perturbation smears with it.
    float2 qm = float2(p.x + 0.62 * p.y, -p.z + 1.45 * p.y);
    float m0 = an_meso(qm, mf1, mf2, flt);
    float micro = m0;
    // Snow does not cling to a 45 deg face.  Letting it cover everything is
    // what turns a range into a sheet of wax; the dark rock on the steeps is
    // what carves the faces apart and gives the massif its structure.
    // Snow lies on the gentle ground and blows off the steeps.  The band has to
    // be TIGHT: a wide one leaves a continuous grey ramp from rock to snow, and
    // a ramp shades like poured wax.  A hard-ish break is what makes a face
    // read as facets of dark rock with snow caught on the ledges.
    float snow = smoothstep(0.73, 0.20, slope + 0.30 * rough + 0.20 * fine
                                 + 0.42 * (m0 - 0.5 * mf)
                                 + 0.40 * (bed - 0.5) + 0.22 * (bed2 - 0.5))
               * smoothstep(-60.0, 110.0, p.y + 180.0 * rough);
    snow = clamp(snow + 0.20 * smoothstep(1700.0, 3000.0, p.y) * smoothstep(0.60, 0.20, slope), 0.0, 1.0);
    // Rock has to be a real MID TONE, not near-black.  At 0.015 the steeps were
    // simply holes, so the range had two values — glowing snow and void — and a
    // two-value object reads as a cut-out ribbon, never as sculpted terrain.
    float3 rock = mix(float3(0.0330, 0.0318, 0.0352), float3(0.0870, 0.0790, 0.0690),
                      clamp(rough * 0.55 + 0.35 * fine + 0.22 * patch + 0.70 * bed, 0.0, 1.0));
    float scour = an_fbmF(float2(p.x * 0.0016, -p.z * 0.0050) + 5.0, 3, 200.0, flt) * graze;
    float3 alb = mix(rock, float3(0.84, 0.88, 0.96) * (0.70 + 0.44 * scour + 0.22 * patch), snow);
    alb *= 1.0 + 0.16 * patch;
    // rock ribs and scree, ~2 km scale so they survive the LOD filter
    float ribs = an_fbmF(float2(p.x * 0.00310, -p.z * 0.00245) + 31.0, 3, 323.0, flt);
    float rib = smoothstep(0.04, 0.46, ribs + 0.42 * slope)
              * smoothstep(0.24, 0.52, slope) * smoothstep(3200.0, 1500.0, p.y) * graze;
    alb = mix(alb, float3(0.0275, 0.0262, 0.0288), rib * 0.60);
    float bdet = smoothstep(700.0, 150.0, flt);
    float beltN = smoothstep(-0.20, 0.26, an_fbmF(float2(p.x * 0.0026, -p.z * 0.0016) + 21.0, 3, 385.0, flt));
    float belt = smoothstep(460.0, 110.0, p.y - 190.0 * rough) * mix(0.40, beltN, bdet)
               * smoothstep(0.52, 0.14, slope) * graze;
    alb = mix(alb, float3(0.070, 0.086, 0.072), belt * 0.62);

    float3 nMac = n;
    if (mf > 0.004) {
        float mx = an_meso(qm + float2(ex, 0.0), mf1, mf2, flt);
        float mz = an_meso(qm + float2(0.0, ex), mf1, mf2, flt);
        // a true slope: (dh/dx) with a real relief amplitude in metres
        // Amplitude also has to shrink with the footprint, or the slope the
        // difference reports grows without bound as ex opens up.
        float amp = 27.0 * (0.62 + 0.55 * snow) * smoothstep(320.0, 70.0, flt);
        n = normalize(n + float3(-(mx - m0), 0.0, (mz - m0)) * (amp / ex));
        slope = 1.0 - n.y;
    }

    // WALL GATE.  A heightfield cannot hold an overhang: wherever the field
    // approaches vertical, the visible surface degenerates into an extrusion
    // of one contour line, so every pixel column standing on it repeats the
    // same value and the face fills with hanging vertical streaks.  No amount
    // of filtering or LOD repairs that — it is the parameterisation, not the
    // sampling.  So detect the state and hand those pixels to the mist.
    // ...and it must be read off the MARCHED normal, not the meso-bumped one.
    // Degeneracy is a property of the heightfield's parameterisation; a shading
    // bump that tips the normal past vertical is not a degenerate surface.
    // Testing the bumped normal handed most of the massif's face to the fog —
    // which is precisely why the range kept reading as a soft glowing veil
    // rather than as lit snow and rock.
    float wall = smoothstep(0.42, 0.10, mix(n.y, nMac.y, 0.35));

    float3 L  = an_keyDir();
    float3 L2 = an_fillDir();
    float3 M  = an_moonDir();
    float key  = clamp(dot(n, L),  0.0, 1.0);
    float fill = clamp(dot(n, L2), 0.0, 1.0);
    float moon = clamp(dot(n, M),  0.0, 1.0);
    float sh   = an_shadow(p, L, flt, near ? 3 : 2);
    // The moon is the only light in this frame that casts a readable shadow, so
    // it gets the long walk: a 22 deg source throws a spur's shadow kilometres
    // across the next basin, and those shadows are the whole reason the massif
    // reads as solid rather than as a lit outline.
    float shM  = an_shadow(p, M, flt, near ? 5 : 3);
    float pl   = an_pulse(t);

    // green key on the crests, cooler teal fill on the faces turned to the
    // overhead sheet, blue-violet sky and starlight in the shadows
    // The aurora is an enormous overhead source: upward-facing snow is far
    // brighter than a steep face.  That gradient, not the key, is what makes
    // ridge tops read — and it keeps flanks dark without a shadow ray.
    // The aurora contribution is cut to roughly half of what it was.  At the
    // old level the green channel on snow ran to ~0.8 after exposure, i.e. the
    // range was BRIGHTER than the curtain lighting it — the unmistakable
    // signature of a self-luminous surface.  It now sits well under the sky and
    // the moon carries the value, so the snow reflects light instead of
    // emitting it.
    float3 KEY  = float3(0.0250, 0.0810, 0.0470) * pl;
    float3 FILL = float3(0.0195, 0.0605, 0.0525) * pl;
    float3 SKYA = float3(0.0126, 0.0388, 0.0330) * (0.55 + 0.45 * pl);
    float3 STAR = float3(0.0128, 0.0176, 0.0430);

    float3 lit = alb * (KEY  * key * mix(0.20, 1.0, sh)
                      + FILL * fill * ao
                      + SKYA * (0.08 + 0.92 * pow(max(n.y, 0.0), 1.35)) * ao
                      + STAR * (0.55 + 0.45 * n.y)
                      + float3(0.0052, 0.0078, 0.0205) * (1.0 - key) * ao);
    // MOONLIGHT — the modelling light.  Terminator softened a little (snow is
    // strongly forward-scattering and never has a knife-edge terminator), and
    // a cool sky bounce off the surrounding snowfield fills the shadow side so
    // it stays readable instead of going to black.
    // At grazing incidence the shading has no spatial resolution left along the
    // view direction, so any hard term must be blended toward its own mean or
    // it smears vertically.  `graze` does this for the texture; shadows need it
    // just as much.
    float shFade = smoothstep(0.075, 0.360, gz);
    sh  = mix(0.78, sh,  shFade);
    shM = mix(0.80, shM, shFade);
    float moonW = mix(0.10, 1.0, shM) * mix(0.72, 1.0, ao);
    float wrap  = clamp((dot(n, M) + 0.30) / 1.30, 0.0, 1.0);
    lit += alb * AN_MOON * (moon * moonW + 0.19 * wrap * wrap);
    // dry-snow sheen: a broad lobe that picks out wind-packed faces
    // SPECULAR LOD.  Sub-pixel normal variance must become ROUGHNESS, never a
    // sharper highlight.  A tight lobe evaluated on the meso-perturbed normal
    // was by far the loudest aliasing source in this scene: at 14 m/pixel it
    // threw a diagonal chicken-wire speckle over every slope, and it survived
    // band-limiting the underlying fields because pow(.,42) manufactures its
    // own high frequencies out of a perfectly smooth normal.  So both lobes
    // run on the MACRO normal, stay broad, and carry no fine modulation.
    float specLOD = smoothstep(420.0, 90.0, flt);
    float shine = mix(4.5, 11.0, specLOD);
    float3 H = normalize(L - rd);
    float spec = pow(clamp(dot(nMac, H), 0.0, 1.0), shine) * snow * sh * mix(0.35, 1.0, specLOD);
    lit += KEY * spec * 0.52;
    // Moon glitter on wind-crust.  A real snowfield under a low moon throws a
    // broad specular sheet, and its fine sparkle is what keeps snow from
    // reading as smooth clay.
    float3 HM = normalize(M - rd);
    float sm  = pow(clamp(dot(nMac, HM), 0.0, 1.0), shine * 1.55) * snow * mix(0.25, 1.0, shM)
              * shFade * mix(0.30, 1.0, specLOD);
    float cg = smoothstep(420.0, 70.0, flt) * graze;
    float crust = mix(0.5, 0.5 + 0.5 * an_fbmF(float2(p.x * 0.0088, -p.z * 0.0077) + 47.0, 3, 115.0, flt), cg);
    lit += AN_MOON * sm * (0.80 + 0.90 * crust * crust) * 0.40;
    // IMAGE-PLANE SPARKLE.  Wind-crust glitter is two orders of magnitude below
    // the 14 m/pixel sampling limit here, so in world space it can only alias.
    // It belongs in the image plane, where it is also temporally fixed (the
    // camera never moves) — free in an inter-coded stream and incapable of
    // flicker.  Cells are ~1.5 px so a 2x2 supersample does not average it away.
    float gsp = max(ws_grain(floor(fc * 0.70), 0.0), 0.0);
    lit += (AN_MOON * 1.30 + KEY * 0.55) * snow * gsp * gsp * gsp * gsp
         * 0.46 * mix(0.25, 1.0, shM) * smoothstep(0.10, 0.45, n.y)
         * (0.45 + 1.25 * crust * crust);
    // the snow flats at the foot of the range sit under the whole curtain, so
    // they catch far more of it than a steep face does — this is the mid tone
    // the treeline needs to read against
    lit += alb * float3(0.016, 0.046, 0.036) * pl * ao
              * smoothstep(1100.0, 60.0, p.y) * max(n.y, 0.0);
    lit *= mix(1.0, 0.80 + 0.40 * (fine * 0.5 + 0.5), fdet);
    lit *= 1.0 + 0.16 * (micro - 0.5 * mf);    // wind-crust breakup on the snow

    lit *= 1.86 * mix(0.88, 1.0, smoothstep(13200.0, 20000.0, -p.z));
    lit *= mix(1.0, 0.20, smoothstep(17000.0, 33000.0, dist));
    float fog = 1.0 - exp(-pow(dist / 30000.0, 1.30));
    fog = clamp(fog * mix(1.0, 0.46, smoothstep(0.0, 1900.0, p.y)), 0.0, 0.90);
    // The second range 35-55 km out has to sit in far more air than this, or
    // its summits read as bright fragments floating in the saddles of the
    // near one instead of as another layer of the landscape.
    fog = max(fog, smoothstep(29000.0, 47000.0, dist) * 0.90);
    // valley mist hugging the water and the foot of the range
    float mist = exp(-max(p.y, 0.0) / 760.0) * smoothstep(13200.0, 16500.0, -p.z) * 0.96;
    float3 hz = an_haze(rd, t);
    // EDGE-ON FADE.  The lower slopes of the range are met within a couple of
    // degrees of tangent: one screen column then spans kilometres of ground, so
    // a metre of bump moves the hit point hundreds of metres up or down the
    // hill and the face fills with long vertical streaks.  That is geometry,
    // not sampling — no filter fixes it.  In a real photograph those slopes are
    // simply not there: they sit under the valley inversion.  So hand every
    // near-tangent pixel to the air, which is where it belongs.
    float edgeOn = 1.0 - smoothstep(0.030, 0.150, gz);
    mist = max(mist, edgeOn * 0.52);
    // VALLEY INVERSION.  The apron between the shore and the peaks rises about
    // 14 deg over eight kilometres and is therefore seen within a few degrees
    // of tangent — the one configuration a heightfield cannot render cleanly,
    // and the source of every vertical streak hanging under the crests.  In the
    // photographs this piece is aiming at, that ground is not visible either:
    // on a calm, clear, radiatively cooling arctic night a cold-air pool fills
    // the valley to 1-1.5 km and only the peaks stand out of it.  So the
    // artefact and the reference agree — drown it.
    float invTop = 1660.0 + 560.0 * gnoise(float2(p.x * 0.000215, -p.z * 0.000128) + 3.0)
                          + 190.0 * gnoise(float2(p.x * 0.000860, -p.z * 0.000410) + 17.0);
    float inv = smoothstep(invTop, invTop - 980.0, p.y) * smoothstep(13150.0, 14600.0, -p.z);
    mist = max(mist, inv * 0.985);
    // The degenerate near-vertical faces used to be replaced by a pale blue-grey
    // stand-in, which hung a row of bright vertical DRIPS under every crest —
    // the single loudest "this is a shader" tell in the last pass.  Hand them
    // to the air instead: at the haze colour they are indistinguishable from
    // the mist already lying against the foot of the range.
    lit = mix(lit, hz * 0.34, wall * 0.94);
    mist = max(mist, wall * 0.53);
        // The inversion is lit from above by the curtain and from the side by the
    // moon; giving it a neutral component keeps the whole lower frame out of
    // the aurora's hue family, so the massif stops rhyming with the sky.
    float3 mistC = hz * 0.80 + AN_MOON * 0.082;
    // Soft billows in the bank.  Driven by the RAY, not by the hit point: a
    // world-space field on ground met near tangent moves kilometres per pixel
    // and can only speckle, while a field in ray space is smooth by
    // construction and still reads as drifting cloud.
    float bill = 0.5 + 0.5 * gnoiseLoop(float2(rd.x * 6.2, rd.y * 30.0), t, 1);
    mist *= 0.70 + 0.52 * bill;
    return mix(mix(lit, hz * 0.62, fog), mistC, clamp(mist, 0.0, 0.965));
}

// =====================================================================
//  SPRUCE BILLBOARD SHEETS — vertical planes at fixed northing.
// =====================================================================
// u is the SIGNED offset from the trunk in trunk-half-widths.
inline float an_treeProfile(float u, float v, float sd, float shp) {
    if (v < 0.0 || v > 1.0 || abs(u) > 1.7) return 0.0;
    float ex = mix(0.78, 1.70, shp);
    float taper = pow(1.0 - v, ex) * (0.13 + 0.87 * smoothstep(0.0, 0.07 + 0.14 * shp, v));
    // WHORLS.  A spruce carries its branches in rings and every ring DROOPS —
    // the tip of a whorl hangs below where it leaves the trunk.  A symmetric
    // bulge, which is what this profile used to be, stacks into a pile of
    // diamond plates: the cartoon-conifer read the panel called a stencil.
    float tiers = 12.0 + 17.0 * fract(sd * 0.41);
    float tv = v * tiers + sd * 3.1;
    float tier = fract(tv);
    float whorl = smoothstep(0.02, 0.26, tier) * (1.0 - smoothstep(0.52, 1.00, tier));
    float w = taper * (0.60 + 0.74 * whorl);
    // branch length depends on which side of the trunk it leaves
    w *= 0.86 + 0.28 * (0.5 + 0.5 * gnoise(float2(sign(u) * 3.1 + sd * 5.0, tv * 0.97)));
    w *= 0.80 + 0.40 * (0.5 + 0.5 * gnoise(float2(u * 3.4 + sd * 3.0, v * 26.0)));
    // needle-scale raggedness: without it the silhouette is a smooth vector
    // scallop, and a smooth edge at 200 px tall is unmistakably synthetic
    w *= 0.82 + 0.30 * (0.5 + 0.5 * gnoise(float2(u * 13.0 - sd * 2.0, v * 118.0)));
    w *= 0.90 + 0.18 * (0.5 + 0.5 * gnoise(float2(u * 31.0 + sd * 7.0, v * 265.0)));
    w = max(w, 0.030 * (1.0 - smoothstep(0.05, 0.55, v)));
    return (abs(u) > 1.7) ? 0.0 : w;
}

inline float an_ground(float x, float sd0) {
    return -0.30 + 0.90 * gnoise(float2(x * 0.029 + sd0, sd0 * 2.0))
                 + 0.38 * gnoise(float2(x * 0.112 + sd0, 3.0));
}

// returns (coverage, frost, rim, dimmed coverage)
inline float4 an_sheet(float x, float y, float t, int id, float px,
                       float density, float hMin, float hMax, float sway,
                       thread float &mside, thread float &clump) {
    float4 outv = float4(0.0);
    mside = 0.0; clump = 0.5;
    float sd0 = float(id) * 13.7;
    float gi = floor(x / density);
    for (int k = -2; k <= 2; k++) {
        float g = gi + float(k);
        float4 h  = hash24(float2(g, sd0));
        float4 h2 = hash24(float2(g + 0.5, sd0 + 3.0));
        if (h.w > 0.855) continue;                     // gaps and clearings
        float dep = h2.x * h2.x;                       // how far back in the band
        float cx = (g + 0.04 + 0.92 * h.x) * density;
        // a real stand is mostly young and short with a few dominant spires
        float H  = mix(hMin * 0.46, hMax * 1.16, pow(h.y, 1.75) * (0.22 + 1.05 * h.w)) * mix(1.16, 0.48, dep)
                 * (0.62 + 0.80 * (0.5 + 0.5 * gnoise(float2(cx * 0.013, sd0 * 3.0))));
        float base = an_ground(cx, sd0) - 0.55 * h.z + 0.60 * dep;
        float v = (y - base) / H;
        if (v < 0.0 || v > 1.0) continue;
        float swy = sway * H * v * v * sin(TAU * (t + h.z * 3.0 + g * 0.37));
        float du = x - cx - swy;
        float wmax = H * (0.078 + 0.190 * h2.y * h2.y);
        float w = an_treeProfile(du / max(wmax, 1e-3), v, h.x * 9.0, h2.z) * wmax;
        float aa = max(px * 1.15, 1e-4);
        float cov = smoothstep(w + aa, w - aa, abs(du));
        if (cov <= 0.0) continue;
        // Snow load sits in CLUMPS on the upper side of the branch whorls.
        // Keying it to the tier index instead drew a pale outline around every
        // whorl, which is what made the crowns read as stamped pinecones.
        float ru = abs(du) / max(w, 1e-3);
        float frost = smoothstep(0.26, 0.86, 0.5 + 0.5 * gnoise(float2(du * 3.1 + g * 5.0, v * 27.0 + h.x * 20.0)));
        frost *= 0.42 + 0.58 * smoothstep(0.02, 0.40, ru);
        frost *= 0.30 + 0.70 * smoothstep(-0.12, 0.58, gnoise(float2(du * 9.0, v * 96.0 + g)));
        // These are FROSTED spruces on a lake shore: the snow load sits along
        // the top of every branch whorl all the way up the crown, and it is what
        // turns a black stencil into a photographed tree.
        frost *= mix(1.0, 0.62, v) * 1.05;
        // aurora backlight catching the needles at the silhouette edge
        float rim = smoothstep(0.52, 1.00, ru) * (0.30 + 0.70 * v);
        // The moon is over the left shoulder, so the left flank of every crown
        // takes a cool highlight and the right flank falls away.  Without it a
        // spruce is a filled silhouette — a vector stencil, which is exactly
        // how the old treeline read.
        float ms = smoothstep(0.30, -0.95, du / max(w, 1e-3)) * (0.35 + 0.65 * v);
        float cl = 0.5 + 0.5 * gnoise(float2(du * 2.6 + g, v * 54.0 + sd0));
        cl = mix(cl, 0.5 + 0.5 * gnoise(float2(du * 9.0 - g, v * 150.0)), 0.45);
        if (cov > outv.x) { mside = ms; clump = cl; }
        outv.x = max(outv.x, cov);
        outv.y = max(outv.y, cov * frost);
        outv.z = max(outv.z, cov * rim * mix(1.0, 0.40, dep));
        outv.w = max(outv.w, cov * mix(1.0, 0.42, dep));
    }
    return outv;
}

// A continuous dark canopy mass with a ragged top — a real spruce treeline is
// a forest EDGE, not a row of separate spikes; only the tallest spires stand
// clear of it.  Without this the line reads as an EKG trace.
inline float an_canopy(float x, float y, float px, int id, float hRef) {
    float sd = float(id) * 7.9;
    float g  = an_ground(x, float(id) * 13.7);
    float c1 = 0.5 + 0.5 * gnoise(float2(x * 0.042 + sd, 1.0));
    float c2 = 0.5 + 0.5 * gnoise(float2(x * 0.155 + sd, 5.0));
    float c3 = 0.5 + 0.5 * gnoise(float2(x * 0.480 + sd, 9.0));
    float gap = smoothstep(0.06, 0.52, c1 * c2 + 0.30 * c3);   // real clearings
    float top = g + hRef * gap * (0.05 + 1.05 * c1 * c1 + 0.46 * c2 * c2 * c2 + 0.22 * c3 * c3);
    float aa = max(px * 1.0, 1e-4);
    return smoothstep(top + aa, top - aa, y);
}

inline float an_bank(float x, float y, float px, int id, float hgt) {
    float sd = float(id) * 5.1;
    float g  = an_ground(x, float(id) * 13.7);
    float k  = 0.5 + 0.5 * gnoise(float2(x * 0.019 + sd, sd));
    float top = g + hgt * (0.06 + 1.25 * k * k * k)
              + hgt * 0.40 * gnoise(float2(x * 0.145 + sd * 3.0, 7.0));
    float aa = max(px * 0.9, 1e-4);
    return smoothstep(top + aa, top - aa, y);
}

// =====================================================================
//  ABOVE-WATER RENDER (also used for the mirrored reflection ray)
// =====================================================================
inline float3 an_shore(float3 col, float3 ro, float3 rd, float t, float px);

inline float3 an_above(float3 ro, float3 rd, float t, float px, int NL, bool near, float2 fc) {
    float3 col = an_sky(ro, rd, t, NL);

    float3 hp;
    float td = an_march(ro, rd, hp, px);
    if (td > 0.0) col = an_shadeLand(hp, rd, t, td, px, near, fc);

    // Aurora-lit fog bank lying on the flats between the far shore and the
    // foot of the range.  Without it that 12 km of ground is a dead black
    // band across the middle of the frame and the range has nothing to
    // stand in front of.
    if (rd.y > -0.002) {
        float dfog = (td > 0.0) ? td : 26000.0;
        float fa = ws_fogAmount(dfog, ro, rd, 3.6e-5, 1.0 / 52.0);
        fa *= smoothstep(300.0, 3200.0, dfog);
        // banks, not a uniform wash across the whole middle of the frame
        fa *= 0.42 + 0.86 * (0.5 + 0.5 * gnoiseLoop(float2(rd.x * 5.6, rd.z * 2.2), t, 1));
        float3 fogC = an_haze(rd, t) * 1.05 + float3(0.0026, 0.0068, 0.0086) * an_pulse(t);
        col = mix(col, fogC, clamp(fa, 0.0, 0.46));
    }

    if (!near) col = an_shore(col, ro, rd, t, px * 0.30);   // mirrored shore for the lake
    return col;
}

// three shorelines: a distant hazy edge, a continuous far treeline and a
// near spruce group at the left
inline float3 an_shore(float3 col, float3 ro, float3 rd, float t, float px) {
    const int NT = 3;
    float zs[NT]   = { 1560.0, 640.0, 205.0 };
    float dens[NT] = {    6.2,   5.0,   6.4 };
    float hmn[NT]  = {    8.0,  11.5,  13.0 };
    float hmx[NT]  = {   19.0,  27.0,  32.0 };
    float bnk[NT]  = {    0.30,  0.42,  1.05 };
    float haze[NT] = {    0.62,  0.26,  0.06 };
    for (int i = 0; i < NT; i++) {
        if (rd.z >= -1e-5) continue;
        float tt = (-zs[i] - ro.z) / rd.z;
        if (tt <= 0.0) continue;
        float3 p = ro + rd * tt;
        if (p.y < -2.5 || p.y > 26.0) continue;
        float pxs = max(px * tt, (i <= 1) ? 0.055 : 0.0);
        float sway = (i == 2) ? 0.0060 : 0.0032;
        float clump = 0.56 + 1.00 * (0.5 + 0.5 * gnoise(float2(p.x * (i == 2 ? 0.022 : 0.0135), float(i) * 4.0)))
                    * (0.72 + 0.46 * (0.5 + 0.5 * gnoise(float2(p.x * 0.0031, 17.0))));
        float mside = 0.0, needleClump = 0.5;
        float4 sh = an_sheet(p.x, p.y, t, i, pxs, dens[i], hmn[i] * clump, hmx[i] * clump, sway,
                             mside, needleClump);
        float cp = an_canopy(p.x, p.y, pxs, i, hmn[i] * clump);
        float bk = an_bank(p.x, p.y, pxs, i, bnk[i]);
        float lim = (i == 2) ? smoothstep(-52.0, -96.0, p.x) : 1.0;
        sh *= lim; bk *= lim; cp *= lim;
        float cov = max(max(sh.x, cp), bk);
        if (cov <= 0.002) continue;

        float3 amb = an_skyLight(t);
        // The near treeline sits in the layer the eye checks first, so it needs
        // to be a LIT object, not a fill colour: moonlight down the left flank,
        // aurora rim through the crown edge, frost on the branch tips, and a
        // needle-clump breakup so the mass has interior structure.
        float3 mn = AN_MOON * 0.285;
        float3 needle = float3(0.058, 0.082, 0.065)
                      * (amb * 3.30 + mn * (0.55 + 3.20 * mside) + float3(0.0044, 0.0062, 0.0118));
        needle *= 0.60 + 0.80 * needleClump;
        float3 frostC = float3(0.76, 0.83, 0.90)
                      * (amb * 1.85 + mn * (0.46 + 1.70 * mside) + float3(0.0052, 0.0072, 0.0138));
        float3 snowC  = float3(0.56, 0.62, 0.70) * (amb * 0.50 + mn * 0.52 + float3(0.0020, 0.0030, 0.0064));
        float inv = 1.0 / max(sh.x, 1e-3);
        float3 tc = mix(needle, frostC, clamp(sh.y * inv * 1.40, 0.0, 1.0));
        tc *= mix(1.0, sh.w * inv, 1.0);                       // depth dimming
        tc += float3(0.060, 0.176, 0.112) * an_pulse(t) * (sh.z * inv) * 0.44;   // aurora rim
        tc += mn * (sh.z * inv) * 0.52;                                          // moon rim
        float3 bc = snowC * (0.50 + 0.50 * (0.5 + 0.5 * gnoise(float2(p.x * 1.6, p.y * 2.4))));
        float crown = 0.5 + 0.5 * gnoise(float2(p.x * 0.42, p.y * 1.30 + 4.0));
        // snow caught on the canopy top, so the far treeline is a textured mass
        // rather than one flat cut-out value
        float cfr = smoothstep(0.34, 0.90, 0.5 + 0.5 * gnoise(float2(p.x * 2.1, p.y * 3.4 + 9.0)))
                  * smoothstep(0.0, 0.9, crown);
        float3 canC = needle * (0.52 + 0.74 * crown * crown)
                    + float3(0.030, 0.088, 0.058) * an_pulse(t) * 0.030 * crown
                    + mn * 0.075 * crown * crown;
        canC = mix(canC, snowC * 0.62, cfr * 0.34);
        float3 obj = (sh.x > 0.5) ? tc : ((bk > cp) ? bc : canC);
        obj = mix(obj, an_haze(rd, t) * 0.92, haze[i]);        // aerial perspective
        col = mix(col, obj, cov);
    }
    return col;
}

// =====================================================================
//  WATER
// =====================================================================
inline float3 an_ripple(float2 q, float t, float damp, float flt) {
    float3 g = float3(0.0);
    // A handful of travelling sines alone reads as regular stripes when the
    // eye grazes the surface, so keep them modest and let loop-safe noise
    // carry most of the slope.
    const float lam[6] = { 37.0, 19.0, 11.0, 6.3, 3.6, 2.1 };
    const float spd[6] = {  1.0,  2.0,  3.0, 4.0, 6.0, 8.0 };
    const float amp[6] = { 0.0098, 0.0074, 0.0054, 0.0037, 0.0023, 0.0013 };
    const float ang[6] = { 0.28, 1.47, -0.63, 2.55, -1.88, 0.92 };
    for (int i = 0; i < 6; i++) {
        float2 d = float2(cos(ang[i]), sin(ang[i]));
        float k = TAU / lam[i];
        // let each train wander so the crests never line up into bands
        float wob = 6.4 * gnoiseLoop(q * (0.55 / lam[i]) + float2(float(i) * 7.3, 0.0), t, 1);
        float ph = dot(q, d) * k - TAU * (t * spd[i]) + wob;
        float a = amp[i] * damp * exp(-an_sq(flt / lam[i]) * 3.0);
        float c = cos(ph) * a * k * lam[i] * 0.16;
        g.x += c * d.x; g.z += c * d.y;
    }
    // broadband chop, two scales
    float f1 = exp(-an_sq(flt / 5.0) * 3.0);
    float f2 = exp(-an_sq(flt / 17.0) * 3.0);
    g.x += fbmLoop(q * 0.42, t, 3, 2) * 0.0094 * damp * f1;
    g.z += fbmLoop(q * 0.42 + float2(7.3, 2.1), t, 3, 2) * 0.0094 * damp * f1;
    g.x += fbmLoop(q * 0.115 + float2(2.7, 9.4), t, 3, 1) * 0.0255 * damp * f2;
    g.z += fbmLoop(q * 0.115 + float2(5.1, 1.8), t, 3, 1) * 0.0255 * damp * f2;
    g.x += fbmLoop(q * 0.038 + float2(8.9, 4.2), t, 3, 1) * 0.0210 * damp * f2;
    g.z += fbmLoop(q * 0.038 + float2(1.4, 6.6), t, 3, 1) * 0.0210 * damp * f2;
    // A still lake under a calm arctic night: the reflected ray may bend by
    // about a degree, no more.  At the old amplitude the mirror image was
    // displaced by a quarter of the frame and the massif came back as melted
    // wax — the loudest "CG water" tell in the piece.
    return g * 0.105;
}

// =====================================================================
inline float3 an_render(float2 fragCoord, WSCtx ctx) {
    // Loop phase, rotated so the balanced frame (the one used for the poster,
    // grabbed at 3 s of a 10 s loop) lands on the calm, green-cored moment
    // rather than on a magenta-heavy one.  fract() keeps the loop exact.
    float t = fract(ctx.t + 0.70);
    float3 ro = float3(0.0, AN_EYE, 0.0);
    float3 ta = ro + float3(0.040, 0.1180, -1.0);
    float fov = 55.0;
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, fov);
    float px = (2.0 / ctx.res.y) * tan(fov * (PI / 180.0) * 0.5);

    float3 col;
    if (rd.y < -0.0006) {
        float tw = (0.0 - ro.y) / rd.y;
        float3 wp = ro + rd * tw;
        float dist = tw;
        float damp = 1.0 / (1.0 + dist / 150.0);
        float3 grad = an_ripple(float2(wp.x, -wp.z), t, damp, px * dist / max(-rd.y, 0.004));
        float3 n = normalize(float3(-grad.x, 1.0, -grad.z));

        float3 rrd = reflect(rd, n);
        rrd.y = max(rrd.y, 0.0010);
        rrd = normalize(rrd);
        float3 mro = float3(ro.x, -ro.y, ro.z);
        // A lake reflection is never as sharp as the subject: the surface slope
        // spread smears it, and it loses the high frequencies first.
        // A 5x footprint here wiped the LOD clean off the reflected range and
        // gave the lake a melted-wax copy of the massif.  A real mirror loses
        // its high frequencies to the surface slope spread, not to a five-fold
        // loss of geometric detail.
        float3 refl = an_above(mro, rrd, t, px * 2.5, 20, false, fragCoord);

        float ci = clamp(dot(-rd, n), 0.0, 1.0);
        float F = 0.020 + 0.980 * pow(1.0 - ci, 5.0);
        float3 body = float3(0.0011, 0.0024, 0.0036) + an_skyLight(t) * 0.060;
        // the near foreground stays quiet — that is the Dock strip
        float nearK = 0.66 + 0.34 * smoothstep(60.0, 520.0, dist);
        col = refl * (0.022 + 0.978 * F) * 0.90 * nearK + body * (1.0 - F);
    } else {
        col = an_above(ro, rd, t, px, 33, true, fragCoord);
    }
    col = an_shore(col, ro, rd, t, px);

    float2 uv = fragCoord / ctx.res;
    col *= ws_vignette(uv, 0.30);
    col += float3(0.0016, 0.0028, 0.0074) * (1.0 - smoothstep(0.0, 0.18, ws_luma(col)));
    col = ws_saturate(col, mix(1.28, 0.78, smoothstep(0.09, 0.50, ws_luma(col))));
    col *= 1.62;
    col = ws_acesFitted(col);
    // sensor character: mostly fixed-pattern (free in an inter-coded loop),
    // with a small temporal component so it does not read as a texture
    // Static grain is FREE in an inter-coded stream (it is identical every
    // frame, so it costs one intra block and nothing after), and it is exactly
    // what a near-black flat region needs: without it the encoder quantises the
    // lake to a handful of levels and the macroblock grid shows up as low-level
    // flicker.  So: more fixed-pattern in the shadows, less temporal.
    float shad = 1.0 - smoothstep(0.0, 0.34, ws_luma(col));
    col += ws_grain(fragCoord, 0.0) * (0.0030 + 0.0052 * shad);
    col += ws_grain(fragCoord + 137.0, t) * 0.0013;
    return max(col, 0.0);
}

float3 scene(float2 fragCoord, WSCtx ctx) {
    return an_render(fragCoord, ctx);
}
