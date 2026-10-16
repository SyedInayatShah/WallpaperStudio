// =====================================================================
//  Salt Mirror — a flooded salt flat at dusk (salar-style mirror).
//
//  Camera 1.55 m above a thin sheet of water, pitch 0 so the horizon
//  splits the frame and the sky mirrors below.  Looks down -z, +x right.
//  Ground / water are in metres, clouds & atmosphere in kilometres.
//
//  Sky   : ws_atmosphere (Rayleigh + Mie), sun 1.4 deg up, 54 deg left of view.
//  Clouds: volumetric cumulus field (2-D coverage, flat bases, domed tops,
//          3-D billow erosion), sun light-march + multi-scatter octaves,
//          sky / flat-bounce ambient, finite-segment aerial perspective.
//  Water : flat Fresnel mirror, faint anisotropic wind ripple in patches,
//          glossy micro-jitter (resolved by supersampling).
//  Crust : hex-lattice Voronoi ridges (2-4 cm) on a floor that sinks
//          slowly with distance, so ridges pierce the surface only in the
//          foreground and dissolve into the mirror further out.
// =====================================================================

constant float SM_RE    = 6371.0;   // km
constant float SM_CAMH  = 0.60;     // m
constant float SM_FOVY  = 42.0;
constant float SM_PITCH = -1.1;     // deg, slight look-down: horizon a little above centre
constant float SM_MIST  = 0.00058;   // 1/m low salt-flat haze
constant float SM_MISTH = 26.0;     // m haze layer height
constant float SM_SUNEL = 0.75;     // deg
constant float SM_SUNAZ = -84.0;   // deg, negative = left of view (behind-left: front/side-lit clouds)
constant float SM_SUNI  = 30.0;
constant float SM_MIE   = 0.24;
constant float SM_EXPO  = 1.40;
constant float SM_CBASE = 1.05;     // km cloud base
constant float SM_CTHK  = 2.75;      // km max cloud thickness
constant float SM_TMAX  = 60.0;     // km cloud march limit
constant float SM_SIG   = 30.0;     // 1/km extinction in cloud core
constant float SM_CELL  = 0.58;     // m salt polygon size

inline float3 sm_sunDir() {
    float el = SM_SUNEL * (PI / 180.0), az = SM_SUNAZ * (PI / 180.0);
    return float3(sin(az) * cos(el), sin(el), -cos(az) * cos(el));
}
inline float sm_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
}

// ------------------------------------------------------------ atmosphere
// Sunlight transmittance to altitude altKm (same constants as ws_atmosphere).
inline float3 sm_sunTrans(float altKm, float3 sd) {
    const float Rp = 6371e3, Ra = 6471e3;
    float3 p0 = float3(0.0, Rp + altKm * 1000.0 + 1.0, 0.0);
    float L = ws_raySphere(p0, sd, Ra).y;
    float odR = 0.0, odM = 0.0, tPrev = 0.0;
    for (int i = 0; i < 12; i++) {
        float u = float(i + 1) / 12.0;
        float t1 = L * u * u;
        float tm = 0.5 * (tPrev + t1);
        float h = length(p0 + sd * tm) - Rp;
        float dt = t1 - tPrev;
        odR += exp(-h / 8e3) * dt; odM += exp(-h / 1.2e3) * dt;
        tPrev = t1;
    }
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    return exp(-(kR * odR + 21e-6 * SM_MIE * 1.1 * odM));
}

