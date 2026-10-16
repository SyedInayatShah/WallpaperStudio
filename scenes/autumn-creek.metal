// =====================================================================
//  Autumn Creek — forest creek at peak autumn, camera low at the water.
//  Units: metres. x right, y up, z forward (upstream, toward the sun).
//  Terrain + water are two heightfields; canopy/mist are a volume.
// =====================================================================

constant float AC_STEP  = 0.30;   // rise per cascade
constant float AC_POOLK = 0.320;   // stair frequency (pools per metre)
constant float AC_TMAX  = 42.0;

struct ACLight { float3 sun; float3 sunCol; float3 amb; float3 ambSky; };

inline float3 ac_sunDir() { return normalize(float3(0.520, 0.395, 1.0)); }
inline float  ac_smax(float a, float b, float k) { float h = clamp(0.5 + 0.5*(a - b)/k, 0.0, 1.0); return mix(b, a, h) + k*h*(1.0 - h); }
inline float  ac_sq(float x) { return x*x; }
inline float  ac_hg(float mu, float g) { float gg = g*g; return (1.0 - gg) / (4.0*PI*pow(max(1.0 + gg - 2.0*g*mu, 1e-3), 1.5)); }

// ---------------------------------------------------------------- layout
inline float ac_cx(float z) { return 0.75*sin(z*0.19 + 0.4) + 0.40*sin(z*0.53 + 2.1); }
inline float ac_hw(float z) { return 1.45 + 0.55*sin(z*0.23 + 1.0) + 0.28*sin(z*0.47 + 3.3); }
inline float ac_u(float2 p)  { return p.y*AC_POOLK + 0.06 + 0.23*sin(p.x*0.52 + p.y*0.19 + 0.7) + 0.13*gnoise(p*0.42 + 2.0) + 0.045*gnoise(p*1.7); }
// per-step jitter so the cascades are not a regular staircase
inline float ac_jit(float k) { return (hash11(k*1.7 + 0.3) - 0.5)*0.62; }
inline float ac_lvl(float k) { return AC_STEP*(k + ac_jit(k)); }
inline float ac_levelApprox(float z) { return AC_STEP*(z*AC_POOLK + 0.06); }

// rounded boulders from a jittered grid, smooth-max union
inline float ac_domes(float2 p, float cell, float rmin, float rmax, float hf, float seed) {
    float2 pc = p/cell; float2 i = floor(pc); float2 f = pc - i;
    float h = 0.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 r = hash24(i + g + seed);
        float2 c = g + 0.15 + 0.7*r.xy;
        float rad = mix(rmin, rmax, r.z*r.z)/cell;
        float2 d = f - c;
        float ang = r.w*TAU; float ca = cos(ang), sa = sin(ang);
        d = float2(ca*d.x - sa*d.y, sa*d.x + ca*d.y);
        d.x *= mix(0.75, 1.4, fract(r.z*7.31));
        float dd = dot(d, d)/(rad*rad);
        if (dd < 1.0) {
            float q = sqrt(dd);
            float dome = sqrt(max(1.0 - dd*q, 0.0));
            float H = rad*cell*hf*(0.55 + 0.45*fract(r.w*5.17));
            h = ac_smax(h, H*(dome - 0.15), 0.02);
        }
    }
    return h;
}

// terrain height; `smooth` = bed + banks + boulders only (what the water sheet follows)
inline float ac_terrain2(float2 p, float detail, thread float &smooth) {
    float cx = ac_cx(p.y), hw = ac_hw(p.y);
    float xr = p.x - cx, ax = abs(xr);
    float u = ac_u(p); float k = floor(u), f = u - k;
    float l0 = ac_lvl(k), l1 = ac_lvl(k + 1.0);
    float stair = mix(l0, l1, smoothstep(0.76, 1.0, f));
    float chan = max(1.0 - ac_sq(ax/hw), 0.0);
    float basin = (0.30 + 0.32*hash11(k*3.1 + 5.0))*chan*smoothstep(0.0, 0.35, f)*(1.0 - smoothstep(0.72, 0.80, f));
    float bo = max(ax - hw, 0.0);
    float bank = 0.55*smoothstep(0.0, 1.5, bo) + 0.26*bo + 0.30*gnoise(p*0.55 + 3.0)*smoothstep(0.0, 0.5, bo)
               + 0.16*gnoise(p*1.4 + 9.0)*smoothstep(0.0, 0.8, bo);
    float h = stair - basin + bank;
    float2 w = p + 0.09*float2(gnoise(p*2.2), gnoise(p*2.2 + 7.0));
    float big = ac_domes(w, 2.30, 0.42, 1.25, 0.78, 1.0);
    float mid = ac_domes(w + 0.7, 0.86, 0.16, 0.42, 0.82, 4.0);
    h = ac_smax(h + big, h + mid, 0.10);
    smooth = h;
    if (detail > 0.0) {
        float cob = ac_domes(w, 0.26, 0.045, 0.13, 0.85, 2.0);
        h += detail*(cob + 0.012*fbm(p*16.0, 2) + 0.004*gnoise(p*55.0));
    }
    return h;
}
inline float ac_terrain(float2 p, float detail) { float s; return ac_terrain2(p, detail, s); }

// water surface height given the smooth terrain under it
inline float ac_water(float2 p, float smooth) {
    float u = ac_u(p); float k = floor(u), f = u - k;
    float l0 = ac_lvl(k), l1 = ac_lvl(k + 1.0);
    float lvl = mix(l0, l1, smoothstep(0.80, 0.97, f));
    float drop = min(smoothstep(0.74, 0.82, f) + (1.0 - smoothstep(0.0, 0.08, f)), 1.0);
    float cover = 1.0 - smoothstep(0.05, 0.14, smooth - lvl);
    float sheet = max(lvl, smooth + 0.02);
    float und = 0.003*gnoise(p*3.0 + 1.0);
    return mix(lvl + und, sheet, drop*cover);
}

