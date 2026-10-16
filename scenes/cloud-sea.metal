// =====================================================================
//  Cloud Sea (r1) — sunrise over an undercast, seen from a high summit.
//
//  Units: km. Camera looks along +z, +x right, y up. y = 0 is the
//  (hidden) interior of the cloud deck; deck tops sit ~0.2–1.0 km.
//  Earth curvature folded into cs_h(p) = y + r^2 / (2 Re).
//
//  Deck  : heightfield-bounded volume (multi-scale Worley domes under a
//          convection mask + 3D billow displacement + edge fraying).
//          Surface search, then short volumetric march with Beer–Lambert,
//          local light march, heightfield shadow (long soft turret
//          shadows), Wrenninge multi-scatter octaves, dual-lobe HG, powder.
//  Peaks : ridged, warped massifs, sphere-traced, soft shadows, snow.
//  Air   : ws_atmosphere at altitude, aerial perspective, low mist layer
//          hugging the deck, sun glare / soft bloom.
// =====================================================================

constant float CR_RE    = 6371.0;
constant float CR_CAMY  = 1.15;     // camera height above deck interior (km)
constant float CR_ALTM  = 3200.0;   // camera altitude for the sky model (m)
constant float CR_SIG   = 70.0;     // cloud extinction (1/km)
constant float CR_HMAX  = 1.05;     // upper bound of cloud tops
constant float CR_SUNEL = 1.6;
constant float CR_SUNAZ = 9.5;
constant float CR_EXPO  = 0.5;

// sky = single scattering + a weak high-sun term standing in for multiple scattering
inline float3 cr_sky(float3 rd, float3 L) {
    float3 Lh = normalize(float3(L.x, 0.45, L.z));
    float3 c = ws_atmosphere(rd, L, 22.0, 0.76, 1.0, 3200.0)
             + 0.06 * ws_atmosphere(rd, Lh, 22.0, 0.76, 0.3, 3200.0);
    // ozone (Chappuis band) absorption along the long twilight sun path:
    // removes the green cast of pure Rayleigh skies at low sun
    float oz = 2.6 * (1.0 - 0.5 * smoothstep(0.9, 1.0, dot(rd, L)));
    c *= exp(-float3(0.065, 0.19, 0.0085) * oz) * float3(1.12, 1.28, 1.0);
    // higher-order scattering deepens the upper sky toward blue
    c *= mix(float3(1.0), float3(0.72, 0.93, 1.5), smoothstep(0.02, 0.6, rd.y));
    return c;
}

inline float cr_h(float3 p) { return p.y + dot(p.xz, p.xz) * (0.5 / CR_RE); }

inline float cr_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
}

// smooth dome field from Worley F1 (1 at cell centre, ~0 at edges)
inline float cr_dome(float2 x) {
    float2 w = worley(x);
    float d = w.x;
    return max(0.0, 1.0 - d * d * 1.6);
}

// ------------------------------------------------------------ deck
float cr_env(float2 w);
// cloud-top height field. tower: convection mask (0..1)
inline float cr_top(float2 xz, float lod, thread float &tower) {
    float2 q = xz + 0.9 * float2(gnoise(xz * 0.13), gnoise(xz * 0.13 + 19.7));
    float reg = fbm(q * 0.055, 3);
    tower = smoothstep(0.12, 0.6, fbm(q * 0.09 + float2(3.1, 8.2), 3));
    tower *= smoothstep(3.0, 9.0, xz.y);                   // calmer sheet in the foreground
    float h = 0.26 + 0.12 * reg;
    float oro = cr_env(xz);                                 // cloud piles up against the massifs
    h += smoothstep(0.3, 0.8, oro) * (0.10 + 0.16 * max(gnoise(xz * 1.6 + 3.0), 0.0) + 0.06 * gnoise(xz * 4.5));   // cloud banked against the massifs, ragged
    float calm = 0.35 + 0.65 * smoothstep(2.0, 10.0, xz.y);
    // undulatus rolls on the sheet (soft parallel waves, perpendicular to the wind)
    float2 wd = normalize(float2(0.8, 0.35));
    float roll = sin(dot(q, wd) * 9.0 + 2.0 * gnoise(q * 0.6));
    h += 0.010 * (1.0 - tower) * roll * (0.6 + 0.4 * gnoise(q * 0.9 + 4.0));
    h += 0.035 * calm * fbm(q * 0.6 + 3.0, 3);             // irregular swells of the sheet
    h += 0.42 * tower * cr_dome(q * 0.75);
    h += 0.13 * tower * cr_dome(q * 2.1 + 5.1);
    h += lod * 0.035 * tower * cr_dome(q * 5.7 + 1.7);
    return h;
}