// In-scattered light and transmittance along a view ray from the camera to distKm.
inline float3 sm_airlight(float3 rd, float3 sd, float distKm, thread float3& Tair) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6 * SM_MIE;
    const int N = 8, NL = 4;
    float dist = distKm * 1000.0;
    float3 r0 = float3(0.0, Rp + 2.0, 0.0);
    float mu = dot(rd, sd), mumu = mu * mu, g = 0.76, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    float3 tR = float3(0.0), tM = float3(0.0);
    float odR = 0.0, odM = 0.0, tPrev = 0.0;
    for (int i = 0; i < N; i++) {
        float u1 = float(i + 1) / float(N);
        float t1 = dist * u1 * u1;
        float tm = 0.5 * (tPrev + t1), dt = t1 - tPrev;
        tPrev = t1;
        float3 pos = r0 + rd * tm;
        float h = length(pos) - Rp;
        float dR = exp(-h / 8e3) * dt, dM = exp(-h / 1.2e3) * dt;
        odR += dR; odM += dM;
        float jl = ws_raySphere(pos, sd, Ra).y;
        float jR = 0.0, jM = 0.0, jp = 0.0;
        for (int j = 0; j < NL; j++) {
            float v1 = float(j + 1) / float(NL);
            float j1 = jl * v1 * v1;
            float jm = 0.5 * (jp + j1);
            float hj = length(pos + sd * jm) - Rp;
            jR += exp(-hj / 8e3) * (j1 - jp);
            jM += exp(-hj / 1.2e3) * (j1 - jp);
            jp = j1;
        }
        float3 att = exp(-(kR * (odR + jR) + kM * 1.1 * (odM + jM)));
        tR += dR * att; tM += dM * att;
    }
    Tair = exp(-(kR * odR + kM * 1.1 * odM));
    return SM_SUNI * (pR * kR * tR + pM * kM * tM);
}

inline float3 sm_sky(float3 rd, float3 sd) {
    float3 d = rd;
    d.y = max(d.y, 0.0006);
    d = normalize(d);
    float3 col = ws_atmosphere(d, sd, SM_SUNI, 0.76, SM_MIE, 2.0);
    // thin high cirrus veil (8 km) — upper-left, zenith and top-right kept calm
    if (d.y > 0.022) {
        float2 q = float2(d.x * 0.52, d.z) * (8.0 / d.y) * 0.055;
        float n = fbm(q + float2(0.0, 3.0), 5) + 0.35 * fbm(q * 3.1 + 9.0, 3);
        float a = smoothstep(0.12, 0.66, n);
        a *= smoothstep(0.022, 0.11, d.y) * (1.0 - smoothstep(0.50, 0.92, d.y));
        a *= mix(1.0, 0.26, smoothstep(-0.14, 0.40, d.x)) * 0.20;
        float3 lit = SM_SUNI * sm_sunTrans(8.0, sd) * (0.050 + 0.045 * sm_hg(dot(d, sd), 0.62)) + col * 0.40;
        col = mix(col, lit, a);
    }
    return col;
}

// ------------------------------------------------------------ clouds
// 2-D coverage in [0,1] and local thickness (km) at horizontal position q (km).
// Cellular: each Voronoi cell is one cumulus tower; a broad fbm mask groups them
// into clusters with clear sky between; the zenith is kept clear.
// cloud-base altitude (km) varies per cluster so the undersides are not one plane
inline float sm_cbase(float2 q) {
    return SM_CBASE + 0.30 * gnoise(q * 0.030 + 17.3) + 0.11 * gnoise(q * 0.105 + 3.7);
}