inline float ac_detailAt(float t) { return 1.0 - smoothstep(6.0, 10.0, t); }

inline float ac_top(float2 p, float detail, thread float &terr, thread float &wat) {
    float sm; terr = ac_terrain2(p, detail, sm); wat = ac_water(p, sm); return max(terr, wat);
}

inline bool ac_march(float3 ro, float3 rd, float tmin, float tmax, int maxIt,
                     thread float &tHit, thread int &mat, thread float &terrO, thread float &watO) {
    float t = tmin, tp = tmin;
    for (int i = 0; i < maxIt; i++) {
        float3 P = ro + rd*t;
        float terr, wat;
        float h = ac_top(P.xz, ac_detailAt(t), terr, wat);
        float d = P.y - h;
        if (d < 0.0) {
            float ta = tp, tb = t;
            for (int j = 0; j < 5; j++) {
                float tm = 0.5*(ta + tb);
                float3 Pm = ro + rd*tm;
                float h2 = ac_top(Pm.xz, ac_detailAt(tm), terr, wat);
                if (Pm.y - h2 < 0.0) tb = tm; else ta = tm;
            }
            float3 Ph = ro + rd*tb;
            ac_top(Ph.xz, ac_detailAt(tb), terr, wat);
            tHit = tb; terrO = terr; watO = wat;
            mat = (wat > terr + 0.002) ? 2 : 1;
            return true;
        }
        tp = t;
        t += clamp(d*0.5, 0.003 + 0.004*t, 0.12 + 0.03*t);
        if (t > tmax) return false;
    }
    return false;
}

inline float3 ac_normalRock(float2 p, float t, float detail) {
    float e = max(0.0012, 0.0005*t);
    float hx = ac_terrain(p + float2(e, 0.0), detail) - ac_terrain(p - float2(e, 0.0), detail);
    float hz = ac_terrain(p + float2(0.0, e), detail) - ac_terrain(p - float2(0.0, e), detail);
    return normalize(float3(-hx, 2.0*e, -hz));
}
inline float3 ac_normalWater(float2 p, float t, float detail) {
    float e = max(0.0015, 0.0006*t);
    float s;
    ac_terrain2(p + float2(e, 0.0), detail, s); float a = ac_water(p + float2(e, 0.0), s);
    ac_terrain2(p - float2(e, 0.0), detail, s); float b = ac_water(p - float2(e, 0.0), s);
    ac_terrain2(p + float2(0.0, e), detail, s); float c = ac_water(p + float2(0.0, e), s);
    ac_terrain2(p - float2(0.0, e), detail, s); float d = ac_water(p - float2(0.0, e), s);
    return normalize(float3(-(a - b), 2.0*e, -(c - d)));
}

// ---------------------------------------------------------------- light helpers
// canopy gaps projected along the sun: shared by dappled light, water and god rays
inline float ac_gaps(float3 P) {
    float3 s = ac_sunDir();
    float3 r = normalize(cross(s, float3(0.0, 1.0, 0.0)));
    float3 u = cross(r, s);
    float2 q = float2(dot(P, r), dot(P, u));
    float n = fbm(q*0.55 + float2(3.1, 7.7), 4);
    float n2 = gnoise(q*2.6 + float2(1.0, 5.0));
    float g = smoothstep(0.04, 0.32, n + 0.25*n2 + 0.02);
    g *= 0.7 + 0.3*vnoise(q*9.0);
    float hgt = P.y - ac_levelApprox(P.z);
    g = mix(g, 1.0, smoothstep(8.0, 11.0, hgt));
    return 0.04 + 0.96*g;
}

inline float ac_shadow(float3 P, float3 Ldir, float det) {
    float sh = 1.0; float t = 0.02;
    for (int i = 0; i < 14; i++) {
        float3 Q = P + Ldir*t;
        float h = ac_terrain(Q.xz, det*(t < 0.5 ? 1.0 : 0.0));
        float d = Q.y - h;
        sh = min(sh, 10.0*d/t);
        if (sh < 0.0) break;
        t += max(0.02, t*0.5);
    }
    return clamp(sh, 0.0, 1.0);
}

inline float ac_ao(float3 P, float det) {
    float occ = 0.0;
    float rad = 0.05;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float a = float(j)*1.5708 + float(i)*0.39;
            float2 q = P.xz + float2(cos(a), sin(a))*rad;
            float h = ac_terrain(q, det*(i < 2 ? 1.0 : 0.0));
            occ += clamp((h - P.y)/rad - 0.15, 0.0, 1.0)*0.25;
        }
        rad *= 2.6;
    }
    return clamp(1.0 - occ*0.35, 0.0, 1.0);
}

inline float3 ac_envCheap(float3 P, float3 R, ACLight L) {
    float mu = dot(R, L.sun);
    float up = clamp(R.y, 0.0, 1.0);
    float3 e = L.amb*(0.9 + 1.4*up) + L.ambSky*up*0.6;
    float g = ac_gaps(P + R*2.5);
    e += L.sunCol*0.12*g*ac_hg(mu, 0.75)*smoothstep(-0.1, 0.2, R.y);
    return e;
}

