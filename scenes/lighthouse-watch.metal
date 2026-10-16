// =====================================================================
//  Lighthouse Watch — a tall lighthouse on a rugged headland, deep night.
//  Twin opposed beams turn once per 20 s loop and sweep as volumetric
//  shafts through sea mist; heavy long-period swells roll in slowly and
//  break white against the rocks. Thin crescent moon, stars, drifting cloud.
//  Units: metres. y up, mean sea level y = 0. Camera looks toward +z.
// =====================================================================

constant float DEG = 0.017453292519943295;

// camera
constant float3 LW_CAM  = float3(0.0, 5.5, 0.0);
constant float  LW_VFOV = 36.0;
constant float  LW_YAW  = 3.0;          // camera heading (deg, + = right / +x)
constant float  LW_HOR  = 0.36;         // horizon height (fraction of frame from bottom)
constant float  LW_EXPO = 1.16;

// lighthouse
constant float2 LW_LH   = float2(-52.0, 232.0);   // tower axis (xz)
constant float  LW_PAD  = 21.0;                   // ground level at the tower
constant float  LW_TWR  = 40.0;                   // masonry tower height above the pad
constant float  LW_R0   = 4.0;                    // tower radius at base
constant float  LW_R1   = 2.05;                   // tower radius at top
constant float  LW_LAMPY = LW_PAD + LW_TWR + 3.0; // lamp height (64 m)

// moon (thin crescent, upper left)
constant float  LW_MOON_AZ = -20.0;               // world azimuth (deg from +z toward +x)
constant float  LW_MOON_EL = 16.0;

// beam
constant float  LW_PHI0   = 100.0 * DEG;          // beam azimuth at t = 0
constant float  LW_BEAM_EL = 0.15 * DEG;           // beam elevation
constant float  LW_SH = 1.25 * DEG;                // core sigma, horizontal
constant float  LW_SV = 2.25 * DEG;                // core sigma, vertical
constant float  LW_SHALO = 2.9 * DEG;             // halo sigma
// soft landward sky-glow (a town somewhere behind the camera) — the fill that
// keeps the white masonry and the wet rock from going to dead black.
constant float3 LW_FILLC = float3(0.175, 0.196, 0.268);
constant float  LW_IBEAM = 5.4e5;                 // beam radiant intensity (scene units)
constant float  LW_SIGS  = 0.028;                 // mist scattering coefficient at sea level (1/m)
constant float  LW_SIGT  = 0.0013;                // extinction (1/m) for beam/lamp transmittance

inline float3 lw_lamp() { return float3(LW_LH.x, LW_LAMPY, LW_LH.y); }
inline float3 lw_moonDir() {
    float az = LW_MOON_AZ * DEG, el = LW_MOON_EL * DEG;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ small helpers
inline float lw_sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
inline float lw_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
inline float lw_sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
inline float lw_sdCylY(float3 p, float r, float h0, float h1) {
    float2 d = float2(length(p.xz) - r, max(h0 - p.y, p.y - h1));
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}
// loop-safe drifting noise: two copies of a field drift by `drift` over their life and are
// blended with variance-preserving weights |sin|,|cos| (sum of squares = 1).
inline float lw_flow2(float2 p, float t, float2 drift, int oct) {
    float a = fract(t), b = fract(t + 0.5);
    float wa = sin(PI * a), wb = sin(PI * b);
    float na = fbm(p - drift * (a - 0.5), oct);
    float nb = fbm(p - drift * (b - 0.5) + float2(41.3, 17.9), oct);
    return (wa * na + wb * nb) / (wa + wb);
}
inline float lw_flow3(float3 p, float t, float3 drift, int oct) {
    float a = fract(t), b = fract(t + 0.5);
    float wa = sin(PI * a), wb = sin(PI * b);
    float na = fbm(p - drift * (a - 0.5), oct);
    float nb = fbm(p - drift * (b - 0.5) + float3(41.3, 17.9, 7.7), oct);
    return (wa * na + wb * nb) / (wa + wb);
}
inline float lw_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * c, 1e-4), 1.5));
}

// ------------------------------------------------------------ terrain
// coastline signed distance in the horizontal plane (m): negative on land
inline float lw_coast(float2 q) {
    float2 w = q + 14.0 * float2(gnoise(q * 0.012 + float2(3.1, 1.7)), gnoise(q * 0.012 + float2(8.3, 5.2)))
                 + 4.0 * float2(gnoise(q * 0.05 + 1.3), gnoise(q * 0.05 + 7.4));
    float d = lw_sdSeg(w, float2(-270.0, 130.0), float2(-46.0, 238.0)) - 34.0;   // headland ridge
    float dm = dot(w - float2(-160.0, 40.0), normalize(float2(1.0, 0.35)));      // mainland
    dm += 30.0 * gnoise(w * 0.0062 + float2(11.4, 4.3))                          // bays and points
        + 13.0 * gnoise(w * 0.0185 + float2(3.7, 9.2));
    d = lw_smin(d, dm, 40.0);
    float dn = lw_sdSeg(w, float2(-86.0, -6.0), float2(-34.0, 16.0)) - 9.5;     // foreground shelf
    d = lw_smin(d, dn, 10.0);
    float ds = length(w - float2(-14.0, 254.0)) - 6.5;                           // sea stack off the point
    d = min(d, ds);
    float dk = length(w - float2(55.0, 150.0)) - 3.5;                            // skerry, right
    d = min(d, dk);
    // near rocks, lower left — the foreground anchor
    float2 nw = (w - float2(-40.0, 82.0)) * float2(1.0, 0.70);
    float dfr = length(nw) - 8.0;
    float dfr2 = length((w - float2(-20.0, 63.0)) * float2(0.9, 1.30)) - 3.4;
    d = min(d, lw_smin(dfr, dfr2, 4.0));
    return d;
}

// Ground height (m). lod = ridged octaves.
inline float lw_heightC(float2 q, float c, int lod) {
    float s = -c;
    if (s < -15.0) return -8.0;
    float top = 22.0 + 3.0 * fbm(q * 0.012 + float2(4.0, 1.0), 2) + 18.0 * smoothstep(-120.0, -300.0, q.x);
    float fg = smoothstep(118.0, 62.0, q.y);
    top = mix(top, 3.2, fg);
    top = mix(top, 5.4, smoothstep(11.0, 2.5, length((q - float2(-40.0, 82.0)) * float2(1.00, 0.72))));
    top = mix(top, 3.3, smoothstep(6.0, 1.5, length((q - float2(-20.0, 63.0)) * float2(0.90, 1.30))));
    top = mix(top, 14.0, smoothstep(20.0, 10.0, length(q - float2(-14.0, 254.0))));
    top = mix(top, 1.9, smoothstep(12.0, 5.0, length(q - float2(55.0, 150.0))));
    float cw = mix(8.0, 15.0, 0.5 + 0.5 * gnoise(q * 0.03 + 5.0));
    float u = clamp(s / cw, 0.0, 1.0);
    float iu = 1.0 - u;
    float prof = 1.0 - iu * iu * iu;
    float h = top * prof;
    // relief lives on the face, not the skyline: a cliff crest is a fairly clean edge
    float crest = 1.0 - smoothstep(0.55, 0.93, prof);
    float rockMask = (1.0 - smoothstep(0.62, 1.0, u)) * (0.40 + 0.60 * crest);
    float r = ridged(q * 0.045 + float2(1.7, 3.3), min(lod, 2));
    float rBig = ridged(q * 0.018 + float2(8.9, 4.2), 2);
    float amp = 3.0 + 3.4 * rBig;                       // some stretches sheer, some broken
    h += ((r - 0.55) * amp + (rBig - 0.52) * 6.0) * rockMask;
    // close rock gets a second, sharper generation of crags and fracture ledges
    float nearM = smoothstep(190.0, 55.0, q.y) * smoothstep(-2.5, 0.6, h)
                * (1.0 - smoothstep(7.0, 17.0, s));
    if (nearM > 0.002 && lod > 1) {
        float r2 = ridged(q * 0.26 + float2(5.1, 9.4), 3);
        float r3 = ridged(q * 0.85 + float2(2.4, 6.1), 2);
        float ledge = 0.5 + 0.5 * sin(h * 3.1 + 3.2 * gnoise(q * 0.20));
        h += ((r2 - 0.52) * 2.9 + (r3 - 0.52) * 0.85 + (ledge - 0.5) * 0.70) * nearM;
    }
    // rocky apron at the waterline: boulders and shelves
    float ap = smoothstep(-14.0, -2.0, s) * (1.0 - smoothstep(0.0, 8.0, s));
    if (ap > 0.001) {
        float2 wcA = worley(q * 0.22 + 0.5 * float2(gnoise(q * 0.1), gnoise(q * 0.1 + 3.0)));
        float bA = sqrt(max(0.0, 1.0 - wcA.x * wcA.x * 1.6)) * 2.2;
        h = max(h, (bA - 0.6 + 0.8 * r) * ap);
    }
    // the shore cap keeps ground from overhanging the waterline; give its slope a noisy,
    // irregular profile or every rock resolves into a smooth cone
    // The cap's slope must vary only at large scale — fine noise here multiplies by s and
    // turns the cliff crest into a crown of thorns.
    // Shore cap: stops ground overhanging the waterline. Its slope varies only at large
    // scale; the craggy detail is an offset that decays with depth inland, so it roughens
    // the shoreline without ever growing into spikes on a distant cliff crest.
    // Shore cap: stops ground overhanging the waterline, and its slope carries the
    // shoreline's ruggedness. The fine component is faded out with distance — at 200 m a
    // 2 m wobble in the cap turns a cliff crest into a comb of spikes.
    float nearW = smoothstep(155.0, 78.0, q.y);
    float capK = 1.62 + 0.70 * gnoise(q * 0.055 + float2(6.3, 2.9))
               + 0.55 * gnoise(q * 0.021 + float2(1.4, 7.6))
               + (0.80 * gnoise(q * 0.17 + float2(2.7, 8.1)) + 0.30 * gnoise(q * 0.52)) * nearW;
    float faceM = smoothstep(34.0, 3.0, s);        // the cliff face itself, not the plateau
    float cd = 0.0;
    if (faceM > 0.004) {
        float b1 = ridged(q * 0.085 + float2(4.4, 1.2), 2) - 0.52;   // ~12 m buttresses
        float b2 = ridged(q * 0.245 + float2(8.7, 6.5), 2) - 0.52;   // ~4 m ribs
        cd = (b1 * 5.0 + b2 * 1.7) * faceM;
    }
    h = max(min(h, s * clamp(capK, 0.55, 3.25) + 0.35 + cd), -8.0);
    // flatten a pad for the lighthouse and the cottage
    float dp = length((q - float2(LW_LH.x - 8.0, LW_LH.y - 3.0)) * float2(0.7, 1.0));
    float padw = smoothstep(18.0, 10.0, dp) * smoothstep(-2.0, 6.0, s);
    if (padw > 0.0) h = mix(h, LW_PAD + 0.3 * fbm(q * 0.2, 2), padw);
    return h;
}
inline float lw_height(float2 q, int lod) { return lw_heightC(q, lw_coast(q), lod); }