// density in [0,1]; H = cloud top at p.xz, lod in [0,1]
inline float cr_dens(float3 p, float H, float tower, float lod, thread float &dd) {
    float y = cr_h(p);
    float d = H - y;
    dd = d;
    if (d < -0.1) return 0.0;
    // cauliflower billows: inverted |noise| -> round lumps, creased gaps
    float3 q = p * float3(5.0, 6.5, 5.0);
    float amp = (0.6 + 2.0 * tower) * (0.55 + 0.45 * smoothstep(2.0, 7.0, p.z)) * (0.45 + 0.9 * smoothstep(-0.4, 0.5, gnoise(p.xz * 0.45 + 11.0)));
    // turrets: creased cauliflower (inverted |noise|); sheet: soft rounded (signed noise)
    float3 qw = q + 0.9 * float3(gnoise(q * 0.43 + 2.0), 0.0, gnoise(q * 0.43 + 9.0));
    float n1 = gnoise(qw), n2 = gnoise(qw * 2.6 + 3.3), n3 = gnoise(q * 6.9 + 1.1), n4 = gnoise(q * 17.0 + 4.2);
    float cb = 0.06 * (0.35 - abs(n1)) + lod * (0.04 * (0.35 - abs(n2)) + 0.022 * (0.35 - abs(n3)) + lod * 0.01 * (0.35 - abs(n4)));
    float sb = 0.013 * n1 + lod * (0.011 * n2 + 0.008 * n3 + lod * 0.005 * n4);
    float b = mix(sb, cb, smoothstep(0.0, 0.6, tower));
    d += b * amp;
    dd = d;
    float den = smoothstep(-0.002, mix(0.035, 0.009, lod), d);
    // frayed fringe
    float fr = gnoise(p * 30.0) * 0.5 + 0.5;
    den *= mix(1.0, smoothstep(0.2, 0.7, fr + d * 30.0), 0.7 * lod * smoothstep(0.02, 0.0, d));
    return den;
}

inline float cr_denAt(float3 p, float lod) {
    float tw, dd;
    float H = cr_top(p.xz, lod, tw);
    return cr_dens(p, H, tw, lod, dd);
}
// long soft shadows cast over the deck by turrets / peaks (2D heightfield march)
float cr_terr(float2 xz, int oct);
inline float cr_hfShadow(float3 p, float3 L) {
    float2 dir = normalize(L.xz);
    float tanE = L.y / length(L.xz);
    float y0 = cr_h(p);
    float s = 0.05, sh = 1.0;
    for (int i = 0; i < 15; i++) {
        float2 q = p.xz + dir * s;
        float tw;
        float H = cr_top(q, 0.0, tw);
        H = max(H, cr_terr(q, 4));
        float ry = y0 + s * tanE;
        sh = min(sh, clamp((ry - H) / (0.05 + 0.16 * s) + 0.55, 0.0, 1.0));
        s *= 1.5;
    }
    return sh;
}

// ------------------------------------------------------------ terrain
inline float cr_blob(float2 xz, float2 c, float r, float h, float asp) {
    float2 d = xz - c; d.y /= asp;
    return h * exp(-dot(d, d) / (r * r));
}

float cr_env(float2 w) {
    float e = 0.0;
    e = max(e, cr_blob(w, float2(-4.8, 15.0), 3.2, 1.00, 0.7));   // hero massif
    e = max(e, cr_blob(w, float2(-10.5, 23.0), 1.9, 0.95, 0.8));
    e = max(e, cr_blob(w, float2(-26.0, 58.0), 4.0, 0.80, 0.6));
    return e;
}