inline float sm_cov(float2 q, thread float& thick) {
    float hd = length(q);
    float w = smoothstep(3.0, 8.0, hd) * (1.0 - 0.80 * smoothstep(40.0, 62.0, hd));
    float m = fbm(q * 0.030 + float2(3.7, -1.9), 4);
    float mask = smoothstep(-0.14, 0.38, m);
    float2 W1 = worley(q * (1.0 / 2.35) + 4.1);
    float2 W2 = worley(q * (1.0 / 1.15) + 9.7);
    float2 W3 = worley(q * (1.0 / 0.55) + 21.3);
    float2 W4 = worley(q * (1.0 / 0.26) + 31.9);
    float b1 = pow(saturate(1.0 - W1.x / 0.90), 1.20);
    float b2 = pow(saturate(1.0 - W2.x / 0.80), 1.15);
    float b3 = pow(saturate(1.0 - W3.x / 0.54), 1.30);
    float b4 = pow(saturate(1.0 - W4.x / 0.30), 1.30);
    // CLUSTER field (broad, smooth) -> drives cloud DEPTH.
    float clus = mask * (0.72 * b1 + 0.40 * b2 - 0.10);
    // focal congestus bank: overlapping turrets, upper-left third
    float tow = 0.0;
    float2 a1 = q - float2(-4.40, -10.2);  tow += 0.60 * exp(-dot(a1, a1) / (2.0 * 1.05 * 1.05));
    float2 a2 = q - float2(-3.10, -11.3);  tow += 0.80 * exp(-dot(a2, a2) / (2.0 * 1.20 * 1.20));
    float2 a3 = q - float2(-1.85,  -9.9);  tow += 0.52 * exp(-dot(a3, a3) / (2.0 * 0.90 * 0.90));
    float2 a4 = q - float2(-4.05, -12.4);  tow += 0.54 * exp(-dot(a4, a4) / (2.0 * 1.00 * 1.00));
    float2 a5 = q - float2(-2.45, -12.6);  tow += 0.40 * exp(-dot(a5, a5) / (2.0 * 0.80 * 0.80));
    float2 a6 = q - float2(-5.80, -11.0);  tow += 0.36 * exp(-dot(a6, a6) / (2.0 * 1.05 * 1.05));
    float2 a7 = q - float2(-0.55, -11.0);  tow += 0.30 * exp(-dot(a7, a7) / (2.0 * 0.78 * 0.78));
    float2 fd = q - float2( 8.5, -24.0);   tow += 0.26 * exp(-dot(fd, fd) / (2.0 * 2.4 * 2.4));
    float2 fe = q - float2(-14.5, -21.0);  tow += 0.24 * exp(-dot(fe, fe) / (2.0 * 2.6 * 2.6));
    float2 ff = q - float2(  2.6, -17.5);  tow += 0.18 * exp(-dot(ff, ff) / (2.0 * 1.7 * 1.7));
    clus += 0.85 * tow;
    // coverage adds the finer bands on top of the cluster body
    float n = clus + mask * (0.24 * b3 + 0.13 * b4);
    // clear-sky corridor just above the horizon so the gold strip reads through
    float corr = 1.0 - 0.42 * smoothstep(24.0, 38.0, hd) * (1.0 - smoothstep(48.0, 60.0, hd));
    // keep the upper-right of frame calm (desktop icons live there)
    float sr = saturate(q.x / max(hd, 1.0));
    float calm = 1.0 - 0.55 * smoothstep(0.10, 0.80, sr) * (1.0 - smoothstep(16.0, 34.0, hd));
    float g = w * corr * calm;
    n *= g; clus *= g;
    float c = saturate(n);
    // depth from the BROAD cluster only: a plateau body whose crown is carved by
    // 3-D erosion, never a cone spiked at the coverage peak.
    float dep = smoothstep(0.03, 0.52, clus);
    dep = dep * dep * (3.0 - 2.0 * dep);
    thick = 0.05 + SM_CTHK * dep * (0.74 + 0.46 * gnoise(q * 0.33 + 7.0));
    return c;
}

// density in [0,1] at world position p (km); lod 0 = cheap (light march), det = fine-octave weight
inline float sm_dens(float3 p, int lod, float det) {
    float thick;
    float c = sm_cov(p.xz, thick);
    if (c < 0.12) return 0.0;
    float alt = p.y + dot(p.xz, p.xz) * (0.5 / SM_RE);
    float cb = sm_cbase(p.xz);
    float hf = (alt - cb) / thick;
    if (hf < 0.0 || hf > 1.0) return 0.0;
    float d = c - 0.11 - 0.52 * hf * hf - 0.30 * hf * hf * hf * hf;
    d *= smoothstep(0.0, 0.14, alt - cb);
    if (d <= 0.0) return 0.0;
    // CAULIFLOWER erosion.  Frequencies scale up as the local cloud gets thinner,
    // so small puffs get small-scale lobes instead of staying smooth analytic domes.
    float fs = 1.0 / max(thick, 0.35);
    float3 pp = p * float3(2.05, 1.75, 2.05) + float3(0.0, 0.0, 5.0);
    float3 pe = pp * (0.55 + 0.85 * fs);
    float b = 0.46 * gnoise(pe * 0.50 - 3.1)
            + 0.27 * gnoise(pe * 1.05)
            + 0.16 * gnoise(pe * 2.20 + 1.3);
    if (lod > 0) {
        b += 0.085 * gnoise(pe * 4.5 + 2.7);
        if (det > 0.01) b += det * 0.045 * gnoise(pe * 9.4 + 4.1);
    }
    float e = saturate(0.54 - 1.10 * b);          // carve amount, rounded lobes
    // erosion grows upward: flat wet bases, cauliflower crowns, wispy silhouette
    d -= (0.09 + 0.64 * hf * hf + 0.50 * hf) * e;
    return saturate(d * 3.4);
}
inline float sm_dens(float3 p, int lod) { return sm_dens(p, lod, 0.0); }