// horizontal bounding capsules of the land (generous); returns t-range where terrain may exist
inline float2 lw_landRange(float3 ro, float3 rd) {
    float2 rng = float2(1e9, -1e9);
    float2 o = ro.xz, d = rd.xz;
    float dl = length(d);
    if (dl < 1e-4) return rng;
    float2 dn = d / dl;
    // capsules: (a, b, radius)
    for (int i = 0; i < 5; i++) {
        float2 a, b; float r;
        if (i == 0) { a = float2(-300.0, 110.0); b = float2(-40.0, 246.0); r = 62.0; }
        else if (i == 1) { a = float2(-80.0, 0.0); b = float2(-12.0, 34.0); r = 26.0; }
        else if (i == 2) { a = float2(-14.0, 254.0); b = a; r = 26.0; }
        else if (i == 3) { a = float2(55.0, 150.0); b = a; r = 22.0; }
        else { a = float2(-40.0, 82.0); b = float2(-20.0, 63.0); r = 26.0; }
        // ray vs capsule in 2D: solve |o + dn*s - closest(seg)| = r approximately via circle around segment samples
        // exact: distance from ray to segment ≤ r  → compute entry/exit by sampling the segment endpoints' circles and the slab
        float2 ba = b - a;
        float bl = length(ba);
        float2 bn = bl > 1e-3 ? ba / bl : float2(1.0, 0.0);
        float2 pn = float2(-bn.y, bn.x);
        // transform ray into segment frame: u along, v across
        float ou = dot(o - a, bn), ov = dot(o - a, pn);
        float du = dot(dn, bn), dv = dot(dn, pn);
        // slab |v| <= r, u in [0, bl]  (rectangle) plus end circles — union of rectangle and two discs
        float sMin = 1e9, sMax = -1e9;
        // rectangle
        {
            float t0 = -1e9, t1 = 1e9;
            if (abs(dv) > 1e-6) { float ta = (-r - ov) / dv, tb = (r - ov) / dv; t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb)); }
            else if (abs(ov) > r) { t0 = 1e9; t1 = -1e9; }
            if (abs(du) > 1e-6) { float ta = (0.0 - ou) / du, tb = (bl - ou) / du; t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb)); }
            else if (ou < 0.0 || ou > bl) { t0 = 1e9; t1 = -1e9; }
            if (t0 <= t1) { sMin = min(sMin, t0); sMax = max(sMax, t1); }
        }
        // discs
        for (int e = 0; e < 2; e++) {
            float2 c = e == 0 ? a : b;
            float2 oc = o - c;
            float bq = dot(oc, dn);
            float cq = dot(oc, oc) - r * r;
            float disc = bq * bq - cq;
            if (disc > 0.0) { float sq = sqrt(disc); sMin = min(sMin, -bq - sq); sMax = max(sMax, -bq + sq); }
        }
        if (sMin <= sMax) { rng.x = min(rng.x, sMin); rng.y = max(rng.y, sMax); }
    }
    rng /= dl;
    rng.x = max(rng.x, 0.0);
    return rng;
}

// ------------------------------------------------------------ buildings (SDF)
// material ids: 1 tower, 2 iron, 3 lantern glass, 4 cottage wall, 5 roof, 7 rail
inline float2 lw_lighthouse(float3 p) {
    float3 q = p - float3(LW_LH.x, LW_PAD, LW_LH.y);
    float res = 1e5, mat = 0.0;
    // tapered tower
    {
        float y = clamp(q.y / LW_TWR, 0.0, 1.0);
        float r = mix(LW_R0, LW_R1, y);
        float d = max(length(q.xz) - r, max(-q.y - 1.5, q.y - LW_TWR)) * 0.95;
        if (d < res) { res = d; mat = 1.0; }
        float dpl = lw_sdCylY(q, LW_R0 + 0.55, -2.0, 1.4);      // plinth
        if (dpl < res) { res = dpl; mat = 1.0; }
        float band = lw_sdCylY(q, LW_R1 + 0.35, LW_TWR - 1.6, LW_TWR - 0.9);   // corbel under the gallery
        if (band < res) { res = band; mat = 1.0; }
    }
    // gallery deck + railing
    {
        float d = lw_sdCylY(q, 3.35, LW_TWR - 0.15, LW_TWR + 0.3);
        if (d < res) { res = d; mat = 2.0; }
        float3 rq = q - float3(0.0, LW_TWR + 1.25, 0.0);
        float ring = length(float2(length(rq.xz) - 3.25, rq.y)) - 0.05;
        float ring2 = length(float2(length(rq.xz) - 3.25, rq.y + 0.5)) - 0.035;
        float a = atan2(q.z, q.x);
        float sec = TAU / 30.0;
        float ai = (floor(a / sec) + 0.5) * sec;
        float2 pp = float2(cos(ai), sin(ai)) * 3.25;
        float post = max(length(q.xz - pp) - 0.04, abs(q.y - (LW_TWR + 0.78)) - 0.5);
        float rail = min(min(ring, ring2), post);
        if (rail < res) { res = rail; mat = 7.0; }
    }
    // lantern room
    {
        float yb = LW_TWR + 0.3;
        float base = lw_sdCylY(q, 2.05, yb, yb + 0.9);
        if (base < res) { res = base; mat = 2.0; }
        float glass = lw_sdCylY(q, 1.9, yb + 0.9, yb + 3.9);
        if (glass < res) { res = glass; mat = 3.0; }
        // dome
        float3 dq = q - float3(0.0, yb + 3.9, 0.0);
        float dome = max(length(dq * float3(1.0, 1.45, 1.0)) - 2.2, -dq.y);
        dome = min(dome, lw_sdCylY(q, 2.3, yb + 3.85, yb + 4.05));
        if (dome < res) { res = dome * 0.8; mat = 2.0; }
        float ball = length(q - float3(0.0, yb + 5.55, 0.0)) - 0.3;
        float rod = lw_sdCylY(q, 0.04, yb + 5.5, yb + 6.8);
        float top = min(ball, rod);
        if (top < res) { res = top; mat = 2.0; }
    }
    return float2(res, mat);
}

inline float3 lw_cottageLocal(float3 p) {
    float3 c = float3(LW_LH.x - 19.0, LW_PAD, LW_LH.y - 6.0);
    float3 q = p - c;
    float2 cs = float2(cos(0.12), sin(0.12));
    q.xz = float2(cs.x * q.x - cs.y * q.z, cs.y * q.x + cs.x * q.z);
    return q;
}
inline float2 lw_cottage(float3 p) {
    float3 q = lw_cottageLocal(p);
    float res = 1e5, mat = 0.0;
    float wall = lw_sdBox(q - float3(0.0, 1.6, 0.0), float3(6.5, 3.2, 3.6));
    if (wall < res) { res = wall; mat = 4.0; }
    float3 rq = q - float3(0.0, 4.8, 0.0);
    float roofSolid = max(abs(rq.z) * 0.78 + rq.y * 0.62 - 2.4, max(abs(rq.x) - 6.9, -rq.y));
    if (roofSolid < res) { res = roofSolid; mat = 5.0; }
    float ch = lw_sdBox(q - float3(3.8, 6.6, 0.4), float3(0.45, 1.4, 0.45));
    if (ch < res) { res = ch; mat = 4.0; }
    float an = lw_sdBox(q - float3(8.9, 1.3, 0.6), float3(2.5, 2.3, 2.7));
    if (an < res) { res = an; mat = 4.0; }
    float3 aq = q - float3(8.9, 3.6, 0.6);
    float aroof = max(abs(aq.z) * 0.7 + aq.y * 0.71 - 2.05, max(abs(aq.x) - 2.7, -aq.y));
    if (aroof < res) { res = aroof; mat = 5.0; }
    return float2(res, mat);
}

