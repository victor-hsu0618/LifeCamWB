/*
 * lifecam_wb.c — White balance control for Microsoft LifeCam on macOS
 *
 * Uses CoreMediaIO (CMIO) — the Apple UVCAssistant daemon owns the USB
 * interface; raw IOKit USB requests are blocked on macOS 12+.
 *
 * Build:
 *   clang -o lifecam_wb lifecam_wb.c \
 *       -framework CoreMediaIO -framework CoreFoundation
 *
 * Usage:
 *   ./lifecam_wb dump        — list every CMIO control with its values
 *   ./lifecam_wb get
 *   ./lifecam_wb set <K>     — 2800/4000/5500/6500
 *   ./lifecam_wb auto <0|1>
 *
 * Camera permission must be granted to Terminal in
 *   System Settings → Privacy & Security → Camera
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMediaIO/CMIOHardware.h>

/* AudioValueRange (from CoreAudio — avoid importing the whole framework) */
typedef struct { double mMinimum; double mMaximum; } AVR;

/* ── CMIO helpers ───────────────────────────────────────────────────────── */
#define ADDR(sel) ((CMIOObjectPropertyAddress){ \
    (sel), kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain })

static OSStatus cmio_size(CMIOObjectID o, CMIOObjectPropertySelector s, UInt32 *sz)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectGetPropertyDataSize(o, &a, 0, NULL, sz);
}
static OSStatus cmio_get(CMIOObjectID o, CMIOObjectPropertySelector s,
                          void *data, UInt32 sz)
{
    CMIOObjectPropertyAddress a = ADDR(s); UInt32 got = sz;
    return CMIOObjectGetPropertyData(o, &a, 0, NULL, sz, &got, data);
}
static OSStatus cmio_set(CMIOObjectID o, CMIOObjectPropertySelector s,
                          const void *data, UInt32 sz)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectSetPropertyData(o, &a, 0, NULL, sz, data);
}
static bool cmio_has(CMIOObjectID o, CMIOObjectPropertySelector s)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectHasProperty(o, &a);
}
static CMIOClassID cmio_class(CMIOObjectID o)
{
    CMIOClassID c = 0; cmio_get(o, kCMIOObjectPropertyClass, &c, sizeof c); return c;
}
static CMIOObjectID *cmio_owned(CMIOObjectID o, UInt32 *cnt)
{
    UInt32 sz = 0;
    if (cmio_size(o, kCMIOObjectPropertyOwnedObjects, &sz) || !sz)
        { *cnt = 0; return NULL; }
    CMIOObjectID *ids = malloc(sz);
    cmio_get(o, kCMIOObjectPropertyOwnedObjects, ids, sz);
    *cnt = sz / sizeof(CMIOObjectID); return ids;
}
static void cmio_name_cstr(CMIOObjectID o, char *buf, int len)
{
    CFStringRef cf = NULL;
    cmio_get(o, kCMIOObjectPropertyName, &cf, sizeof cf);
    buf[0] = 0;
    if (cf) { CFStringGetCString(cf, buf, len, kCFStringEncodingUTF8); CFRelease(cf); }
}

/* four-char-code → printable string */
static const char *fcc(CMIOClassID c)
{
    static char b[8];
    b[0]=(c>>24)&0xFF; b[1]=(c>>16)&0xFF; b[2]=(c>>8)&0xFF; b[3]=c&0xFF; b[4]=0;
    for(int i=0;i<4;i++) if(b[i]<32||b[i]>126) b[i]='?';
    return b;
}

/* ── Find LifeCam CMIO device ───────────────────────────────────────────── */
static CMIOObjectID find_lifecam(void)
{
    UInt32 sz = 0;
    if (cmio_size(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, &sz)) return 0;
    int n = sz / sizeof(CMIOObjectID);
    CMIOObjectID devs[n];
    cmio_get(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, devs, sz);
    for (int i = 0; i < n; i++) {
        char name[128]; cmio_name_cstr(devs[i], name, sizeof name);
        if (strcasestr(name, "LifeCam")) {
            printf("CMIO device: \"%s\" (id=%u)\n", name, devs[i]);
            return devs[i];
        }
    }
    return 0;
}