// Volumetric march. Returns un-fogged cloud radiance; T = transmittance,
// tMean = contribution-weighted distance (km) for aerial perspective.
inline float3 sm_clouds(float3 rd, float3 sd, float3 sunC, float3 ambSky, float3 ambGnd,
                        float2 fragCoord, thread float& T, thread float& tMean) {
    T = 1.0; tMean = 0.0;
    float3 col = float3(0.0);
    if (rd.y < 0.019) return col;
    float t0 = (SM_CBASE - 0.45) / rd.y;
    if (t0 > SM_TMAX) return col;
    float t1 = min((SM_CBASE + SM_CTHK + 0.70) / rd.y, SM_TMAX);
    float wsum = 0.0;
    float t = t0;
    float jit = hash12(fragCoord * 1.7 + 3.3);
    float mu = dot(rd, sd);
    float ph0 = 0.7 * sm_hg(mu, 0.75) + 0.3 * sm_hg(mu, -0.2);
    float ph1 = 0.7 * sm_hg(mu, 0.50) + 0.3 * sm_hg(mu, -0.1);
    float ph2 = 0.7 * sm_hg(mu, 0.25) + 0.3 * sm_hg(mu,  0.0);
    for (int i = 0; i < 240; i++) {
        if (t > t1 || T < 0.015) break;
        float ds = clamp(t * 0.0038, 0.016, 0.075);
        // jitter the SAMPLE inside the step (kills march-plane terracing at any ds)
        float3 p = rd * (t + ds * jit);
        float thick;
        float c = sm_cov(p.xz, thick);
        float alt = p.y + dot(p.xz, p.xz) * (0.5 / SM_RE);
        float cb = sm_cbase(p.xz);
        if (c < 0.14 || alt < cb - 0.02 || alt > cb + thick) { t += ds * 2.6; continue; }
        float det = smoothstep(13.0, 4.0, t);
        float d = sm_dens(p, 1, det);
        if (d < 0.004) { t += ds * 1.5; continue; }
        float hf = saturate((alt - cb) / thick);
        // light march toward the (nearly horizontal) sun
        float od = 0.0, ls = 0.055, lt = 0.028;
        for (int k = 0; k < 5; k++) { od += sm_dens(p + sd * lt, 0) * ls; lt += ls; ls *= 1.9; }
        od *= SM_SIG;
        float sunL = exp(-od) * ph0 + 0.26 * exp(-0.30 * od) * ph1 + 0.085 * exp(-0.10 * od) * ph2;
        float3 amb = ambSky * mix(0.10, 1.0, pow(hf, 1.4)) + ambGnd * mix(1.0, 0.10, sqrt(hf));
        amb *= 1.0 - 0.58 * d;
        float3 S = sunC * sunL * 1.70 + amb;
        float Ts = exp(-SM_SIG * d * ds);
        float wgt = T * (1.0 - Ts);
        col += wgt * S; wsum += wgt; tMean += wgt * t;
        T *= Ts;
        t += ds;
    }
    tMean = wsum > 0.0 ? tMean / wsum : t0;
    return col;
}

inline float3 sm_skyClouds(float3 rd, float3 sd, float3 sunC, float3 ambSky, float3 ambGnd, float2 fragCoord) {
    float3 sky = sm_sky(rd, sd);
    float T, tMean;
    float3 cl = sm_clouds(rd, sd, sunC, ambSky, ambGnd, fragCoord, T, tMean);
    if (T > 0.999) return sky;
    float3 Tair;
    float3 air = sm_airlight(rd, sd, tMean, Tair);
    return cl * Tair + air * (1.0 - T) + sky * T;
}