inline float2 lw_objects(float3 p) {
    float2 a;
    float3 lq = p - float3(LW_LH.x, LW_PAD + LW_TWR * 0.5, LW_LH.y);
    lq.y *= 0.16;   // squash → bounding ellipsoid around the tall tower
    float bl = length(lq);
    if (bl < 6.5) a = lw_lighthouse(p); else a = float2((bl - 5.0) * 0.9, 0.0);
    float3 cq = p - float3(LW_LH.x - 14.0, LW_PAD + 3.5, LW_LH.y - 6.0);
    float bc = length(cq);
    float2 b = bc < 18.0 ? lw_cottage(p) : float2(bc - 16.0, 0.0);
    return a.x < b.x ? a : b;
}

// ------------------------------------------------------------ scene march
// returns (t, mat) with mat 0 terrain, >0 objects; t < 0 = miss
inline float2 lw_march(float3 ro, float3 rd, float tmax, int lod) {
    float2 lr = lw_landRange(ro, rd);
    float tObj0 = 1e9, tObj1 = -1e9;
    {   // bounding sphere of the buildings
        float3 c = float3(LW_LH.x - 6.0, LW_PAD + 22.0, LW_LH.y - 3.0);
        float3 oc = ro - c;
        float b = dot(oc, rd), cc = dot(oc, oc) - 32.0 * 32.0;
        float disc = b * b - cc;
        if (disc > 0.0) { float sq = sqrt(disc); tObj0 = max(-b - sq, 0.0); tObj1 = -b + sq; }
    }
    float tStart = min(lr.x, tObj0);
    float tEnd = min(max(lr.y, tObj1), tmax);
    if (tStart > tEnd) return float2(-1.0, -1.0);
    float t = max(tStart, 0.3);
    float tPrev = t;
    float dTprev = 1e5;
    for (int i = 0; i < 110; i++) {
        float3 p = ro + rd * t;
        if (p.y > 48.0 && rd.y > 0.0 && (t > tObj1)) break;
        bool inLand = t >= lr.x && t <= lr.y;
        bool inObj = t >= tObj0 && t <= tObj1;
        float dT = 1e5, c = 1e5;
        bool empty = false; float advance = 0.0;
        if (inLand) {
            c = lw_coast(p.xz);
            if (c > 16.0) { empty = true; advance = max((c - 16.0) * 0.7, 0.4 + t * 0.006); }
            else { float h = lw_heightC(p.xz, c, lod); dT = (p.y - h) * 0.32; }
        }
        float2 o = float2(1e5, 0.0);
        if (inObj) o = lw_objects(p);
        // Well clear of any ground: advance without running the surface test, so the
        // marcher can never mistake this bookkeeping distance for a hit.
        if (empty && o.x > 1e4) {
            tPrev = t; dTprev = 1e5;
            t += advance;
            if (t > tEnd) break;
            continue;
        }
        // Outside every bounding volume: jump straight to the next one. (Clamping the
        // distance here instead would let the surface-hit test fire on the bounding
        // volume itself and draw a hairline along it.)
        if (!inLand && !inObj) {
            float tNext = 1e9;
            if (t < lr.x) tNext = min(tNext, lr.x);
            if (t < tObj0) tNext = min(tNext, tObj0);
            if (tNext > 1e8) break;
            t = tNext + 1e-3;
            tPrev = t; dTprev = 1e5;
            continue;
        }
        float d = min(dT, o.x);
        // objects carry hard silhouettes (roof ridge, eaves, railing) and need a much
        // tighter hit test than the terrain heightfield, or they stair-step against the sky
        float eps = (o.x < dT) ? (0.00035 * t + 0.0015) : (0.0015 * t + 0.003);
        if (d < eps) {
            float mat = o.x < dT ? o.y : 0.0;
            if (mat == 0.0 && dTprev > 0.0 && dT < 0.0) {
                float a = tPrev, b = t;
                for (int j = 0; j < 5; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    if (pm.y - lw_height(pm.xz, lod) < 0.0) b = m; else a = m;
                }
                t = 0.5 * (a + b);
            }
            return float2(t, mat);
        }
        tPrev = t; dTprev = dT;
        t += max(d, 0.02 + t * 0.002);
        if (t > tEnd) break;
    }
    return float2(-1.0, -1.0);
}

inline float3 lw_terrainNormal(float2 q, float t, int lod) {
    float e = max(0.03, t * 0.0015);
    float hx = lw_height(q + float2(e, 0.0), lod) - lw_height(q - float2(e, 0.0), lod);
    float hz = lw_height(q + float2(0.0, e), lod) - lw_height(q - float2(0.0, e), lod);
    return normalize(float3(-hx, 2.0 * e, -hz));
}
inline float3 lw_objNormal(float3 p) {
    float e = 0.004;
    float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * lw_objects(p + k.xyy * e).x + k.yyx * lw_objects(p + k.yyx * e).x +
                     k.yxy * lw_objects(p + k.yxy * e).x + k.xxx * lw_objects(p + k.xxx * e).x);
}