/* ── Recursively find control by class ──────────────────────────────────── */
__attribute__((unused))
static CMIOObjectID find_ctrl(CMIOObjectID parent, CMIOClassID target, int depth)
{
    if (depth > 2) return 0;
    UInt32 cnt = 0; CMIOObjectID *ch = cmio_owned(parent, &cnt);
    if (!ch) return 0;
    CMIOObjectID found = 0;
    for (UInt32 i = 0; i < cnt && !found; i++) {
        if (cmio_class(ch[i]) == target) found = ch[i];
        else found = find_ctrl(ch[i], target, depth+1);
    }
    free(ch); return found;
}

/* ── Read/write feature control values ─────────────────────────────────── */
/* Try NativeValue (Float32) first; many UVC controls use it */
static bool ctrl_get_float(CMIOObjectID ctrl, CMIOObjectPropertySelector sel,
                             float *out)
{
    if (!cmio_has(ctrl, sel)) return false;
    Float32 v = 0;
    if (cmio_get(ctrl, sel, &v, sizeof v)) return false;
    *out = v; return true;
}

/* NativeData: for UVC multi-byte controls CMIO stores raw bytes.
 * White balance temperature is 2 bytes (uint16, Kelvin).
 * In NativeData format it's typically padded to 4 bytes.              */
static bool ctrl_get_nd_u16(CMIOObjectID ctrl, uint16_t *out)
{
    if (!cmio_has(ctrl, kCMIOFeatureControlPropertyNativeData)) return false;
    UInt32 sz = 0;
    if (cmio_size(ctrl, kCMIOFeatureControlPropertyNativeData, &sz)) return false;
    uint8_t buf[16] = {};
    if (sz > 16 || cmio_get(ctrl, kCMIOFeatureControlPropertyNativeData, buf, sz))
        return false;
    /* first 2 bytes are the 16-bit UVC value (little-endian) */
    *out = (uint16_t)(buf[0] | (buf[1] << 8));
    return true;
}
static bool ctrl_set_nd_u16(CMIOObjectID ctrl, uint16_t val)
{
    if (!cmio_has(ctrl, kCMIOFeatureControlPropertyNativeData)) return false;
    UInt32 sz = 0;
    if (cmio_size(ctrl, kCMIOFeatureControlPropertyNativeData, &sz)) return false;
    uint8_t buf[16] = {};
    if (sz > 16) return false;
    buf[0] = val & 0xFF; buf[1] = (val >> 8) & 0xFF;
    return cmio_set(ctrl, kCMIOFeatureControlPropertyNativeData, buf, sz) == 0;
}

/* ── dump command ────────────────────────────────────────────────────────── */
static void dump_ctrl(CMIOObjectID obj, int indent)
{
    CMIOClassID cls = cmio_class(obj);
    char name[128]; cmio_name_cstr(obj, name, sizeof name);
    printf("%*sid=%-5u  class='%s'  \"%s\"\n", indent*2, "", obj, fcc(cls), name);

    /* NativeValue (Float32) */
    float nv;
    if (ctrl_get_float(obj, kCMIOFeatureControlPropertyNativeValue, &nv))
        printf("%*s  NativeValue = %.3f\n", indent*2, "", nv);

    /* AutomaticManual */
    if (cmio_has(obj, kCMIOFeatureControlPropertyAutomaticManual)) {
        UInt32 av = 0;
        cmio_get(obj, kCMIOFeatureControlPropertyAutomaticManual, &av, sizeof av);
        printf("%*s  AutoManual  = %u\n", indent*2, "", av);
    }

    /* NativeRange (AudioValueRange = two Float64) */
    if (cmio_has(obj, kCMIOFeatureControlPropertyNativeRange)) {
        AVR r = {}; cmio_get(obj, kCMIOFeatureControlPropertyNativeRange, &r, sizeof r);
        printf("%*s  NativeRange = [%.0f, %.0f]\n", indent*2, "", r.mMinimum, r.mMaximum);
    }

    /* NativeData (raw UVC bytes) */
    if (cmio_has(obj, kCMIOFeatureControlPropertyNativeData)) {
        UInt32 sz = 0; cmio_size(obj, kCMIOFeatureControlPropertyNativeData, &sz);
        uint8_t buf[16] = {};
        if (sz <= 16 && !cmio_get(obj, kCMIOFeatureControlPropertyNativeData, buf, sz)) {
            printf("%*s  NativeData  = [", indent*2, "");
            for (UInt32 j = 0; j < sz; j++) printf("%s%02x", j?",":"", buf[j]);
            printf("] (%u bytes)\n", sz);
            if (sz >= 2) printf("%*s  -> as uint16 = %u\n",
                                indent*2, "", (uint16_t)(buf[0]|(buf[1]<<8)));
        }
    }

    /* NativeDataRange */
    if (cmio_has(obj, kCMIOFeatureControlPropertyNativeDataRange)) {
        UInt32 sz = 0; cmio_size(obj, kCMIOFeatureControlPropertyNativeDataRange, &sz);
        uint8_t buf[32] = {};
        if (sz <= 32 && sz >= 4 && !cmio_get(obj, kCMIOFeatureControlPropertyNativeDataRange, buf, sz)) {
            uint16_t mn = (uint16_t)(buf[0]|(buf[1]<<8));
            uint16_t mx = (uint16_t)(buf[sz/2]|(buf[sz/2+1]<<8));
            printf("%*s  DataRange   = %u – %u\n", indent*2, "", mn, mx);
        }
    }
}