// ------------------------------------------------------------ salt crust
// Hex-lattice Voronoi: (F1, F2) in lattice units
inline float2 sm_hexVor(float2 q) {
    const float RH = 0.8660254;
    float2 g = float2(q.x, q.y / RH);
    float2 i = floor(g);
    float d1 = 9.0, d2 = 9.0;
    for (int dy = -1; dy <= 1; dy++)
    for (int dx = -1; dx <= 1; dx++) {
        float2 c = i + float2(dx, dy);
        float odd = fract(c.y * 0.5) * 2.0;           // 0 or 1
        float2 center = float2(c.x + 0.5 * odd + 0.5, (c.y + 0.5) * RH);
        center += (hash22(c) - 0.5) * 0.30;
        float d = length(q - center);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
    }
    return float2(d1, d2);
}

// ridge height (m) at q (m); e = edge distance, hv = local ridge amplitude
inline float sm_crust(float2 q0, thread float& e, thread float& hv) {
    // organic warp + slowly varying cell size so the lattice never reads as tiling
    float2 q = q0 + 0.46 * SM_CELL * float2(gnoise(q0 * 0.33 + 4.0), gnoise(q0 * 0.33 + 31.0))
                  + 0.17 * SM_CELL * float2(gnoise(q0 * 0.95 + 12.0), gnoise(q0 * 0.95 + 44.0))
                  + 0.06 * SM_CELL * float2(gnoise(q0 * 2.7 + 22.0), gnoise(q0 * 2.7 + 61.0));
    float sc = SM_CELL * (0.82 + 0.42 * gnoise(q0 * 0.11 + 55.0));
    float2 F = sm_hexVor(q / sc);
    e = abs(F.y - F.x + 0.05 * gnoise(q * 3.1));
    hv = 0.012 + 0.009 * gnoise(q * 0.42 + 7.0);
    float wdt = 0.048 + 0.032 * gnoise(q * 1.5 + 3.0);   // ridge width varies along the line
    float prof = exp(-e * e / (2.0 * wdt * wdt));
    prof *= smoothstep(-0.45, 0.30, gnoise(q * 0.9 + 17.0));   // some seams heal over
    // fine secondary cracks inside the polygons (thin, low)
    float2 F2 = worley(q * (2.6 / SM_CELL) + 11.0);
    float e2 = F2.y - F2.x;
    float fine = 0.0020 * exp(-e2 * e2 / (2.0 * 0.07 * 0.07))
                 * smoothstep(-0.2, 0.5, gnoise(q * 0.7 + 71.0));
    return hv * prof + fine + 0.0011 * gnoise(q * 5.0) + 0.0005 * gnoise(q * 15.0);
}
// Water sits at y = 0.  The flat sinks very slowly, so the tallest crust ridges
// pierce the sheet in the near foreground and are drowned further out.
inline float sm_floor(float2 q) {
    float e, hv;
    float dist = length(q);
    float depth = 0.0062 + 0.0105 * smoothstep(1.1, 5.5, dist) + 0.015 * smoothstep(4.5, 19.0, dist);
    float pond = 0.0038 * gnoise(q * 0.16 + 40.0) + 0.0016 * gnoise(q * 0.52 + 13.0);
    return -depth + pond + sm_crust(q, e, hv) * smoothstep(17.0, 0.7, dist);
}

// water ripple height (m) — a salt-flat sheet is nearly dead calm; only a few
// wind-brushed patches carry any texture at all.
inline float sm_ripple(float2 q) {
    float2 s = float2(q.x * 1.0, q.y * 2.6);
    float patch = smoothstep(0.10, 0.62, gnoise(q * 0.045 + 2.0));
    float gust  = smoothstep(0.02, 0.58, gnoise(q * 0.013 + 8.0));
    float a = 0.00042 * gnoise(s * 2.6) + 0.00024 * gnoise(s * 6.4 + 5.0) + 0.00011 * gnoise(s * 14.0 + 11.0);
    return patch * mix(0.12, 1.0, gust) * a;
}