float cr_terr(float2 xz, int oct) {
    float2 w = xz + 0.7 * float2(gnoise(xz * 0.21), gnoise(xz * 0.21 + 7.7));
    float e = cr_env(w);
    if (e < 0.04) return -1.0;
    float mL = ridged(w * 0.30 + float2(1.3, 4.1), 3);
    float mS = ridged(w * 1.25 + float2(5.1, 2.2), max(oct - 1, 1));
    float h = e * (0.40 + 2.2 * mL * mL + 0.45 * mS * (0.4 + mL) * (1.0 - 0.45 * smoothstep(0.7, 1.0, e))) * (0.55 + 0.45 * e) - 0.75 + 0.5 * e * e;
    return h;
}

inline float3 cr_terrNormal(float2 xz, float eps) {
    float h0 = cr_terr(xz, 8);
    float hx = cr_terr(xz + float2(eps, 0.0), 8);
    float hz = cr_terr(xz + float2(0.0, eps), 8);
    return normalize(float3(h0 - hx, eps, h0 - hz));
}

// ------------------------------------------------------------ atmosphere helpers
inline float3 cr_sunTrans(float3 L) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6;
    float3 o = float3(0.0, Rp + CR_ALTM - 700.0, 0.0);
    float len = ws_raySphere(o, L, Ra).y;
    float st = len / 24.0, odR = 0.0, odM = 0.0;
    for (int i = 0; i < 24; i++) {
        float3 x = o + L * (st * (float(i) + 0.5));
        float hh = length(x) - Rp;
        odR += exp(-hh / 8e3) * st;
        odM += exp(-hh / 1.2e3) * st;
    }
    return exp(-(kR * odR + kM * 1.1 * odM * 1.4));
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float el = CR_SUNEL * PI / 180.0, az = CR_SUNAZ * PI / 180.0;
    float3 L = normalize(float3(sin(az) * cos(el), sin(el), cos(az) * cos(el)));

    float3 ro = float3(0.0, CR_CAMY, 0.0);
    float pitch = -3.5 * PI / 180.0;
    float3 ta = ro + float3(0.0, tan(pitch), 1.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, 40.0);
    rd.x = -rd.x;                            // camRay's right vector is -x for +z view
    float pixA = 0.73 / ctx.res.y;           // pixel angle (rad)

    float3 sunT = pow(cr_sunTrans(L), float3(0.68));   // (softened: real low-sun colour reads as gold, not red)
    float3 sunCol = sunT * 6.5;
    float3 skyUp = cr_sky(float3(0.0, 1.0, 0.0), L);
    float3 skyAnti = cr_sky(normalize(float3(-L.x, 0.25, -L.z)), L);
    float3 amb = (skyUp * 0.85 + skyAnti * 0.15) * float3(0.9, 0.97, 1.12) * 2.1;

    float mu = dot(rd, L);

    // ---------------- terrain trace
    float tT = 1e9;
    if (rd.y > -0.2) {
        float t = 2.0, tp = 2.0;
        for (int i = 0; i < 300; i++) {
            float3 p = ro + rd * t;
            float y = cr_h(p);
            if (y > 3.6 || t > 80.0) break;
            float h = cr_terr(p.xz, 8);
            float g = y - h;
            if (g < 0.0004 * t) {
                // bisection refine between the last safe point and this one
                float a = tp, b = t;
                for (int k = 0; k < 7; k++) {
                    float m = 0.5 * (a + b);
                    float3 q = ro + rd * m;
                    if (cr_h(q) - cr_terr(q.xz, 8) < 0.0) b = m; else a = m;
                }
                tT = b; break;
            }
            tp = t;
            t += max(g * 0.3, 0.0008 * t);
        }
    }

    // ---------------- cloud march
    float3 cAcc = float3(0.0);
    float Tr = 1.0;
    float tW = 0.0, wSum = 0.0;
    float tmax = min(tT, 160.0);
    if (rd.y < 0.02) {
        float t = rd.y < -0.001 ? max((CR_HMAX - CR_CAMY) / rd.y, 0.5) : 20.0;
        bool inside = false;
        float hfs = 1.0;
        bool gotShadow = false;
        for (int i = 0; i < 260; i++) {
            if (t > tmax || Tr < 0.015) break;
            float3 p = ro + rd * t;
            float y = cr_h(p);
            if (y > CR_HMAX + 0.05 && rd.y > -0.02 && i > 4 && y - CR_HMAX > 0.3) break;
            float foot = t * pixA;
            float lod = 1.0 - smoothstep(0.004, 0.03, foot);
            float tw;
            float H = cr_top(p.xz, lod, tw);
            float gap = y - H;
            if (!inside) {
                if (gap < 0.09) { inside = true; t += (hash12(fragCoord + float2(ctx.t * 97.0, t)) - 0.5) * (0.007 + 0.0028 * t); }
                else { t += max(gap * 0.8, 0.004 + 0.006 * t); continue; }
            }
            if (gap > 0.14) { inside = false; continue; }
            float dt = 0.007 + 0.0028 * t;
            float dd;
            float den = cr_dens(p, H, tw, lod, dd);
            if (den > 0.002) {
                if (!gotShadow) { hfs = cr_hfShadow(p, L); gotShadow = true; }
                float sig = CR_SIG * den;
                // light march (Beer–Lambert toward the sun)
                float od = 0.0;
                float ls = 0.025;
                float lsum = 0.0;
                for (int j = 0; j < 4; j++) {
                    float3 q = p + L * (lsum + ls * 0.5);
                    // far taps: light diffuses around/through small billows
                    od += CR_SIG * cr_denAt(q, lod * 0.5) * ls * (j < 2 ? 1.0 : (j == 2 ? 0.55 : 0.3));
                    lsum += ls; ls *= 2.2;
                }
                // multi-scatter octaves, dual-lobe phase
                float3 S = float3(0.0);
                float a = 1.0, b = 1.0, c = 1.0;
                for (int k = 0; k < 3; k++) {
                    float ph = mix(cr_hg(mu, 0.78 * c), cr_hg(mu, -0.25 * c), 0.28);
                    S += a * ph * exp(-od * b) * (k == 0 ? hfs : mix(1.0, hfs, 0.85));
                    a *= 0.5; b *= 0.55; c *= 0.5;
                }
                float powder = 1.0 - exp(-sig * 0.06);
                powder = mix(powder, 1.0, 0.5 + 0.5 * mu);
                float3 sun = sunCol * S * powder * 0.7 * PI;
                float depth = max(dd, 0.0);
                // sky occlusion from billows overhead (reveals cauliflower form in shade)
                float occ = exp(-CR_SIG * 0.035 * cr_denAt(p + float3(0.0, 0.035, 0.0) + L * 0.01, lod));
                float3 am = amb * (0.4 + 0.6 * exp(-depth * 9.0)) * (0.55 + 0.45 * occ) * (0.8 + 0.2 * exp(-max(H - y, 0.0) * 4.0));
                am += sunCol * hfs * 0.012 * exp(-depth * 8.0);            // bounce from lit tops
                float3 Sc = (sun + am);
                float e = exp(-sig * dt);
                float3 contrib = Sc * (1.0 - e) * Tr;
                cAcc += contrib;
                float w = Tr * (1.0 - e);
                tW += w * t; wSum += w;
                Tr *= e;
            }
            t += dt;
        }
    }
    float tC = wSum > 1e-4 ? tW / wSum : 1e9;

    // ---------------- background
    float3 bg;
    float tBg;
    if (tT < 1e8) {
        float3 p = ro + rd * tT;
        float3 n = cr_terrNormal(p.xz, max(0.003, tT * pixA * 1.2));
        float y = cr_h(p);
        // soft shadow toward sun
        float sh = 1.0, s = 0.02;
        for (int i = 0; i < 28; i++) {
            float3 q = p + L * s + n * 0.004;
            float g = cr_h(q) - cr_terr(q.xz, 5);
            sh = min(sh, clamp(10.0 * g / s, 0.0, 1.0));
            if (sh < 0.01) break;
            s += max(0.02, g * 0.5);
            if (s > 12.0) break;
        }
        float snowN = gnoise(p.xz * 7.0) * 0.14 + gnoise(p.xz * 25.0) * 0.06;
        float snow = smoothstep(0.30, 0.46, n.y + snowN + 0.12 * (y - 1.2)) * smoothstep(0.45, 0.9, y);
        // fine rock relief (sub-trace scale) + strata banding
        float2 bq = p.xz * 55.0;
        float3 bn = float3(gnoise(bq), 0.0, gnoise(bq + 17.0)) * 0.16 * (1.0 - smoothstep(0.004, 0.012, tT * pixA));
        float3 ng = n;
        n = normalize(n + bn);
        float strata = gnoise(float2(y * 38.0, p.x * 2.0)) * 0.5 + 0.5;
        float3 rock = mix(float3(0.06, 0.056, 0.053), float3(0.15, 0.135, 0.12), strata * (0.5 + 0.5 * gnoise(p.xz * 30.0)));
        float3 alb = mix(rock, float3(0.86, 0.88, 0.92), snow);
        float dif = max(dot(n, L), 0.0) * sh;
        float3 skyA = amb * (0.55 + 0.45 * n.y);
        float3 bounce = float3(1.0, 0.92, 0.85) * amb * 0.9 * clamp(0.5 - 0.5 * n.y, 0.0, 1.0);
        bg = alb * (sunCol * dif * 1.2 + skyA * 0.6 + bounce * 0.3);
        // rim: grazing edges toward the sun glow (snow/ice + air forward scatter)
        float nv = clamp(1.0 + dot(ng, rd), 0.0, 1.0);
        float rim = pow(nv, 5.0) * pow(max(mu, 0.0), 6.0) * (0.3 + 0.7 * sh);
        bg += sunCol * rim * (0.25 + 0.6 * snow);
        tBg = tT;
    } else {
        float3 r2 = rd;
        r2.y = max(r2.y, 0.0005);
        bg = cr_sky(normalize(r2), L);
        // refraction squashes the low sun slightly: stretch the view offset vertically
        float3 rs = normalize(float3(rd.x, L.y + (rd.y - L.y) * 1.12, rd.z));
        bg += ws_sunDisk(rs, L, 0.27, sunT * 900.0);
        tBg = 1e9;
    }

    // ---------------- aerial perspective
    float3 hz = rd; hz.y = max(hz.y, 0.012);
    float3 hazeCol = cr_sky(normalize(hz), L) * 1.05;
    // extra warm mie glow toward the sun inside the haze
    hazeCol += sunCol * 0.02 * cr_hg(mu, 0.7);

    float fBg = tBg < 1e8 ? 1.0 - exp(-tBg / 45.0) : 0.0;
    // low mist lying on the deck (density at y ~ 0.45, falling off upward)
    if (tBg < 1e8) {
        float3 p = ro + rd * tBg;
        float ym = min(cr_h(p), CR_CAMY);
        float mist = 1.3 * exp(-max(ym - 0.4, 0.0) / 0.22) * clamp(0.75 + 0.7 * gnoise(p.xz * 1.1 + 4.0), 0.2, 1.6);
        fBg = 1.0 - (1.0 - fBg) * exp(-mist * min(tBg, 25.0) * 0.08);
    }
    bg = mix(bg, mix(hazeCol, amb * 0.5, 0.45), fBg);

    float fC = 1.0 - exp(-tC / 55.0);
    float3 cloud = mix(cAcc, hazeCol * (1.0 - Tr), fC);
    float3 col = cloud + Tr * bg;

    // sun glare / soft bloom
    float ang = acos(clamp(mu, -1.0, 1.0));
    col += sunT * (40.0 * exp(-ang * 500.0) + 5.0 * exp(-ang * 160.0) + 9.0 * exp(-ang * 50.0) + 2.0 * exp(-ang * 10.0));

    col *= CR_EXPO;
    col *= ws_vignette(fragCoord / ctx.res, 0.28);        // natural lens falloff
    col = ws_acesFitted(col);
    col = max(ws_saturate(col, 1.04), 0.0);
    col += ws_grain(fragCoord, ctx.t) * 0.004;
    return col;
}