static void dump_obj(CMIOObjectID obj, int indent)
{
    dump_ctrl(obj, indent);
    if (indent < 2) {
        UInt32 cnt = 0; CMIOObjectID *ch = cmio_owned(obj, &cnt);
        if (ch) { for (UInt32 i = 0; i < cnt; i++) dump_obj(ch[i], indent+1); free(ch); }
    }
}

static void cmd_dump(void)
{
    UInt32 sz = 0;
    if (cmio_size(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, &sz)) return;
    int n = sz/sizeof(CMIOObjectID); CMIOObjectID devs[n];
    cmio_get(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, devs, sz);
    printf("%d CMIO devices:\n", n);
    for (int i = 0; i < n; i++) dump_obj(devs[i], 1);
}

/* ── Locate the white balance temperature control ───────────────────────── */
/*
 * Strategy (in order):
 *  1. Find a control whose NativeData is a 2–4 byte value in [2000,10000]
 *     AND class is 'temp' or 'ucwt'
 *  2. Fall back to first 'temp' control with NativeValue in [2000,10000]
 *  3. Fall back to any 'temp' control
 */
static CMIOObjectID find_wb_ctrl(CMIOObjectID dev, bool *use_nd)
{
    UInt32 cnt = 0; CMIOObjectID *ch = cmio_owned(dev, &cnt);
    if (!ch) return 0;

    CMIOObjectID best = 0; bool best_nd = false;

    for (UInt32 i = 0; i < cnt; i++) {
        CMIOClassID cls = cmio_class(ch[i]);
        /* Only consider temperature and "unknown UVC" controls */
        bool candidate = (cls == kCMIOTemperatureControlClassID) ||
                         (cls == 'ucwt');   /* common LifeCam white-bal class */
        if (!candidate) continue;

        /* Prefer NativeData with a value in Kelvin range */
        uint16_t nd = 0;
        if (ctrl_get_nd_u16(ch[i], &nd) && nd >= 2000 && nd <= 10000) {
            best = ch[i]; best_nd = true; break;
        }
        /* Try NativeValue */
        float nv = 0;
        if (!best && ctrl_get_float(ch[i], kCMIOFeatureControlPropertyNativeValue, &nv)
                && nv >= 2000.0f && nv <= 10000.0f) {
            best = ch[i]; best_nd = false;
        }
        /* Weakest: any 'temp' control */
        if (!best && cls == kCMIOTemperatureControlClassID)
            { best = ch[i]; best_nd = false; }
    }
    free(ch);
    if (use_nd) *use_nd = best_nd;
    return best;
}