// ---------------------------------------------------------------- leaves
inline float ac_leafSDF(float2 q, float kind, thread float &vein) {
    float r = length(q); float a = atan2(q.y, q.x);
    float R;
    if (kind < 0.45) {   // maple-like: 5 lobes, stem notch
        float lobe = pow(abs(cos(2.5*a)), 0.6);
        R = 0.58 + 0.42*lobe;
        R *= 1.0 - 0.18*smoothstep(0.75, 1.0, abs(a)/PI);
        vein = smoothstep(0.1, 0.0, abs(sin(2.5*a))*r)*(1.0 - smoothstep(0.3, 1.0, r/R));
        return r - R;
    } else {             // ovate, pointed tip
        float2 e = float2(q.x - 0.08, q.y*1.8);
        float re = length(e); float ae = atan2(e.y, e.x);
        float Re = 0.92*(1.0 + 0.12*cos(ae))*(1.0 - 0.10*pow(abs(sin(ae)), 3.0));
        float mid = smoothstep(0.06, 0.0, abs(e.y))*(1.0 - smoothstep(0.2, 1.0, re/Re));
        float lat = smoothstep(0.12, 0.0, abs(fract(e.x*3.0 + abs(e.y)*1.2) - 0.5))*0.5*(1.0 - smoothstep(0.6, 1.0, re/Re));
        vein = max(mid, lat);
        return (re - Re)*0.7;
    }
}

struct ACLeaf { float cover; float3 col; float3 nrm; float ring; };

inline ACLeaf ac_leafField(float2 p, float cell, float density, float seed, float3 n, float aa) {
    ACLeaf o; o.cover = 0.0; o.col = float3(0.0); o.nrm = n; o.ring = 0.0;
    float2 pc = p/cell; float2 i = floor(pc); float2 f = pc - i;
    float best = -1.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 h = hash24(i + g + seed);
        if (h.x > density) continue;
        float4 h2 = hash24(i + g + seed + 37.1);
        float2 c = g + 0.15 + 0.7*h.yz;
        float2 d = (f - c)*cell;
        float size = mix(0.035, 0.062, h.w);
        float ang = h2.x*TAU; float ca = cos(ang), sa = sin(ang);
        float2 q = float2(ca*d.x - sa*d.y, sa*d.x + ca*d.y)/size;
        if (dot(q, q) > 2.4) continue;
        float vein; float sd = ac_leafSDF(q, h2.y, vein);
        float a = aa/size;
        float m = 1.0 - smoothstep(-a, a, sd);
        if (sd > 0.0) o.ring = max(o.ring, smoothstep(0.35, 0.0, sd));
        if (m > 0.02 && h2.z > best) {
            best = h2.z; o.cover = m;
            float3 red = float3(0.42, 0.045, 0.02), orange = float3(0.70, 0.22, 0.03);
            float3 yellow = float3(0.78, 0.55, 0.07), brown = float3(0.26, 0.12, 0.05);
            float sel = h2.w;
            float3 col;
            if (h2.y < 0.45) col = sel < 0.5 ? red : (sel < 0.85 ? orange : yellow);
            else col = sel < 0.55 ? yellow : (sel < 0.8 ? orange : brown);
            float rr = clamp(1.0 + sd, 0.0, 1.0);
            col = mix(col, brown, 0.35*smoothstep(0.55, 1.0, rr)*h.w);
            col *= 0.85 + 0.3*gnoise(q*2.5 + h2.z*10.0);
            col *= 1.0 - 0.4*vein;
            o.col = col;
            float2 rad = normalize(q + float2(1e-4, 0.0));
            float2 rw = float2(ca*rad.x + sa*rad.y, -sa*rad.x + ca*rad.y);
            o.nrm = normalize(n + float3(-rw.x, 0.0, -rw.y)*0.45*smoothstep(0.5, 1.0, rr));
        }
    }
    return o;
}

// ---------------------------------------------------------------- rock material + shading
inline float3 ac_rockAlbedo(float2 q, float3 n, float above, float bo, float t,
                            thread float3 &nOut, thread float &moss, thread float &wetOut,
                            thread float &ring, thread float &leafOut) {
    float grain = fbm(q*7.0 + 2.0, 3);
    float3 rock = mix(float3(0.30, 0.28, 0.25), float3(0.16, 0.155, 0.15), 0.5 + 0.5*grain);
    rock *= 0.85 + 0.3*vnoise(q*45.0);
    rock *= mix(float3(1.0), float3(1.2, 0.98, 0.78), smoothstep(0.2, 0.7, gnoise(q*0.7 + 5.0)));
    float wet = 1.0 - smoothstep(0.05, 0.40, above);
    float mossN = fbm(q*2.1 + 11.0, 3) + 0.4*fbm(q*8.0 + 3.0, 2);
    moss = smoothstep(-0.14, 0.24, mossN + 0.1*smoothstep(0.0, 1.0, bo))*smoothstep(0.22, 0.62, n.y)
         * smoothstep(-0.02, 0.07, above)*(1.0 - 0.45*smoothstep(0.7, 1.8, above));
    float3 mossC = mix(float3(0.055, 0.135, 0.024), float3(0.215, 0.310, 0.062), vnoise(q*70.0));
    mossC *= 0.72 + 0.56*fbm(q*26.0 + 4.0, 2);      // velvet clumping
    float3 alb = mix(rock, mossC, moss);
    alb *= mix(1.0, 0.45, wet*(1.0 - moss));
    float litter = smoothstep(0.2, 0.9, bo)*smoothstep(0.30, 0.72, n.y);
    if (litter > 0.0) {
        float3 lit = float3(0.20, 0.10, 0.04)*(0.7 + 0.5*vnoise(q*30.0));
        alb = mix(alb, lit, litter*0.7*(1.0 - moss));
    }
    float dens = mix(0.22, 0.95, litter)*smoothstep(0.42, 0.80, n.y);
    float aa = max(0.0006, 0.00035*t);
    ACLeaf lf = ac_leafField(q, 0.10, dens, 1.0, n, aa);
    alb = mix(alb, lf.col, lf.cover);
    nOut = normalize(mix(n, lf.nrm, lf.cover));
    ring = lf.ring*(1.0 - lf.cover);
    leafOut = lf.cover;
    wetOut = wet*(1.0 - 0.4*lf.cover);
    return alb;
}