// ------------------------------------------------------------ sea
constant int LW_NW = 11;
// wave i: cycles per 20 s loop n (deep-water dispersion: lambda = g T^2 / 2pi, T = 20 s / n)
inline void lw_wave(int i, thread float2& dir, thread float& k, thread float& a, thread float& n, thread float& ph) {
    const float NS[11] = {2, 3, 4, 5, 6, 8, 10, 13, 17, 3, 5};
    const float AS[11] = {1.10, 0.78, 0.48, 0.28, 0.165, 0.092, 0.050, 0.029, 0.017, 0.40, 0.155};
    const float DA[11] = {0.05, -0.08, 0.12, -0.15, 0.22, -0.26, 0.30, -0.36, 0.42, 0.62, -0.72};
    const float PH[11] = {0.3, 2.1, 4.4, 1.2, 5.3, 0.7, 3.6, 2.9, 1.7, 4.0, 0.2};
    n = NS[i];
    float lam = 624.6 / (n * n);
    k = TAU / lam;
    float ang = 3.40 + DA[i];        // propagation azimuth: toward the camera, a little left
    dir = float2(sin(ang), cos(ang));
    a = AS[i];
    ph = PH[i];
}
// Stokes-like crest sharpening: f(th) = 2*((1+cos th)/2)^1.6 - 1
inline float lw_seaH(float2 x, float t, int nmax) {
    float h = 0.0;
    for (int i = 0; i < nmax; i++) {
        float2 dir; float k, a, n, ph;
        lw_wave(i, dir, k, a, n, ph);
        float th = dot(dir, x) * k - TAU * n * t + ph;
        float c = 0.5 + 0.5 * cos(th);
        h += a * (2.0 * pow(c, 1.6) - 1.0);
    }
    return h;
}
// normal (analytic swells + wind ripples), unresolved slope variance, swell surge (for foam)
inline float3 lw_seaN(float2 x, float t, float fp, thread float& var, thread float& surge) {
    float2 g = float2(0.0);
    var = 0.0002;
    surge = 0.0;
    for (int i = 0; i < LW_NW; i++) {
        float2 dir; float k, a, n, ph;
        lw_wave(i, dir, k, a, n, ph);
        float lam = TAU / k;
        float w = smoothstep(1.5, 4.0, lam / max(fp, 1e-4));
        float th = dot(dir, x) * k - TAU * n * t + ph;
        float c = 0.5 + 0.5 * cos(th);
        float st = a * k;
        var += (1.0 - w * w) * st * st * 0.6;
        float df = -1.6 * pow(c, 0.6) * sin(th);     // d/dth of 2 c^1.6 - 1
        g += dir * (a * k * df * w);
        if (i < 3) surge += a * (2.0 * pow(c, 1.6) - 1.0);
    }
    // wind ripples (loop-safe drifting noise), two scales
    float e = 0.35;
    float wr1 = smoothstep(2.5, 0.6, fp);          // ~2 m ripples
    float wr2 = smoothstep(0.9, 0.2, fp);          // ~0.6 m ripples
    if (wr1 > 0.0) {
        float2 q = x * 0.55;
        float2 dr = float2(1.8, -3.5);
        float n0 = lw_flow2(q, t, dr, 2);
        float nx = lw_flow2(q + float2(e * 0.55, 0.0), t, dr, 2);
        float nz = lw_flow2(q + float2(0.0, e * 0.55), t, dr, 2);
        g += float2(nx - n0, nz - n0) / (e * 0.55) * 0.022 * wr1;
    }
    if (wr2 > 0.0) {
        float2 q = x * 1.7 + 11.0;
        float n0 = gnoise(q), nx = gnoise(q + float2(0.1, 0.0)), nz = gnoise(q + float2(0.0, 0.1));
        g += float2(nx - n0, nz - n0) / 0.1 * 0.03 * wr2;
    }
    var += 0.0105 * (1.0 - wr1) + 0.0082 * (1.0 - wr2) + 0.0016;
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------ lighthouse beam
inline float3 lw_beamDir(float t, int b) {
    float phi = LW_PHI0 + TAU * t + (b == 1 ? PI : 0.0);
    return float3(sin(phi) * cos(LW_BEAM_EL), sin(LW_BEAM_EL), cos(phi) * cos(LW_BEAM_EL));
}
// angular profile of the beam for unit direction vn from the lamp
inline float lw_beamProfile(float3 vn, float3 D, float3 S, float3 U) {
    float along = dot(vn, D);
    if (along < 0.3) return 0.0;
    float ah = atan2(dot(vn, S), along), av = atan2(dot(vn, U), along);
    float core = exp(-0.5 * (ah * ah / (LW_SH * LW_SH) + av * av / (LW_SV * LW_SV)));
    float spine = 0.55 * exp(-0.5 * (ah * ah / (0.34 * LW_SH * LW_SH) + av * av / (0.5 * LW_SV * LW_SV)));
    float halo = 0.016 * exp(-0.5 * (ah * ah + av * av) / (LW_SHALO * LW_SHALO));
    float avd = av + 5.0 * DEG;
    float down = 0.055 * exp(-0.5 * (ah * ah / (3.0 * LW_SH * LW_SH) + avd * avd / (34.0 * DEG * DEG)));
    return core + spine + halo + down;
}
// scattering coefficient of the misty air (relative to LW_SIGS)
inline float lw_mist(float3 p, float t) {
    float hgt = exp(-max(p.y, 0.0) / 72.0);
    float n = lw_flow3(p * float3(0.022, 0.040, 0.022), t, float3(16.0, 1.0, 6.0), 3);
    float f = lw_flow3(p * float3(0.075, 0.110, 0.075) + 31.0, t, float3(9.0, 1.5, 3.0), 2);
    float d = 0.44 + 1.95 * n + 1.00 * f;
    // drifting low banks that sit on the sea and thin out with height
    d += 0.9 * exp(-max(p.y, 0.0) / 22.0) * smoothstep(-0.15, 0.45, lw_flow3(p * float3(0.010, 0.05, 0.010) + 7.0, t, float3(22.0, 0.0, 8.0), 2));
    return hgt * clamp(d, 0.10, 2.8);
}
// in-scattered beam light along the view ray segment [0, tEnd]; ns samples per beam
inline float3 lw_beamScatter(float3 ro, float3 rd, float tEnd, float t, float jit, int ns, float strength) {
    float3 L = lw_lamp();
    float3 sum = float3(0.0);
    float tc = dot(L - ro, rd);
    float3 pc = ro + rd * tc;
    float3 pv = pc - L;
    float d = max(length(pv), 0.05);
    float3 Ph = pv / d;                              // unit vector lamp → closest point on ray
    float th0 = atan2(0.0 - tc, d);
    float th1 = atan2(tEnd - tc, d);
    float3 N = normalize(cross(Ph, rd));             // normal of the plane (lamp, ray)
    for (int b = 0; b < 2; b++) {
        float3 D = lw_beamDir(t, b);
        float3 S = normalize(cross(D, float3(0.0, 1.0, 0.0)));
        float3 U = cross(S, D);
        float dn = dot(D, N);
        float delta = asin(clamp(abs(dn), 0.0, 1.0));   // closest angular approach of the beam axis to the ray plane
        float w = 4.4 * LW_SHALO;
        if (delta > w * 1.25) continue;
        float edge = 1.0 - smoothstep(w * 0.85, w * 1.25, delta);   // soft, so no hard screen-space seam
        float thStar = atan2(dot(D, rd), dot(D, Ph));
        // sample th over [thStar-w, thStar+w] warped as th = thStar + w*u|u| (u in [-1,1]),
        // with the interval CLAMPED to the visible span [th0, th1] — no per-sample rejection,
        // so nothing pops in and out between neighbouring pixels.
        float x0 = th0 - thStar, x1 = th1 - thStar;
        float ua = clamp(sign(x0) * sqrt(min(abs(x0) / w, 1.0)), -1.0, 1.0);
        float ub = clamp(sign(x1) * sqrt(min(abs(x1) / w, 1.0)), -1.0, 1.0);
        if (ub - ua < 1e-5) continue;
        float acc = 0.0;
        for (int i = 0; i < ns; i++) {
            // only a fraction of the per-pixel jitter: full decorrelation between
            // neighbouring pixels turned the smooth shaft into visible sensor-like speckle
            float jj = fract(jit * 0.26 + float(i) * 0.6180339887);
            float u = mix(ua, ub, (float(i) + jj) / float(ns));
            float th = thStar + w * u * abs(u);
            float jac = 2.0 * w * abs(u);            // dth/du
            float ts = tc + d * tan(th);
            float3 p = ro + rd * ts;
            float3 v = p - L;
            float r = length(v);
            float3 vn = v / max(r, 1e-3);
            float prof = lw_beamProfile(vn, D, S, U);
            if (prof < 1e-4) continue;
            // Striation. A real lens throws an uneven fan — panel joints, dust on the glass,
            // drifting density in the air — so the shaft is streaked, not airbrushed.
            {
                float al = dot(vn, D);
                float ah2 = atan2(dot(vn, S), al), av2 = atan2(dot(vn, U), al);
                float2 ag = float2(ah2, av2) * (1.0 / DEG);
                float n1 = lw_flow2(ag * 0.62 + float2(0.0, 5.0), t, float2(1.6, 0.4), 2);
                float n2 = lw_flow2(ag * 2.30 + float2(9.0, 1.0), t, float2(3.1, 0.8), 2);
                prof *= clamp(0.72 + 0.62 * n1 + 0.30 * n2, 0.16, 1.95);
            }
            float cosSc = dot(vn, -rd);
            float ph = 0.68 * lw_hg(cosSc, 0.62) + 0.32 * 0.0796;
            float sig = lw_mist(p, t);
            float tr = exp(-LW_SIGT * (r + ts));
            float near = r * r / (r * r + 4.0);
            // equiangular weight: (r^2 / d) per unit theta; integrand has 1/r^2 → 1/d
            acc += prof * ph * sig * tr * near * jac / (d * 0.50 + 40.0);
        }
        sum += float3(acc * ((ub - ua) / float(ns)) * edge);
    }
    return sum * (LW_SIGS * LW_IBEAM * strength);
}

// ------------------------------------------------------------ night sky
// Star field in (azimuth, altitude). Cells are sized so a star core lands at ~1.3 px
// at 2560x1600 / 36 deg vFOV — big enough not to scintillate in video, small enough
// to read as a point. Magnitude distribution is heavy-tailed so a few stars dominate.
inline float3 lw_stars(float2 sp, float t, float dense) {
    float3 col = float3(0.0);
    for (int L = 0; L < 3; L++) {
        float sc = 96.0 * (1.0 + 0.77 * float(L));
        float2 q = sp * sc + float2(31.7, 11.3) * float(L);
        float2 id = floor(q);
        float2 f = q - id - 0.5;
        float4 h = hash24(id + float2(7.0, 13.0) * float(L));
        float cut = mix(0.955, 0.760, dense);          // Milky Way is far denser
        if (h.x < cut) continue;
        float2 pos = (h.yz - 0.5) * 0.66;
        float d2 = dot(f - pos, f - pos);
        float mag = pow(h.w, 4.5);                      // few bright, many faint
        float sig = 0.048 + 0.030 * mag;
        float core = exp(-d2 / (sig * sig));
        // slow, shallow scintillation (integer cycles per loop -> loop safe)
        float tw = 0.86 + 0.14 * sin(TAU * (t * (1.0 + floor(h.y * 3.0)) + h.z));
        float3 tint = mix(float3(1.00, 0.80, 0.62), float3(0.70, 0.80, 1.00), smoothstep(0.15, 0.85, h.z));
        col += tint * core * (0.013 + 0.62 * mag) * tw;
    }
    return col;
}
// Faint Milky Way: a broad band of unresolved starlight split by a dark dust rift.
inline float lw_milkyBand(float3 rd) {
    float3 N = normalize(float3(0.246, 0.937, -0.254));
    float bd = dot(rd, N);
    float band = exp(-bd * bd / (2.0 * 0.115 * 0.115));
    // rift: a darker lane offset from the band axis
    float rift = 1.0 - 0.62 * exp(-(bd - 0.055) * (bd - 0.055) / (2.0 * 0.030 * 0.030));
    return band * rift;
}

// ------------------------------------------------------------ sky
inline float3 lw_sky(float3 rd, float3 md, float moonIll) {
    float h = clamp(rd.y, -0.05, 1.0);
    float3 zen = float3(0.0040, 0.0068, 0.0170);
    float3 hor = float3(0.0210, 0.0282, 0.0470);
    float3 col = mix(hor, zen, 1.0 - exp(-max(h, 0.0) * 3.0));
    // moon aureole (Mie forward scatter in thin haze)
    float mu = dot(rd, md);
    float ang = acos(clamp(mu, -1.0, 1.0));
    col += float3(0.055, 0.058, 0.070) * moonIll * (0.9 * exp(-ang / 0.05) + 0.35 * exp(-ang / 0.22) + 0.10 * exp(-ang / 0.7));
    // sea-mist glow near the horizon
    col += hor * 0.85 * exp(-max(h, 0.0) / 0.045);
    return col;
}

inline float3 lw_moonDisc(float3 rd, float3 md) {
    float c = dot(rd, md);
    float ang = acos(clamp(c, -1.0, 1.0));
    float rad = 0.26 * DEG;
    if (ang > rad * 1.6) return float3(0.0);
    // local disc coords
    float3 S = normalize(cross(md, float3(0.0, 1.0, 0.0)));
    float3 U = cross(S, md);
    float2 uv = float2(dot(rd, S), dot(rd, U)) / rad;
    float rr = dot(uv, uv);
    float disc = 1.0 - smoothstep(0.93, 1.05, sqrt(rr));
    float3 n = float3(uv, sqrt(max(0.0, 1.0 - rr)));
    float3 sun = normalize(float3(-0.86, -0.22, -0.46));     // sun behind and left → thin crescent
    float lit = max(dot(n, sun), 0.0);
    float phase = smoothstep(0.0, 0.25, lit);
    float3 albedo = float3(0.95, 0.92, 0.86) * (0.75 + 0.25 * gnoise(uv * 5.0));
    // earthshine on the dark limb
    return albedo * (phase * 9.0 + 0.07) * disc;
}

// Two cloud sheets seen in perspective: a broken stratocumulus deck at 1.4 km and a
// high thin veil at 5.2 km. Detail octaves fade out with distance so the deck never
// degenerates into uniform dapple near the horizon. Returns (rgb, alpha).
inline float4 lw_clouds(float3 ro, float3 rd, float t, float3 md, float3 moonCol, float3 amb, float mu) {
    if (rd.y < 0.010) return float4(0.0);
    float3 col = float3(0.0);
    float alpha = 0.0;
    for (int L = 0; L < 2; L++) {
        float H      = (L == 0) ? 5200.0 : 1420.0;
        float baseS  = (L == 0) ? 1.0 / 7200.0 : 1.0 / 2600.0;
        float2 drift = (L == 0) ? float2(760.0, 175.0) : float2(330.0, 76.0);
        float tc = (H - ro.y) / max(rd.y, 1e-4);
        if (tc > 120000.0) continue;
        float2 q = ro.xz + rd.xz * tc;
        // large slow domain warp: gives the sheet genuine weather-scale structure
        float2 wq = q + 430.0 * float2(gnoise(q * (baseS * 1.1) + float2(3.1, 1.7)),
                                       gnoise(q * (baseS * 1.1) + float2(8.3, 5.2)));
        float lodf = smoothstep(34000.0, 9000.0, tc);       // near enough to resolve detail
        float lodg = smoothstep(72000.0, 20000.0, tc);
        float lodh = smoothstep(11000.0, 3400.0, tc);
        // coverage bias: thicker weather far left / low, opening out over the upper right
        float bias = (L == 0 ? -0.215 : -0.190)
                   + 0.100 * smoothstep(2000.0, -14000.0, q.x)
                   - 0.075 * (1.0 - smoothstep(0.012, 0.075, rd.y))
                   - 0.105 * smoothstep(0.26, 0.70, rd.y) * smoothstep(-2000.0, 9000.0, q.x);
        float lo = (L == 0) ? -0.02 : 0.005, hi = (L == 0) ? 0.34 : 0.275;
        // second, turbulent warp: this is what tears the sheet's contours apart so the
        // deck stops reading as smooth painted ribbons
        if (lodg > 0.002) {
            float sw = baseS * 4.2;
            wq += (34.0 * lodg) * float2(gnoise(q * sw + float2(17.3, 4.1)),
                                         gnoise(q * sw + float2(1.9, 23.7)));
        }
        float base = lw_flow2(wq * baseS + float2(2.1, 0.6), t, drift * baseS, 5);
        // open sky: no detail octave can lift this cell over the threshold, so stop here
        if (base * 1.38 + bias < lo - 0.40) continue;
        float med  = lodg > 0.002 ? lw_flow2(wq * (baseS * 3.4) + float2(9.1, 3.2), t, drift * (baseS * 3.4), 3) : 0.0;
        float bil  = 1.0 - abs(med);                        // billow: puffy, not smooth
        float det  = lodf > 0.002 ? lw_flow2(wq * (baseS * 12.0) + float2(4.7, 8.8), t, drift * (baseS * 12.0), 3) : 0.0;
        float det2 = lodh > 0.002 ? lw_flow2(wq * (baseS * 34.0) + float2(6.2, 1.4), t, drift * (baseS * 34.0), 2) : 0.0;
        float cov = base * 1.38 + bias + 0.26 * (bil - 0.5) * lodg
                  + 0.165 * det * lodf + 0.085 * det2 * lodh;
        // soft, gradual optical thickness — cumulus edges feather, they do not cut
        float dens = smoothstep(lo, hi, cov);
        // erosion: ridged high-frequency noise eats the thin margins into rags and wisps,
        // weighted to where the sheet is already thin (a real cumulus edge is fractal)
        if (lodf > 0.002 && dens > 0.015 && dens < 0.99) {
            float er = lw_flow2(wq * (baseS * 19.0) + float2(12.9, 7.3), t, drift * (baseS * 19.0), 2);
            float rg = 1.0 - abs(er);
            dens = clamp(dens - rg * rg * 0.84 * (1.0 - dens) * lodf, 0.0, 1.0);
        }
        float fade = smoothstep(0.010, 0.050, rd.y);
        float a = (1.0 - exp(-2.3 * dens * dens)) * fade * (L == 0 ? 0.34 : 0.90);
        if (a < 0.0025) continue;
        // lighting: a thin crescent gives little; most of the luminance is the sheet's own
        // scattered skylight plus a silver edge where the cloud thins toward the moon
        float2 toMoon = normalize(md.xz + 1e-4) * (L == 0 ? 2600.0 : 950.0);
        float covM = lw_flow2((wq + toMoon) * baseS + float2(2.1, 0.6), t, drift * baseS, 3)
                   + 0.42 * (lodg > 0.002 ? lw_flow2((wq + toMoon) * (baseS * 3.4) + float2(9.1, 3.2), t, drift * (baseS * 3.4), 2) : 0.0) * lodg
                   + bias;
        float grad = clamp((cov - covM) * 2.6 + 0.5, 0.0, 1.0);
        float thin = 1.0 - dens;
        float fwd = lw_hg(mu, 0.58);
        // internal shading: the thick middle of a cell goes dark, the thin margins glow
        float shade = mix(1.15, 0.30, smoothstep(0.15, 0.95, dens));
        float3 c = amb * (0.30 + 0.70 * thin) * shade
                 + moonCol * (0.035 + 0.26 * grad) * (0.25 + 0.75 * thin) * shade
                 + moonCol * fwd * 1.15 * thin * dens;
        // the deck is lit a little from underneath by the same landward glow that fills the rock
        if (L == 1) c += LW_FILLC * 0.085 * (0.35 + 0.65 * thin) * shade;
        // composite: the veil is behind the deck
        col = col * (1.0 - a) + c * a;
        alpha = alpha * (1.0 - a) + a;
    }
    return float4(col / max(alpha, 1e-4), alpha);
}

// ------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float t = ctx.t;
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;

    // camera
    float kf = tan(LW_VFOV * 0.5 * DEG);
    float pitch = atan((1.0 - 2.0 * LW_HOR) * kf);
    float yaw = LW_YAW * DEG;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    float3 r = normalize(float3(cos(yaw), 0.0, -sin(yaw)));
    float3 u = cross(r, f);
    if (u.y < 0.0) u = -u;
    float3 rd = normalize(f + (p.x * r + p.y * u) * kf);
    float3 ro = LW_CAM;
    float pixA = 2.0 * kf / ctx.res.y;
    float jit = hash12(fragCoord * 1.37 + 0.123);

    float3 lamp = lw_lamp();
    float3 md = lw_moonDir();
    const float moonIll = 0.3;                               // crescent
    float3 moonCol = float3(0.80, 0.86, 1.0) * 0.11;          // moonlight irradiance
    float3 skyAmb = float3(0.010, 0.014, 0.026);              // mean sky radiance (upper hemisphere)
    float3 lampCol = float3(1.0, 0.86, 0.62);
    float3 winCol = float3(1.0, 0.50, 0.17);
    float3 sunV = float3(0.0);

    // ------------------------------------------------ sea intersection window
    float tSea0 = 1e9, tSea1 = 1e9;
    if (rd.y < -1e-4) { tSea0 = max((ro.y - 3.7) / -rd.y, 0.0); tSea1 = (ro.y + 3.7) / -rd.y; }

    // ------------------------------------------------ geometry
    float2 hit = lw_march(ro, rd, min(tSea1 + 12.0, 1400.0), 3);
    float tSea = -1.0;
    if (rd.y < -1e-4 && (hit.x < 0.0 || hit.x > tSea0)) {
        float t0 = tSea0, t1 = min(min(tSea1, 2600.0), hit.x > 0.0 ? hit.x : 1e9);
        float tp = t0;
        int N = 36;
        for (int i = 1; i <= N; i++) {
            float tt = mix(t0, t1, float(i) / float(N));
            float3 pp = ro + rd * tt;
            float dd = pp.y - lw_seaH(pp.xz, t, 6);
            if (dd < 0.0) {
                float a = tp, b = tt;
                for (int j = 0; j < 5; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    if (pm.y - lw_seaH(pm.xz, t, 6) < 0.0) b = m; else a = m;
                }
                tSea = 0.5 * (a + b);
                break;
            }
            tp = tt;
        }
        // beyond the search cap the swell is far below a pixel — fall back to the mean plane
        if (tSea < 0.0 && hit.x < 0.0) tSea = t1;
        if (tSea < 0.0 && hit.x > 0.0) {
            float3 hp = ro + rd * hit.x;
            if (hp.y < lw_seaH(hp.xz, t, 6) + 0.05) tSea = hit.x;
        }
    }

    float3 col;
    float tScene = 1e4;
    bool isSea = tSea > 0.0 && (hit.x < 0.0 || tSea < hit.x);
    float3 beamsD[2];
    float3 beamsS[2], beamsU[2];
    for (int b = 0; b < 2; b++) {
        beamsD[b] = lw_beamDir(t, b);
        beamsS[b] = normalize(cross(beamsD[b], float3(0.0, 1.0, 0.0)));
        beamsU[b] = cross(beamsS[b], beamsD[b]);
    }

    if (isSea) {
        tScene = tSea;
        float3 P = ro + rd * tSea;
        float fp = tSea * pixA / max(-rd.y, 0.03);
        fp = sqrt(fp * tSea * pixA);
        float var, surge;
        float3 n = lw_seaN(P.xz, t, fp, var, surge);
        float3 v = -rd;
        float nv = max(dot(n, v), 1e-3);
        float3 R = reflect(rd, n);
        R.y = abs(R.y) + 0.002;
        float F = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
        // reflected sky (no stars — the surface scatters them away)
        float3 refl = lw_sky(R, md, moonIll * 0.6);
        // dark headland reflection: cheap silhouette test along R
        {
            float2 lr = lw_landRange(P, R);
            // The distance cut on this test must be FADED, not switched: a hard cut is a
            // hard cut on a flat sea surface -> a dead-straight horizontal edge across the
            // water, because constant reflected distance is constant image row.
            float gate = 1.0 - smoothstep(680.0, 1150.0, lr.x);
            if (lr.x < lr.y && gate > 0.002) {
                float sh = 0.0;
                for (int i = 0; i < 10; i++) {
                    float tt = mix(lr.x, min(lr.y, 1150.0), (float(i) + 0.5) / 10.0);
                    float3 pp = P + R * tt;
                    if (pp.y < 50.0) {
                        float h = lw_height(pp.xz, 1);
                        sh = max(sh, smoothstep(-1.6, 1.6, h - pp.y));   // soft, fractional
                    }
                }
                refl = mix(refl, float3(0.0025, 0.0036, 0.0060), sh * 0.95 * gate);
            }
        }
        float3 body = float3(0.0035, 0.0085, 0.0125) + LW_FILLC * 0.012;
        float3 c0 = refl * F + body * (1.0 - F);
        // crest catch: slopes tilted toward the bright horizon band pick up a thread of light,
        // which is what actually makes a dark sea legible in a night photograph
        {
            float2 gz = float2(n.x, n.z);
            float tilt = clamp(-dot(normalize(gz + 1e-5), normalize(float2(rd.x, rd.z))) * length(gz) * 9.0, 0.0, 1.0);
            float horiz = exp(-max(R.y, 0.0) / 0.10);
            c0 += float3(0.0165, 0.0225, 0.0380) * tilt * horiz * 1.5 * F;
        }
        // glitter from the lamp, the windows and the moon (GGX with unresolved roughness)
        // Roughness floor grows with the pixel footprint: without it the GGX lobe stays
        // tighter than a pixel at mid range and the lamp highlight resolves into thin
        // uniform-width contour loops that read as scribbled-on foam.
        float a2 = clamp(var * 3.6 + 0.030 * smoothstep(0.10, 2.4, fp) + 0.004, 0.012, 0.45);
        {
            float3 Lv = lamp - P; float Ld = length(Lv); float3 Ln = Lv / Ld;
            float3 hv = normalize(Ln + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (PI * dd * dd);
            // lantern always glows; much brighter when a beam faces this point
            float face = 0.0;
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float I = 1500.0 + LW_IBEAM * 0.55 * face;
            float tr = exp(-LW_SIGT * Ld);
            float irr = I / (Ld * Ld) * max(dot(n, Ln), 0.0) * tr;
            c0 += lampCol * irr * D * F * 0.25 / max(nv, 0.05) * 0.5;
            // broad, soft sheen where the beam's pool lands — the water there is visibly lifted
            c0 += lampCol * irr * 0.024 * (0.25 + 0.75 * F);
        }
        {   // moon glitter — softened: at r0 this band out-shone the beam itself
            float am = clamp(a2 * 1.45, 0.016, 0.50);
            float3 hv = normalize(md + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (am - 1.0) + 1.0;
            float D = am / (PI * dd * dd);
            c0 += moonCol * 13.0 * moonIll * D * F * 0.25 * max(dot(n, md), 0.0) / max(nv, 0.05) * 0.5;
        }
        // foam where the swell meets rock
        float cst = lw_coast(P.xz);
        float foam = 0.0;
        if (cst < 16.0) {
            // run-up: the surge walks the foam line up and down the rock over the swell period
            float run = clamp(surge * 0.9, -1.0, 1.2);
            const float2 fdr = float2(2.6, -5.0);
            // advect the foam field, then threshold a genuinely multi-octave density:
            // patches then have fractal, varied-width edges instead of the constant-width
            // squiggle a narrow contour band of a smooth noise produces.
            float2 fq = P.xz;
            float w0 = lw_flow2(fq * 0.24, t, fdr * 0.24, 3);
            float w1 = lw_flow2(fq * 0.24 + 37.0, t, fdr * 0.24, 3);
            fq += (float2(w0, w1) - 0.5) * 11.0;
            float f2 = lw_flow2(fq * 0.85, t, fdr * 0.85, 4);
            float f3 = lw_flow2(fq * 3.10 + 17.0, t, fdr * 3.10, 3);
            float f4 = lw_flow2(fq * 9.60 + 5.0, t, fdr * 9.60, 2);
            float lace = f2 * 0.52 + f3 * 0.31 + f4 * 0.17;      // signed, ~[-1,1]
            // the surf band lowers the threshold; the noise decides the shape
            float edge = 3.2 + 3.8 * run;
            float band = smoothstep(edge + 8.5, edge - 2.4, cst) * smoothstep(-8.5, -1.0, cst);
            float thr = 0.42 - 0.62 * band;
            float soft = 0.085 + 0.150 * (1.0 - band);
            foam = smoothstep(thr, thr + soft, lace);
            foam *= 0.26 + 0.74 * band;
            // spent foam: a broad, low-opacity veil drifting seaward — no lines
            float veil = smoothstep(16.0, 4.0, cst) * smoothstep(0.06, 0.30, lace) * (0.20 + 0.26 * run);
            foam = max(foam, clamp(veil, 0.0, 0.34));
            foam *= smoothstep(7.0, 0.9, fp);
        }
        if (foam > 0.0) {
            float3 nf = n;
            float3 amb = skyAmb * PI * (0.6 + 0.4 * nf.y);
            float3 mo = moonCol * max(dot(nf, md), 0.0) * 1.2;
            float3 fl = LW_FILLC * 0.85;
            float3 Lv = lamp - P; float Ld2 = dot(Lv, Lv); float3 Ln = Lv * rsqrt(Ld2);
            float face = 0.0;
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float3 bl = lampCol * (2400.0 + LW_IBEAM * 0.55 * face) / Ld2 * max(dot(nf, Ln), 0.0) * exp(-LW_SIGT * sqrt(Ld2));
            // aerated water scatters strongly and is the brightest thing in a night surf photo
            float3 fc = float3(0.84, 0.87, 0.90) * (amb + mo + fl + bl) * (2.75 / PI);
            c0 = mix(c0, fc, foam * 0.74);
        }
        // beam reflected in the water
        // reflect about a flattened normal: the beam's mirror image is a broad glow on a
        // night sea, not a set of thin contour lines chasing the wave slope
        float3 nB = normalize(mix(float3(0.0, 1.0, 0.0), n, 0.34));
        float3 RB = reflect(rd, nB); RB.y = abs(RB.y) + 0.002;
        float3 bref = lw_beamScatter(P + float3(0.0, 0.05, 0.0), RB, 1500.0, t, jit, 10, 1.0);
        c0 += bref * lampCol * F * (1.0 - foam);
        // The nearest water was the brightest thing in frame and stole the beam's job;
        // hold it back so the eye goes to the tower.
        c0 *= 1.0 - 0.34 * smoothstep(170.0, 45.0, tSea);
        col = c0;
    } else if (hit.x > 0.0) {
        tScene = hit.x;
        float3 P = ro + rd * hit.x;
        float3 n;
        float3 alb;
        float3 emit = float3(0.0);
        float rough = 0.6;
        float spec = 0.03;
        if (hit.y == 0.0) {
            n = lw_terrainNormal(P.xz, hit.x, 3);
            // fine rock bump
            {
                float e = max(0.06, hit.x * 0.0015);
                float2 q = P.xz * 0.6;
                float b0 = fbm(q, 2), bx = fbm(q + float2(e * 0.6, 0.0), 2), bz = fbm(q + float2(0.0, e * 0.6), 2);
                float3 bn = normalize(float3(-(bx - b0), e * 0.6 * 1.2, -(bz - b0)));
                n = normalize(n + (bn - float3(0.0, 1.0, 0.0)) * 0.8 * smoothstep(210.0, 45.0, hit.x));
            }
            float slope = 1.0 - n.y;
            // --- bedded stratification -------------------------------------------------
            // Discrete beds of unequal thickness, gently dipping, with dark parting planes
            // and a set of cross joints. An evenly spaced sine (the r0 version) reads as a
            // comb of stripes; real strata have irregular thickness and their own tone.
            // texture LOD: sub-metre detail is smaller than a pixel past ~150 m and only
            // aliases into leopard-spot mottle if it is left switched on out there
            float dFine = smoothstep(240.0, 85.0, hit.x);
            float bslope = smoothstep(0.022, 0.21, slope);              // faces, not the cap
            float outcrop = smoothstep(0.30, 0.72, 0.5 + 0.5 * gnoise(P.xz * 0.028 + 9.1));
            float bexp = bslope * (0.55 + 0.45 * outcrop);
            float dip = 0.048 * P.x + 0.026 * P.z;                      // beds dip a few degrees
            float bp = (P.y + dip) * 0.68 + 1.55 * gnoise(P.xz * 0.030) + 0.42 * gnoise(P.xz * 0.145);
            float bi = floor(bp);
            float bu = bp - bi;
            float3 bh = hash33(float3(bi, 3.7, 1.3));
            bu = pow(bu, 0.50 + 1.25 * bh.x);                           // unequal bed thickness
            float bedTone = 0.74 + 0.54 * bh.y;
            float parting = smoothstep(0.11, 0.0, bu) + smoothstep(0.90, 1.0, bu);
            float strata = bedTone * (1.0 - 0.46 * parting);
            // cross joints: near-vertical fractures at irregular spacing
            float jp = (P.x * 0.285 - P.z * 0.165) + 1.15 * gnoise(P.xz * 0.075) + 0.06 * P.y;
            float joint = smoothstep(0.085, 0.012, abs(jp - floor(jp) - 0.5)) * (0.45 + 0.55 * bh.z);
            float3 rock = mix(float3(0.168, 0.158, 0.148), float3(0.430, 0.404, 0.370), strata * strata);
            rock *= mix(1.0, 0.55, joint * bexp);
            // tonal variation at a scale a pixel can still resolve at 250 m
            rock *= 0.80 + 0.40 * fbm(P.xz * 0.17 + P.y * 0.11, 3);
            // sub-metre grit: near rock only
            rock *= mix(1.0, 0.80 + 0.40 * fbm(P.xz * 0.9 + P.y * 0.5, 3), dFine);
            rock = mix(float3(0.285, 0.272, 0.253) * (0.84 + 0.32 * fbm(P.xz * 0.30, 3)), rock, bexp);
            // parting planes are ledges: they tilt up and catch the grazing light, which is
            // what actually makes bedding legible on a backlit cliff
            {
                float ledge = smoothstep(0.50, 0.97, parting) * bexp;
                n = normalize(n + float3(0.0, 1.0, 0.0) * ledge * 0.78
                                + float3(n.x, 0.0, n.z) * (joint * bexp * -0.30));
            }
            float3 grass = mix(float3(0.118, 0.140, 0.076), float3(0.150, 0.132, 0.086),
                               smoothstep(0.30, 0.72, 0.5 + 0.5 * gnoise(P.xz * 0.055 + 2.3)));
            grass *= max(0.24, 0.72 + 0.62 * fbm(P.xz * 0.115 + 1.7, 3));
            grass *= mix(1.0, 0.78 + 0.44 * fbm(P.xz * 0.55, 3), dFine);
            float g = smoothstep(0.42, 0.14, slope) * smoothstep(5.0, 10.0, P.y) * (0.55 + 0.45 * gnoise(P.xz * 0.3));
            alb = mix(rock, grass, g);
            float wet = smoothstep(3.4, 0.4, P.y);
            // barnacle / lichen mottling and a pale splash zone just above the waterline
            float mott = mix(1.0, 0.72 + 0.56 * fbm(P.xz * 1.9 + P.y * 0.7, 3), dFine);
            alb *= mott;
            float splash = smoothstep(0.4, 1.9, P.y) * smoothstep(4.6, 2.4, P.y)
                         * smoothstep(0.35, 0.75, 0.5 + 0.5 * gnoise(P.xz * 1.1));
            alb = mix(alb, float3(0.52, 0.51, 0.47), splash * 0.55);
            alb *= mix(1.0, 0.40, wet);
            rough = mix(0.62, 0.14, wet);
            spec = mix(0.03, 0.075, wet);
        } else {
            n = lw_objNormal(P);
            int m = int(hit.y + 0.5);
            alb = m == 1 ? float3(0.80, 0.78, 0.74) : (m == 2 || m == 7) ? float3(0.05, 0.05, 0.055) : m == 3 ? float3(0.02) : m == 4 ? float3(0.70, 0.66, 0.60) : float3(0.14, 0.07, 0.05);
            if (m == 1) {
                // masonry: subtle stone texture + red band near the top
                float3 q = P - float3(LW_LH.x, LW_PAD, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float tex = 0.88 + 0.12 * gnoise(float2(ang * 6.0, q.y * 0.8));
                // stone courses: a faint horizontal ruling, and blotchy weathering / salt staining
                // individual courses: each ring of stone has its own value and its own
                // polish, so the shaft is not one smooth CG cylinder in a close crop
                float cy = q.y * 1.35;
                float ci = floor(cy);
                float3 ch = hash33(float3(ci, 4.1, 2.6));
                float course = 0.955 + 0.045 * smoothstep(0.05, 0.16, abs(cy - ci - 0.5));
                course *= 0.93 + 0.14 * ch.x;
                float weather = 0.82 + 0.18 * fbm(float2(ang * 3.0, q.y * 0.35) * 1.6, 3);
                alb *= tex * course * weather;
                spec = 0.028 + 0.030 * ch.y;
                alb *= mix(0.62, 1.0, smoothstep(0.0, 9.0, q.y));    // damp, darker at the foot
                float band = smoothstep(2.1, 1.6, abs(q.y - (LW_TWR - 6.2)));
                alb = mix(alb, float3(0.40, 0.085, 0.065), band * 0.92);
                rough = 0.62;
                // small slit windows on the seaward/camera face
                float3 toCam = normalize(float3(-LW_LH.x, 0.0, -LW_LH.y));
                float facing = dot(normalize(float3(q.x, 0.0, q.z)), toCam);
                float pwT = max(hit.x * pixA, 0.012);
                for (int wI = 0; wI < 3; wI++) {
                    float wy = 9.0 + 10.5 * float(wI);
                    float lat = length(float2(dot(float2(q.x, q.z), float2(-toCam.z, toCam.x)), 0.0));
                    float win = smoothstep(0.55 + pwT, 0.55 - pwT, abs(q.y - wy))
                              * smoothstep(0.30 + pwT, 0.30 - pwT, lat)
                              * smoothstep(0.45, 0.58, facing);
                    emit += winCol * 0.95 * win;
                }
                // a little more landward fill on the shaft so the tower stays legible
                // against the black sky at wallpaper-thumbnail scale
                alb *= 1.06;
            }
            if (m == 3) {
                // lantern glass: bright with the lens, mullions dark
                float3 q = P - float3(LW_LH.x, LW_PAD + LW_TWR + 1.2, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float pwL = max(hit.x * pixA, 0.010) * 1.2;
                float mull = smoothstep(0.44 + 0.06, 0.44 - 0.06, abs(fract(ang / TAU * 12.0) - 0.5))
                           * smoothstep(1.35 + pwL, 1.35 - pwL, abs(q.y - 1.6))
                           * smoothstep(0.08 - pwL, 0.08 + pwL, abs(q.y - 1.6));
                float3 toCam = normalize(ro - P);
                float face = 0.0;
                for (int b = 0; b < 2; b++) face += lw_beamProfile(toCam, beamsD[b], beamsS[b], beamsU[b]);
                emit = lampCol * (2.2 + 45.0 * face) * mull;
                alb = float3(0.02);
                rough = 0.2;
            }
            if (m == 4) {
                float3 q = lw_cottageLocal(P);
                // windows on the long front (-z) face and the annex
                float pwC = max(hit.x * pixA, 0.010);
                float wx = fract((q.x + 6.5) / 3.25) - 0.5;
                float win = smoothstep(0.19 + pwC / 3.25, 0.19 - pwC / 3.25, abs(wx))
                          * smoothstep(0.6 + pwC, 0.6 - pwC, abs(q.y - 1.8))
                          * smoothstep(-3.5 + pwC, -3.5 - pwC, q.z)
                          * smoothstep(6.0 + pwC, 6.0 - pwC, abs(q.x));
                float wa = smoothstep(0.55 + pwC, 0.55 - pwC, abs(q.x - 8.9))
                         * smoothstep(0.5 + pwC, 0.5 - pwC, abs(q.y - 1.6))
                         * smoothstep(-2.6 + pwC, -2.6 - pwC, q.z);
                float wglow = smoothstep(2.10, 0.28, abs(wx) * 3.25) * smoothstep(2.3, 0.45, abs(q.y - 1.8))
                            * step(q.z, -3.4) * smoothstep(6.6, 5.6, abs(q.x));
                emit = winCol * (1.7 * max(win, wa) + 0.34 * wglow);
                alb *= 0.92 + 0.08 * gnoise(q.xy * 2.0);
            }
            if (m == 5) { rough = 0.5; alb *= 0.8 + 0.2 * gnoise(P.xz * 1.5); }
        }
        // lighting: sky ambient + moon + landward glow + lamp spill + beams + window spill
        float3 amb = skyAmb * PI * (0.55 + 0.45 * n.y);
        float3 mo = moonCol * max(dot(n, md), 0.0);
        // soft wrapped fill from the landward sky glow behind the camera
        const float3 fillD = normalize(float3(0.20, 0.40, -0.89));
        float3 fill = LW_FILLC * (0.10 + 0.90 * max(dot(n, fillD) * 0.85 + 0.15, 0.0));
        float3 Lv = lamp - P;
        float Ld2 = dot(Lv, Lv);
        float Ld = sqrt(Ld2);
        float3 Ln = Lv / Ld;
        float nl = max(dot(n, Ln), 0.0);
        float face = 0.0;
        for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
        // lantern spill: strong just below the lantern (gallery, tower top), 1/r^2 beyond
        float spill = 1400.0 / (Ld2 + 2.0);
        float3 lampL = lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * nl * exp(-LW_SIGT * Ld);
        // gallery wash — light spilling out under the lantern, down the tower and over the pad
        {
            float3 gp = lamp - float3(0.0, 2.6, 0.0);
            float3 Gv = gp - P; float Gd2 = dot(Gv, Gv); float3 Gn = Gv * rsqrt(Gd2);
            float aim = smoothstep(-0.25, 0.85, -Gn.y);         // points downward
            lampL += lampCol * 520.0 * aim / (Gd2 + 9.0) * (0.30 + 0.70 * max(dot(n, Gn), 0.0)) * ((hit.y == 2.0 || hit.y == 7.0) ? 0.45 : 1.0);
        }
        // cottage window spill onto the ground
        float3 wpos = float3(LW_LH.x - 19.0, LW_PAD + 1.8, LW_LH.y - 6.0) + float3(0.0, 0.0, -4.0);
        float3 Wv = wpos - P; float Wd2 = dot(Wv, Wv);
        float3 winL = winCol * 6.0 / (Wd2 + 1.0) * max(dot(n, Wv * rsqrt(Wd2)), 0.0);
        float3 diff = alb * (amb + mo + fill + lampL + winL) / PI;
        // specular (wet rock, masonry): Blinn-Phong-ish with the lamp and the moon
        float3 v = -rd;
        float3 hL = normalize(Ln + v), hM = normalize(md + v);
        float shin = 2.0 / (rough * rough) - 2.0;
        float sL = pow(max(dot(n, hL), 0.0), shin) * (shin + 8.0) / (8.0 * PI);
        float sM = pow(max(dot(n, hM), 0.0), shin) * (shin + 8.0) / (8.0 * PI);
        float fr = spec + (1.0 - spec) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
        float3 specC = fr * (lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * nl * sL * exp(-LW_SIGT * Ld) + moonCol * max(dot(n, md), 0.0) * sM);
        // cold moon rim along silhouette edges — reads the tower against the sky
        float rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.5) * smoothstep(-0.1, 0.5, dot(n, md));
        float rimK = (hit.y == 1.0) ? 0.115 : (0.058 + 0.075 * smoothstep(260.0, 60.0, hit.x));
        col = diff + specC + emit + float3(0.42, 0.50, 0.66) * rim * rimK * (0.35 + 0.65 * alb.g);
    } else {
        // sky
        float3 sky = lw_sky(rd, md, moonIll);
        float2 sp = float2(atan2(rd.x, rd.z), asin(clamp(rd.y, -1.0, 1.0)));
        float mw = lw_milkyBand(rd);
        // Milky Way: unresolved starlight, clumped by a slow fbm, plus a dust rift
        {
            float tex = 0.55 + 0.50 * fbm(sp * 7.5 + float2(3.3, 1.9), 4);
            sky += float3(0.0300, 0.0318, 0.0400) * mw * tex * smoothstep(0.02, 0.30, rd.y);
        }
        float3 stars = lw_stars(sp, t, mw);
        // stars drown in the horizon mist glow and in the moon aureole
        float aur = 1.0 - 0.75 * exp(-acos(clamp(dot(rd, md), -1.0, 1.0)) / 0.20);
        float starMask = smoothstep(0.012, 0.135, rd.y) * aur;
        float mu = dot(rd, md);
        float4 cl = lw_clouds(ro, rd, t, md, moonCol * 9.0, skyAmb * 1.5, mu);
        float3 moon = lw_moonDisc(rd, md);
        col = sky + (stars * starMask + moon) * (1.0 - cl.a);
        col = mix(col, cl.rgb, cl.a);
        tScene = 3000.0;
    }

    // aerial perspective / mist (night: faint blue haze)
    {
        float fogA = ws_fogAmount(min(tScene, 3000.0), ro, rd, 0.0011, 0.018);
        float3 fogC = lw_sky(normalize(float3(rd.x, 0.03, rd.z)), md, moonIll) * 0.9;
        col = mix(col, fogC, fogA * (isSea || hit.x > 0.0 ? 1.0 : 0.35));
    }

    // lighthouse beams (volumetric)
    float3 beam = lw_beamScatter(ro, rd, min(tScene, 2500.0), t, jit, 17, 1.0);
    col += beam * lampCol;

    // lantern glow / flare
    {
        float3 lv = normalize(lamp - ro);
        float ang = acos(clamp(dot(rd, lv), -1.0, 1.0));
        float fl = 0.0;
        for (int b = 0; b < 2; b++) fl += lw_beamProfile(-lv, beamsD[b], beamsS[b], beamsU[b]);
        float occl = (hit.x > 0.0 && hit.x < length(lamp - ro) - 4.0) ? 0.35 : 1.0;   // partially hidden behind terrain
        // veiling glare, with a touch of lateral chromatic dispersion: the outer skirt of
        // the halo runs warm on the inside and cool on the outside, the way a real fast
        // lens throws a bright point source
        float3 kc = float3(1.045, 1.000, 0.952);
        float3 glow = float3(0.0);
        for (int c = 0; c < 3; c++) {
            float a = ang / kc[c];
            glow[c] = 0.9 * exp(-a / 0.0025) + 0.16 * exp(-a / 0.012) + 0.05 * exp(-a / 0.06) + 0.012 * exp(-a / 0.25);
        }
        glow *= lampCol * (0.05 + 1.0 * fl);
        // a single faint internal reflection (ghost) opposite the source through frame centre
        {
            float3 gh = normalize(f * 2.0 - lv);
            float ga = acos(clamp(dot(rd, gh), -1.0, 1.0));
            glow += lampCol * float3(0.85, 0.95, 1.05) * fl * 0.010 * exp(-ga / 0.030);
        }
        col += glow * occl;
    }

    col *= LW_EXPO;
    // a touch more falloff along the bottom edge keeps the Dock strip calm
    {
        float2 uv = fragCoord / ctx.res;
        col *= ws_vignette(uv, 0.13);
        col *= 1.0 - 0.40 * smoothstep(0.30, 0.0, uv.y);
    }
    // Film/sensor grain. A real long exposure at this level is noisiest in the deep
    // shadows and cleanest in the highlights, so weight it by luminance.
    {
        float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
        float amp = 0.0088 * (1.0 - 0.68 * smoothstep(0.015, 0.30, lum));
        float g = ws_grain(fragCoord, t);
        float gc = ws_grain(fragCoord + float2(311.0, 97.0), t);
        col += (g + float3(0.30, -0.12, 0.34) * gc * 0.5) * amp;
    }
    return ws_acesFitted(max(col, 0.0));
}