/* ── get / set / auto commands ───────────────────────────────────────────── */
static int cmd_get(CMIOObjectID dev)
{
    bool use_nd = false;
    CMIOObjectID ctrl = find_wb_ctrl(dev, &use_nd);
    if (!ctrl) {
        fprintf(stderr, "No WB temperature control found. Run './lifecam_wb dump'.\n");
        return 1;
    }
    printf("WB ctrl: id=%u class='%s' mode=%s\n",
           ctrl, fcc(cmio_class(ctrl)), use_nd ? "NativeData" : "NativeValue");

    /* Auto/manual */
    if (cmio_has(ctrl, kCMIOFeatureControlPropertyAutomaticManual)) {
        UInt32 av = 0;
        cmio_get(ctrl, kCMIOFeatureControlPropertyAutomaticManual, &av, sizeof av);
        printf("  Auto WB : %s\n", av ? "ON" : "OFF");
    }

    /* Temperature */
    if (use_nd) {
        uint16_t k = 0;
        if (!ctrl_get_nd_u16(ctrl, &k)) { fprintf(stderr,"  read failed\n"); return 1; }
        printf("  WB temp : %u K\n", k);
    } else {
        float nv = 0;
        if (!ctrl_get_float(ctrl, kCMIOFeatureControlPropertyNativeValue, &nv))
            { fprintf(stderr,"  read failed\n"); return 1; }
        printf("  WB temp : %.0f K\n", nv);
    }

    /* Range */
    if (cmio_has(ctrl, kCMIOFeatureControlPropertyNativeRange)) {
        AVR r = {}; cmio_get(ctrl, kCMIOFeatureControlPropertyNativeRange, &r, sizeof r);
        if (r.mMinimum || r.mMaximum)
            printf("  WB range: %.0f – %.0f K\n", r.mMinimum, r.mMaximum);
    } else if (cmio_has(ctrl, kCMIOFeatureControlPropertyNativeDataRange)) {
        UInt32 sz = 0; cmio_size(ctrl, kCMIOFeatureControlPropertyNativeDataRange, &sz);
        if (sz >= 4) {
            uint8_t buf[32] = {}; cmio_get(ctrl, kCMIOFeatureControlPropertyNativeDataRange, buf, sz);
            uint16_t mn = (uint16_t)(buf[0]|(buf[1]<<8));
            uint16_t mx = (uint16_t)(buf[sz/2]|(buf[sz/2+1]<<8));
            if (mn || mx) printf("  WB range: %u – %u K\n", mn, mx);
        }
    }
    return 0;
}

static int cmd_set(CMIOObjectID dev, float k)
{
    bool use_nd = false;
    CMIOObjectID ctrl = find_wb_ctrl(dev, &use_nd);
    if (!ctrl) { fprintf(stderr, "No WB control found.\n"); return 1; }

    /* Disable auto */
    if (cmio_has(ctrl, kCMIOFeatureControlPropertyAutomaticManual)) {
        UInt32 off = 0;
        cmio_set(ctrl, kCMIOFeatureControlPropertyAutomaticManual, &off, sizeof off);
    }

    int rc;
    if (use_nd) {
        rc = ctrl_set_nd_u16(ctrl, (uint16_t)roundf(k)) ? 0 : 1;
    } else {
        Float32 fk = k;
        rc = cmio_set(ctrl, kCMIOFeatureControlPropertyNativeValue, &fk, sizeof fk);
    }
    if (rc) { fprintf(stderr, "  SET failed\n"); return 1; }
    printf("  WB set to %.0f K  (ctrl id=%u class='%s')\n", k, ctrl, fcc(cmio_class(ctrl)));
    return 0;
}

static int cmd_auto(CMIOObjectID dev, int enable)
{
    bool use_nd = false;
    CMIOObjectID ctrl = find_wb_ctrl(dev, &use_nd);
    if (!ctrl) { fprintf(stderr, "No WB control found.\n"); return 1; }

    if (!cmio_has(ctrl, kCMIOFeatureControlPropertyAutomaticManual)) {
        fprintf(stderr, "Auto-manual not supported on this control.\n"); return 1;
    }
    UInt32 v = enable ? 1 : 0;
    OSStatus kr = cmio_set(ctrl, kCMIOFeatureControlPropertyAutomaticManual, &v, sizeof v);
    if (kr) { fprintf(stderr, "  AUTO failed (%d)\n", (int)kr); return 1; }
    printf("  Auto WB %s\n", enable ? "ON" : "OFF");
    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr,
            "Usage:\n"
            "  %s dump\n"
            "  %s get\n"
            "  %s set <K>      (2800=tungsten 4000=fluorescent 5500=daylight 6500=cloudy)\n"
            "  %s auto <0|1>\n",
            argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "dump") == 0) { cmd_dump(); return 0; }

    CMIOObjectID dev = find_lifecam();
    if (!dev) {
        fprintf(stderr,
            "LifeCam not found.\n"
            "Grant Camera permission to Terminal:\n"
            "  System Settings → Privacy & Security → Camera\n");
        return 1;
    }

    if (strcmp(argv[1], "get") == 0) return cmd_get(dev);

    if (strcmp(argv[1], "set") == 0 && argc == 3) {
        float k = atof(argv[2]);
        if (k < 2000 || k > 10000) { fprintf(stderr, "K must be 2000-10000\n"); return 1; }
        return cmd_set(dev, k);
    }
    if (strcmp(argv[1], "auto") == 0 && argc == 3)
        return cmd_auto(dev, atoi(argv[2]));

    fprintf(stderr, "Unknown command\n"); return 1;
}