inline float3 ac_shadeRock(float3 P, float3 n, float3 rd, float t, float terr, float wat, ACLight L, bool full) {
    float2 q = P.xz;
    float cx = ac_cx(P.z), hw = ac_hw(P.z); float bo = max(abs(P.x - cx) - hw, 0.0);
    float above = P.y - wat;
    float3 n2; float moss, wet, ring, leafc;
    float3 alb = ac_rockAlbedo(q, n, above, bo, t, n2, moss, wet, ring, leafc);
    float det = ac_detailAt(t);
    float g = ac_gaps(P);
    float sh = full ? ac_shadow(P + n*0.01, L.sun, det) : 0.8;
    float ao = full ? ac_ao(P, det) : 0.7;
    ao *= 1.0 - 0.5*ring;
    float ndl = max(dot(n2, L.sun), 0.0);
    float3 sunL = L.sunCol*g*sh;
    float3 amb = (L.amb*(0.55 + 0.45*n2.y) + L.ambSky*max(n2.y, 0.0))*ao;
    float3 col = alb*(sunL*ndl + amb);
    // organic translucency: moss + leaves glow when the sun is behind them
    float fwd = pow(max(dot(rd, L.sun), 0.0), 3.0);
    float3 transC = mix(float3(0.10, 0.15, 0.022), float3(0.80, 0.34, 0.05), leafc);
    col += transC*max(moss*0.7, leafc)*sunL*fwd*0.20;
    float3 h = normalize(L.sun - rd);
    float ndh = max(dot(n2, h), 0.0);
    float rough = mix(mix(0.55, 0.16, wet), 0.75, moss);
    float a2 = rough*rough; a2 *= a2;
    float D = a2/(PI*ac_sq(ndh*ndh*(a2 - 1.0) + 1.0));
    float F0 = 0.03;
    float vdh = max(dot(-rd, h), 0.0);
    float F = F0 + (1.0 - F0)*pow(1.0 - vdh, 5.0);
    col += sunL*D*F*ndl*0.25;
    float ndv = max(dot(n2, -rd), 0.0);
    float Fe = F0 + (1.0 - F0)*pow(1.0 - ndv, 5.0);
    float3 R = reflect(rd, n2);
    col += ac_envCheap(P, R, L)*Fe*(1.0 - rough)*ao;
    return col;
}

// ---------------------------------------------------------------- canopy backdrop
// Perspective plane at distance D in front of the camera (camera looks toward +z);
// coordinates are METRES on that plane.
inline float2 ac_plane(float3 rd, float D) { return rd.xy*(D/max(rd.z, 0.06)); }

// radiating branch structure of a crown whose trunk sits at `org` (metres on the plane)
inline float ac_branchField(float2 q, float2 org, float k, float seed, thread float &wood) {
    float2 c = q - org;
    float r = max(length(c), 0.08);
    float a = atan2(c.y, c.x);
    float2 bp = float2(a*k, log(r)*1.7 + seed);
    float n = fbm(bp, 4);
    float rg = 1.0 - abs(n)*2.6;                        // ridges = branch cores
    wood = smoothstep(0.66, 0.95, rg)*smoothstep(11.0, 1.2, r);
    float mass = smoothstep(-0.34, 0.26, n + 0.30*fbm(bp*2.7 + 11.0, 3));
    return mass*smoothstep(13.0, 2.0, r);
}

inline float3 ac_foliageTint(float2 q, float cf, float seed) {
    float h = fbm(q*cf*0.24 + seed, 3) + 0.38*fbm(q*cf*1.0 + seed*1.7, 2) + 0.20*fbm(q*cf*4.5 + seed, 2);
    float3 crim  = float3(0.34, 0.042, 0.016);
    float3 amber = float3(0.66, 0.190, 0.020);
    float3 gold  = float3(0.90, 0.520, 0.055);
    float3 lime  = float3(0.44, 0.40, 0.050);
    float3 c = mix(crim, amber, smoothstep(-0.45, 0.02, h));
    c = mix(c, gold, smoothstep(-0.04, 0.44, h));
    c = mix(c, lime, 0.40*smoothstep(0.36, 0.74, h));
    c *= 0.74 + 0.52*vnoise(q*cf*9.0);
    return c;
}

// ---- leaf-clump canopy layer ----------------------------------------
// A crown is not fbm mush: it is a pile of roughly spherical leaf clumps.
// Each clump is lit from BEHIND, so its thin edges glow gold and its core
// stays a deep crimson silhouette — that read is what sells a backlit canopy.
struct ACCan { float cov; float3 col; };