// low salt-flat haze along a path of length distM (m), looking in rd
inline float sm_mist(float3 rd, float distM) {
    float d = distM;
    if (rd.y > 1e-4) d = min(d, SM_MISTH / rd.y);
    return 1.0 - exp(-d * SM_MIST);
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float k = tan(SM_FOVY * 0.5 * PI / 180.0);
    float3 rd = normalize(float3(p.x * k, p.y * k, -1.0));
    { float a = SM_PITCH * (PI / 180.0), c = cos(a), sn = sin(a);
      rd = normalize(float3(rd.x, c * rd.y + sn * rd.z, -sn * rd.y + c * rd.z)); }
    float3 ro = float3(0.0, SM_CAMH, 0.0);
    float3 sd = sm_sunDir();

    // per-pixel lighting constants
    float3 sunG = SM_SUNI * sm_sunTrans(0.002, sd);
    float3 sunC = SM_SUNI * sm_sunTrans(1.9, sd);
    float3 skyZ = ws_atmosphereFast(float3(0.0, 1.0, 0.0), sd, SM_SUNI, 0.76, 2.0);
    float3 hs = normalize(float3(sd.x, 0.0, sd.z));
    float3 skyS = ws_atmosphereFast(normalize(hs * 0.98 + float3(0.0, 0.2, 0.0)), sd, SM_SUNI, 0.76, 2.0);
    float3 skyA = ws_atmosphereFast(normalize(-hs * 0.98 + float3(0.0, 0.2, 0.0)), sd, SM_SUNI, 0.76, 2.0);
    float3 skyH = 0.5 * (skyS + skyA);
    float3 Lavg = 0.45 * skyZ + 0.55 * skyH;      // mean sky radiance
    // sky ambient skewed to the cool zenith; ground bounce skewed warm (mirror of the sunset)
    float3 ambSky = 0.30 * (0.86 * skyZ + 0.14 * skyH);
    float3 ambGnd = 0.20 * (0.45 * Lavg + 0.55 * skyS) + sunG * 0.020;

    float3 hz = normalize(float3(rd.x, 0.0, rd.z));
    float3 hazeC = ws_atmosphereFast(normalize(float3(rd.x, 0.042, rd.z)), sd, SM_SUNI, 0.72, 2.0) * 0.78
                 + Lavg * 0.22
                 + sunG * (0.010 + 0.085 * sm_hg(dot(hz, sd), 0.60));

    float3 col;
    float viewDist = 4000.0;
    if (rd.y >= 0.0) {
        col = sm_skyClouds(rd, sd, sunC, ambSky, ambGnd, fragCoord);
    } else {
        float tw = SM_CAMH / (-rd.y);              // water surface hit
        viewDist = tw;
        bool dry = false;
        float3 hp = float3(0.0);
        if (tw < 11.0) {
            float ta = (SM_CAMH - 0.035) / (-rd.y);
            float dt = (tw - ta) / 30.0;
            float tprev = ta;
            float t = ta + dt * hash12(fragCoord * 0.73 + 9.1);
            for (int i = 0; i < 30; i++) {
                float3 q = ro + rd * t;
                if (q.y < sm_floor(q.xz)) {
                    float a = tprev, b = t;
                    for (int j = 0; j < 4; j++) {
                        float m = 0.5 * (a + b);
                        float3 qm = ro + rd * m;
                        if (qm.y < sm_floor(qm.xz)) b = m; else a = m;
                    }
                    hp = ro + rd * 0.5 * (a + b);
                    dry = true;
                    break;
                }
                tprev = t; t += dt;
            }
        }
        if (dry) {
            // dry salt ridge above the water line
            float eps = 0.008;
            float2 q = hp.xz;
            float3 n = normalize(float3(sm_floor(q - float2(eps, 0.0)) - sm_floor(q + float2(eps, 0.0)), 2.0 * eps,
                                        sm_floor(q - float2(0.0, eps)) - sm_floor(q + float2(0.0, eps))));
            float3 alb = float3(0.86, 0.855, 0.835) * (0.86 + 0.14 * gnoise(q * 26.0) + 0.07 * gnoise(q * 80.0));
            float up = 0.5 + 0.5 * n.y;
            float3 Ldiff = alb * (mix(Lavg * 0.55, mix(skyH, skyZ, saturate(n.y)), up));
            float vis = smoothstep(0.0, 0.016, hp.y) * 0.78;
            float3 Lsun = alb / PI * sunG * max(dot(n, sd), 0.0) * vis;
            // damp wetness right at the water line so crests are brightest at their tips
            float wet = 1.0 - 0.34 * smoothstep(0.012, 0.0, hp.y);
            col = (Ldiff + Lsun) * wet;
        } else {
            float3 wp = ro + rd * tw;
            float2 q = wp.xz;
            // ripple normal (fades with distance) + glossy micro-jitter
            float eps = 0.012;
            float fade = smoothstep(16.0, 1.6, tw);
            float3 n = float3(0.0, 1.0, 0.0);
            if (fade > 0.0) {
                float hx = sm_ripple(q + float2(eps, 0.0)) - sm_ripple(q - float2(eps, 0.0));
                float hz = sm_ripple(q + float2(0.0, eps)) - sm_ripple(q - float2(0.0, eps));
                n = normalize(float3(-hx * fade, 2.0 * eps, -hz * fade));
            }
            float2 jit = (hash22(fragCoord * 3.1 + 17.0) - 0.5) * 0.0011 * fade;
            n = normalize(n + float3(jit.x, 0.0, jit.y));
            float cosT = saturate(-dot(rd, n));
            float F = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            float3 rr = reflect(rd, n);
            float3 refl = sm_skyClouds(rr, sd, sunC, ambSky, ambGnd, fragCoord);
            // sun glitter off the ripple facets
            float sp = pow(max(dot(rr, sd), 0.0), 700.0);
            refl += sunG * sp * 1.3 * fade;
            refl = mix(refl, hazeC, sm_mist(rr, 4000.0));

            // bottom seen through the water
            float2 qb = q;
            float wd0 = max(-sm_floor(q), 0.0);
            if (tw < 9.0) {
                float3 rt = refract(rd, n, 1.0 / 1.333);
                qb = q + rt.xz * (wd0 / max(-rt.y, 0.12));   // smooth parallax, no stepping
            }
            float e, hv;
            float r = sm_crust(qb, e, hv);
            float dep = 0.62 + 0.38 * smoothstep(-0.45, 0.45, gnoise(qb * 0.22 + 40.0));
            // salt is white; the seams are only a little duller, never black
            float3 alb = mix(float3(0.470, 0.487, 0.480), float3(0.880, 0.874, 0.848),
                             smoothstep(-0.10, 0.85, r / hv) * dep);
            alb *= 0.92 + 0.08 * gnoise(qb * 2.0) + 0.05 * gnoise(qb * 6.5) + 0.03 * gnoise(qb * 20.0);
            float3 albAvg = float3(0.700, 0.702, 0.685);
            // texture contrast dies off quickly: beyond a few metres it is pure mirror
            alb = mix(alb, albAvg, smoothstep(1.8, 7.5, tw));
            // brine absorption: a few cm of water over the crust, faint cool green
            float wdep = clamp(wd0 + 0.004, 0.002, 0.045) / max(-rd.y, 0.10);
            float3 absorb = exp(-wdep * float3(1.10, 0.48, 0.62));
            float3 Lbot = alb * absorb * (Lavg * 0.58 + skyZ * 0.26);
            col = F * refl + (1.0 - F) * Lbot;
        }
    }

    if (rd.y < 0.0) {
        float dk = min(viewDist, 40000.0) / 1000.0;
        float3 Tair;
        float3 air = sm_airlight(rd, sd, dk, Tair);
        col = col * Tair + air;
    }
    col = mix(col, hazeC, sm_mist(rd, min(viewDist, 4000.0)));

    col *= SM_EXPO;
    col = ws_acesFitted(col);
    float2 uv = fragCoord / ctx.res;
    col *= ws_vignette(uv, 0.12);
    col += ws_grain(fragCoord, ctx.t) * 0.004;
    return clamp(col, 0.0, 1.0);
}