inline ACCan ac_clumpLayer(float2 q0, float cell, float dens, float thick,
                           float seed, float3 backL, float3 amb, float aa) {
    ACCan o; o.cov = 0.0; o.col = float3(0.0);
    // ragged silhouettes: warp the domain at leaf scale before cutting circles
    float s1 = 2.6/cell;
    float2 q = q0 + (0.30*cell)*float2(fbm(q0*s1 + 3.0, 3), fbm(q0*s1 + 19.0, 3));
    float2 pc = q/cell; float2 i = floor(pc); float2 f = pc - i;
    // leaf mosaic shared by the whole layer: individual leaves, not fbm mush
    float lfq = 1.0/max(cell, 0.02);
    float mos = fbm(q0*(8.5*lfq) + seed*3.7, 4) + 0.35*gnoise(q0*(22.0*lfq) + seed);
    float spk = vnoise(q0*(13.0*lfq) + seed*1.9);
    float keep = 1.0; float best = -1.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 h = hash24(i + g + seed);
        if (h.x > dens) continue;
        float4 h2 = hash24(i + g + seed + 29.3);
        float2 c = g + 0.06 + 0.88*h.yz;
        float2 d = f - c;
        d.y *= mix(0.92, 1.45, h2.x);
        float r = mix(0.36, 0.66, h.w);
        float rr = length(d)/r;
        if (rr > 1.02) continue;
        float sph = sqrt(max(1.0 - rr*rr, 0.0));       // relative optical depth
        float e = clamp(aa/(r*cell), 0.006, 0.35);
        float m = smoothstep(1.0, 1.0 - 4.0*e, rr);
        // leafy holes everywhere, opening right up towards the thin edge
        float thr = mix(0.30, -0.38, sph);
        m *= smoothstep(thr - 0.13, thr + 0.17, mos);
        if (m <= 0.004) continue;
        keep *= 1.0 - m;
        if (h2.z > best) {
            best = h2.z;
            float3 tint = ac_foliageTint(q0, 1.0/cell, seed);
            float tk = thick*(0.55 + 0.9*h2.w);
            float tr = exp(-tk*(0.10 + 1.25*sph));      // transmitted through the clump
            float rim = smoothstep(0.48, 1.0, rr);
            float lv = 0.30 + 1.55*spk*spk;             // each leaf transmits differently
            float3 lit = tint*backL*(tr*lv + 0.28*rim*exp(-tk*0.45))
                       + tint*amb*(0.55 + 0.85*spk);
            o.col = lit;
        }
    }
    o.cov = 1.0 - keep;
    return o;
}

// vertical trunks with bark relief; `lit` = sun-side rim
inline float ac_trunks(float2 q, float freq, float seed, float top, thread float &edge) {
    float wob = 0.10*fbm(float2(q.y*0.10 + seed, seed), 2);
    float tq = fbm(float2((q.x + wob*4.0)*freq, q.y*0.035 + seed), 3);
    float m = smoothstep(0.30, 0.52, tq);
    edge = smoothstep(0.26, 0.34, tq)*(1.0 - smoothstep(0.34, 0.46, tq));
    m *= smoothstep(top + 1.5, top - 5.0, q.y);
    m *= 0.72 + 0.28*(0.5 + 0.5*gnoise(float2(q.x*freq*6.0, q.y*1.2)));
    return m;
}

// explicit leaf splats (used for near silhouettes only)
inline void ac_leafCanopy(float2 p, float cell, float density, float seed, float aa,
                          thread float &cov, thread float3 &tint, thread float &glow) {
    cov = 0.0; tint = float3(0.0); glow = 0.0;
    float2 pc = p/cell; float2 i = floor(pc); float2 f = pc - i;
    float best = -1.0; float keep = 1.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 h = hash24(i + g + seed);
        if (h.x > density) continue;
        float4 h2 = hash24(i + g + seed + 53.7);
        float2 c = g + 0.02 + 0.96*h.yz;
        float2 d = (f - c)*cell;
        float size = cell*mix(0.42, 0.98, h.w*h.w);
        float ang = h2.x*TAU; float ca = cos(ang), sa = sin(ang);
        float2 q = float2(ca*d.x - sa*d.y, sa*d.x + ca*d.y)/size;
        q.y *= mix(0.50, 1.0, fract(h2.x*13.7));
        if (dot(q, q) > 2.6) continue;
        float vein; float sd = ac_leafSDF(q, h2.y, vein);
        float av = aa/size;
        float m = 1.0 - smoothstep(-av, av, sd);
        if (m <= 0.004) continue;
        keep *= 1.0 - m;
        if (h2.z > best) {
            best = h2.z;
            float sel = h2.w;
            float3 red = float3(0.44, 0.050, 0.020), orange = float3(0.76, 0.24, 0.026);
            float3 yellow = float3(0.88, 0.58, 0.060), olive = float3(0.28, 0.24, 0.032);
            float3 cc = sel < 0.30 ? red : (sel < 0.64 ? orange : (sel < 0.88 ? yellow : olive));
            cc *= 0.78 + 0.40*vnoise(q*3.0 + h2.z*13.0);
            cc *= 1.0 - 0.34*vein;
            tint = cc;
            glow = pow(fract(h2.z*17.31), 3.6);
        }
    }
    cov = 1.0 - keep;
}

// far forest + the sky behind it. `cheap` = no near layer (used for reflections)
inline float3 ac_canopy(float3 rd, ACLight L, bool cheap) {
    float mu = dot(rd, L.sun);
    float sw = clamp(0.5 + 0.5*mu, 0.0, 1.0);
    float sunw = pow(sw, 12.0);
    float hi = smoothstep(-0.08, 0.42, rd.y);
    float aa = cheap ? 0.05 : 0.0022;
    // the wood closes in overhead; the creek itself keeps an open, hazy slot
    float over = smoothstep(-0.03, 0.26, rd.y);

    // --- the open light behind the trees -----------------------------------
    float3 hazeC = mix(float3(0.16, 0.21, 0.30), float3(1.00, 0.66, 0.34), sunw);
    float3 sky = hazeC*(0.26 + 1.35*sunw);
    sky += float3(1.00, 0.74, 0.42)*1.5*pow(sw, 190.0);           // tight veiled bloom
    if (!cheap) sky += ws_sunDisk(rd, L.sun, 0.42, float3(1.0, 0.90, 0.74)*14.0);
    sky = mix(sky*float3(1.05, 0.88, 0.68)*0.44, sky, hi);
    float3 col = sky;

    // light transmitted through a leaf, and the ambient bounce inside the wood
    float3 backL = float3(1.00, 0.70, 0.36)*(0.30 + 9.5*sunw);
    float3 ambL  = L.ambSky*0.50 + L.amb*0.60;

    // --- layer 4: distant woods, hazy ---------------------------------------
    {
        float2 q = ac_plane(rd, 34.0) + float2(7.0, 2.0);
        float ed; float tr = ac_trunks(q, 0.55, 3.0, 7.0, ed);
        ACCan c4 = ac_clumpLayer(q, 1.15, 0.94, 2.4, 4.0, backL*0.50, ambL*1.1, aa*34.0);
        col = mix(col, c4.col, c4.cov*0.95);
        col = mix(col, float3(0.030, 0.023, 0.020)*(1.0 + 5.0*sunw), tr*0.7);
        float3 haze = mix(float3(0.16, 0.19, 0.25), float3(1.00, 0.70, 0.40), sunw)*(0.20 + 1.30*sunw);
        col = mix(col, haze, cheap ? 0.24 : 0.36);
    }
    // --- layer 3: the golden mid canopy ------------------------------------
    {
        float2 q = ac_plane(rd, 17.0) + float2(-2.5, 1.0);
        float ed; float tr = ac_trunks(q, 0.42, 21.0, 5.0, ed);
        ACCan c3 = ac_clumpLayer(q, 1.45, 0.90, 3.1, 17.0, backL*0.80, ambL*0.75, aa*17.0);
        col = mix(col, c3.col, c3.cov*(0.62 + 0.36*over));
        col = mix(col, float3(0.024, 0.018, 0.015)*(1.0 + 3.2*sunw) + ed*float3(0.10,0.07,0.04)*sunw, tr*0.85);
        float3 haze = mix(float3(0.14, 0.16, 0.20), float3(1.00, 0.72, 0.44), sunw)*(0.12 + 0.95*sunw);
        col = mix(col, haze, 0.15);
    }
    if (!cheap) {
        // --- layer 2: crown overhead ---------------------------------------
        {
            float2 q = ac_plane(rd, 8.5) + float2(-3.2, 2.6);
            float wood;
            float br = ac_branchField(q, float2(-8.0, 0.5), 2.9, 21.0, wood);
            ACCan c2 = ac_clumpLayer(q, 1.20, 0.86, 4.0, 61.0, backL*0.50, ambL*0.42, aa*8.5);
            float m = c2.cov*clamp(0.30 + br*1.6, 0.0, 1.0)*over;
            col = mix(col, c2.col, m*0.96);
            col = mix(col, float3(0.020, 0.015, 0.012)*(1.0 + 2.2*sunw), wood*0.88*over);
        }
        // --- layer 1b: second crown, other side, deeper shadow --------------
        {
            float2 q = ac_plane(rd, 6.0) + float2(4.6, 1.4);
            float wood;
            float br = ac_branchField(q, float2(9.5, 3.0), 2.5, 7.0, wood);
            ACCan c1 = ac_clumpLayer(q, 1.05, 0.80, 5.0, 97.0, backL*0.36, ambL*0.30, aa*6.0);
            float top = smoothstep(0.04, 0.40, rd.y);
            float m = c1.cov*clamp(0.16 + br*1.9, 0.0, 1.0)*top;
            col = mix(col, c1.col, m*0.96);
            col = mix(col, float3(0.016, 0.012, 0.009)*(1.0 + 1.6*sunw), wood*0.9*top);
        }
        // --- layer 1: nearest leaves — small dark silhouettes on a bough -----
        {
            float2 q = ac_plane(rd, 3.4) + float2(2.2, -1.2);
            float wood;
            float br = ac_branchField(q, float2(7.4, 5.0), 2.3, 61.0, wood);
            float top = smoothstep(0.10, 0.44, rd.y);
            float dens = clamp(br*2.6*top - 0.08, 0.0, 0.86);
            float cov, lg; float3 tint;
            ac_leafCanopy(q, 0.072, dens, 131.0, 0.008, cov, tint, lg);
            float3 lit = tint*(backL*0.075*(0.22 + lg) + ambL*0.28) + float3(0.009, 0.007, 0.005);
            col = mix(col, lit, cov*0.96);
            col = mix(col, float3(0.011, 0.008, 0.006), wood*0.9*top);
        }
    }
    // a grazing reflection sees the shaded near wood and the trunks, not the sky
    if (cheap) col *= mix(0.30, 1.0, smoothstep(-0.02, 0.30, rd.y));
    return col;
}


// ---------------------------------------------------------------- water
inline float3 ac_shadeWater(float3 P, float3 rd, float t, float terr, float wat, ACLight L) {
    float det = ac_detailAt(t);
    float u = ac_u(P.xz); float f = u - floor(u);
    float depth = max(wat - terr, 0.0);
    float cx = ac_cx(P.z), hw = ac_hw(P.z); float ax = abs(P.x - cx);

    float3 nW = ac_normalWater(P.xz, t, det);
    // broad, streaked surface undulation (long-exposure: no crisp ripples)
    float2 sp = float2(P.x*13.0, P.z*3.4);
    float r1 = gnoise(sp) + 0.45*gnoise(sp*2.7 + 5.0);
    float r2 = gnoise(sp + float2(31.0, 7.0)) + 0.45*gnoise(sp*2.7 + 17.0);
    float amp = (0.030 + 0.045*smoothstep(0.30, 0.02, depth))*smoothstep(0.012, 0.09, depth)*det;
    nW = normalize(nW + float3(r1, 0.0, r2*0.45)*amp);

    float g = ac_gaps(P);
    float sh = ac_shadow(P + float3(0.0, 0.01, 0.0), L.sun, det);
    float3 sunL = L.sunCol*g*sh;

    // ---- bed seen through the water
    float3 rr = refract(rd, nW, 1.0/1.33);
    if (rr.y > -0.05) rr = normalize(rd + float3(0.0, -0.35, 0.0));
    float travel = clamp(depth/max(-rr.y, 0.22), 0.0, 1.2);
    float3 B = P + rr*travel;
    float bt, bw; ac_top(B.xz, det, bt, bw);
    float3 bn = ac_normalRock(B.xz, t, det);
    // pebble bed: two scales of packed cobbles, shaded before the water column
    {
        float2 cA = worley(B.xz*26.0 + 11.0);
        float2 cB = worley(B.xz*62.0 + 3.0);
        float bumpA = sqrt(max(1.0 - cA.x*2.3, 0.0));
        float bumpB = sqrt(max(1.0 - cB.x*2.6, 0.0));
        float2 e = float2(0.006, 0.0);
        float gx = (sqrt(max(1.0 - worley((B.xz + e.xy)*26.0 + 11.0).x*2.3, 0.0)) - bumpA)
                 + 0.5*(sqrt(max(1.0 - worley((B.xz + e.xy*0.42)*62.0 + 3.0).x*2.6, 0.0)) - bumpB);
        float gz = (sqrt(max(1.0 - worley((B.xz + e.yx)*26.0 + 11.0).x*2.3, 0.0)) - bumpA)
                 + 0.5*(sqrt(max(1.0 - worley((B.xz + e.yx*0.42)*62.0 + 3.0).x*2.6, 0.0)) - bumpB);
        bn = normalize(bn + float3(-gx, 0.0, -gz)*7.0*det);
    }
    float3 bed = ac_shadeRock(float3(B.x, bt, B.z), bn, rr, t, bt, bw, L, false);
    {   // per-pebble tone: ochre / grey / rust cobbles, darker in the joints
        float2 cA = worley(B.xz*26.0 + 11.0);
        float id = hash12(floor(B.xz*26.0 + 11.0 + cA.y*0.0) + cA.y*7.31);
        float3 peb = mix(float3(0.42, 0.34, 0.26), float3(0.20, 0.21, 0.21), step(0.45, id));
        peb = mix(peb, float3(0.40, 0.20, 0.10), smoothstep(0.78, 0.98, id));
        bed = mix(bed, bed*2.0*peb, 0.55*det);
        bed *= 0.55 + 0.75*smoothstep(0.0, 0.42, cA.x*2.3);
    }
    // caustics
    float2 cw = worley(B.xz*13.0 + 4.0);
    float caus = pow(clamp(1.0 - (cw.x*1.9), 0.0, 1.0), 5.0);
    bed += bed*caus*1.9*g*sh*smoothstep(0.02, 0.12, depth);

    // clear creek water: a gentle green-amber absorption, bed clearly visible
    float3 sigma = float3(2.45, 0.90, 1.35)*1.55;
    float3 trans = exp(-sigma*(travel + depth*0.80));
    float3 silt = float3(0.040, 0.072, 0.055)*(L.amb*1.5 + sunL*0.20);
    float3 body = bed*trans + silt*(1.0 - trans);

    // ---- reflection (grazing => dominant)
    float3 R = reflect(rd, nW); R.y = max(R.y, 0.004);
    float3 refl = ac_canopy(R, L, true);
    float ndv = max(dot(nW, -rd), 0.0);
    float F = 0.02 + 0.98*pow(1.0 - ndv, 5.0);
    F = clamp(F, 0.02, 0.92);
    float3 col = mix(body, refl, F);

    // ---- sun specular
    float3 hv = normalize(L.sun - rd);
    float ndh = max(dot(nW, hv), 0.0);
    float rough = 0.085 + 0.07*smoothstep(0.0, 0.5, f);
    float a2 = rough*rough; a2 *= a2;
    float D = a2/(PI*ac_sq(ndh*ndh*(a2 - 1.0) + 1.0));
    col += sunL*D*F*max(dot(nW, L.sun), 0.0)*0.28;

    // ---- silky whitewater
    // whitewater lives only where the sheet actually breaks: the lip, the fall,
    // and the boil at its foot. Everywhere else the water stays clear.
    float lip   = smoothstep(0.78, 0.86, f)*smoothstep(0.995, 0.90, f);
    float fall  = smoothstep(0.86, 0.96, f);
    float boil  = (1.0 - smoothstep(0.0, 0.075, f))*0.85;
    float thin  = (1.0 - smoothstep(0.002, 0.012, depth))*smoothstep(0.55, 0.95, 1.0 - ax/max(hw, 0.3));
    float turb  = max(max(lip*0.55 + fall*1.05, boil), thin*0.30);
    float2 st = float2(P.x*13.0, P.z*1.6);
    float streak = fbm(st, 4)*0.5 + 0.5;
    float fine   = fbm(float2(P.x*30.0, P.z*3.0) + 9.0, 3)*0.5 + 0.5;
    float foam = smoothstep(0.46, 0.99, turb*(0.30 + 1.00*streak)*(0.60 + 0.65*fine));
    foam = clamp(foam, 0.0, 1.0)*smoothstep(0.0, 0.35, 1.0 - smoothstep(6.0, 16.0, t)*0.55);
    // thin silk lines drifting down the calm pools (long-exposure smear)
    float silk = smoothstep(0.93, 0.998, fbm(float2(P.x*26.0, P.z*1.6) + 21.0, 3)*0.5 + 0.5)
               * smoothstep(0.05, 0.22, depth)*(1.0 - turb)*0.10;
    float3 foamC = (sunL*0.30 + L.amb*1.6 + L.ambSky*0.9)*float3(1.0, 0.975, 0.94);
    col = mix(col, foamC, clamp(foam + silk, 0.0, 1.0));

    // ---- leaves floating in the eddies
    float eddy = smoothstep(0.20, 0.45, f)*smoothstep(0.78, 0.55, f)
               * smoothstep(0.30, 0.85, ax/max(hw, 0.3))*smoothstep(0.03, 0.10, depth);
    eddy = clamp(eddy*1.5, 0.0, 1.0)*(1.0 - foam);
    if (eddy > 0.01) {
        float aa = max(0.0007, 0.00040*t);
        ACLeaf lf = ac_leafField(P.xz + 5.0, 0.13, 0.45*eddy, 61.0, float3(0.0, 1.0, 0.0), aa);
        float c = lf.cover*eddy;
        if (c > 0.002) {
            float3 lc = lf.col*1.06;
            float ndl = max(dot(lf.nrm, L.sun), 0.0);
            float3 ll = lc*(sunL*ndl*0.9 + L.amb*1.05 + L.ambSky*0.75);
            ll += lc*sunL*pow(max(dot(rd, L.sun), 0.0), 3.0)*0.5;     // backlit glow
            float3 lh = normalize(L.sun - rd);
            ll += sunL*pow(max(dot(lf.nrm, lh), 0.0), 70.0)*0.35;      // wet sheen
            col = mix(col, ll, c);
        }
        col *= 1.0 - 0.22*lf.ring*eddy*(1.0 - lf.cover);               // meniscus shadow
        col += foamC*0.10*lf.ring*eddy*(1.0 - lf.cover);               // meniscus rim
    }
    return col;
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 uv = fragCoord/ctx.res;

    ACLight L;
    L.sun    = ac_sunDir();
    L.sunCol = float3(1.00, 0.70, 0.38)*12.0;
    L.amb    = float3(0.150, 0.140, 0.115)*1.05;   // warm bounce off the leaf litter
    L.ambSky = float3(0.085, 0.120, 0.190)*1.25;   // cool skylight

    float z0 = 0.0;
    float lvl0 = ac_levelApprox(z0);
    float3 ro = float3(ac_cx(z0) + 0.22, lvl0 + 0.44, z0 - 0.9);
    float3 ta = float3(ac_cx(6.0) - 0.30, ac_levelApprox(6.0) + 0.34, 6.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, 42.0, 0.0);

    float tHit = AC_TMAX; int mat = 0; float terr = 0.0, wat = 0.0;
    bool hit = ac_march(ro, rd, 0.02, AC_TMAX, 150, tHit, mat, terr, wat);

    float3 col;
    if (hit) {
        float3 P = ro + rd*tHit;
        if (mat == 2) {
            col = ac_shadeWater(float3(P.x, wat, P.z), rd, tHit, terr, wat, L);
        } else {
            float3 n = ac_normalRock(P.xz, tHit, ac_detailAt(tHit));
            col = ac_shadeRock(float3(P.x, terr, P.z), n, rd, tHit, terr, wat, L, true);
        }
    } else {
        tHit = AC_TMAX;
        col = ac_canopy(rd, L, false);
    }

    // ---- atmospheric perspective + god rays through the mist -------------
    float mu = dot(rd, L.sun);
    float3 mistC = mix(float3(0.26, 0.31, 0.40), float3(1.0, 0.78, 0.50), 0.58)*0.92;
    {
        float fogT = hit ? tHit : 9.0;
        float fa = ws_fogAmount(fogT, ro, rd, 0.0155, 0.42);
        fa = clamp(fa*(0.72 + 0.55*ac_hg(mu, 0.55)), 0.0, 0.70);
        col = mix(col, mistC*(0.38 + 1.75*ac_hg(mu, 0.64)), fa);
    }
    {
        const int NS = 16;
        float far = min(tHit, 26.0);
        float dt = far/float(NS);
        float3 acc = float3(0.0);
        float jit = hash12(fragCoord + 0.5);
        for (int i = 0; i < NS; i++) {
            float s = (float(i) + jit)*dt + 0.05;
            float3 Q = ro + rd*s;
            float hgt = Q.y - ac_levelApprox(Q.z);
            float dens = exp(-max(hgt, 0.0)*0.55)*(0.55 + 0.45*fbm(Q.xz*0.35 + float2(0.0, 3.0), 2));
            float vis = ac_gaps(Q)*ac_shadow(Q, L.sun, 0.0);
            acc += L.sunCol*vis*dens*dt;
        }
        col += acc*ac_hg(mu, 0.72)*0.042*float3(1.0, 0.85, 0.60);
    }

    // sun flare where it breaks through the leaves
    float sunHit = pow(clamp(mu, 0.0, 1.0), 900.0)*smoothstep(-0.12, 0.18, rd.y);
    col += L.sunCol*sunHit*0.9;

    // ---- grade -----------------------------------------------------------
    col *= ws_vignette(uv, 0.50);
    col = ws_saturate(col, 1.24);
    // filmic lift/contrast before the tonemap: deepen the bank shadows
    col = col*col*0.34 + col*0.72;
    col = ws_acesFitted(col*0.98);
    col += (ws_grain(fragCoord, ctx.t) - 0.5)*0.0055;
    return clamp(col, 0.0, 1.0);
}
