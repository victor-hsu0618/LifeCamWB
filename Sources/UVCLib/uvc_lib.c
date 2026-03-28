/*
 * uvc_lib.c — White balance control via CoreMediaIO for Microsoft LifeCam
 *
 * The Apple UVCAssistant daemon owns the USB interface exclusively on macOS 12+.
 * Raw IOKit USB requests are blocked.  CoreMediaIO is the correct path.
 *
 * The LifeCam Studio exposes white balance temperature as:
 *   CMIO control class  'ucwt' (UVC White Balance Temperature)
 *   Format: NativeData, 2 bytes, little-endian uint16, unit = Kelvin
 *   Auto/manual: kCMIOFeatureControlPropertyAutomaticManual
 *   Range: 2500 – 10000 K (reported by device)
 */

#include "uvc_lib.h"

#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMediaIO/CMIOHardware.h>

typedef struct { double mMinimum; double mMaximum; } AVRange;

/* ── CMIO helpers ───────────────────────────────────────────────────────── */
#define ADDR(s) ((CMIOObjectPropertyAddress){ \
    (s), kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain })

static bool has_prop(CMIOObjectID o, CMIOObjectPropertySelector s)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectHasProperty(o, &a);
}
static OSStatus get_prop(CMIOObjectID o, CMIOObjectPropertySelector s,
                          void *data, UInt32 size)
{
    CMIOObjectPropertyAddress a = ADDR(s); UInt32 got = size;
    return CMIOObjectGetPropertyData(o, &a, 0, NULL, size, &got, data);
}
static OSStatus set_prop(CMIOObjectID o, CMIOObjectPropertySelector s,
                          const void *data, UInt32 size)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectSetPropertyData(o, &a, 0, NULL, size, data);
}
static OSStatus prop_size(CMIOObjectID o, CMIOObjectPropertySelector s, UInt32 *sz)
{
    CMIOObjectPropertyAddress a = ADDR(s);
    return CMIOObjectGetPropertyDataSize(o, &a, 0, NULL, sz);
}
static CMIOClassID obj_class(CMIOObjectID o)
{
    CMIOClassID c = 0; get_prop(o, kCMIOObjectPropertyClass, &c, sizeof c); return c;
}

/* ── Module state ───────────────────────────────────────────────────────── */
static CMIOObjectID g_wb_ctrl = 0;  /* the 'ucwt' control object */

/* ── Device / control discovery ─────────────────────────────────────────── */
static CMIOObjectID find_lifecam_device(void)
{
    UInt32 sz = 0;
    if (prop_size(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, &sz) || !sz)
        return 0;
    int n = sz / sizeof(CMIOObjectID);
    CMIOObjectID devs[n];
    get_prop(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices, devs, sz);
    for (int i = 0; i < n; i++) {
        CFStringRef cf = NULL;
        get_prop(devs[i], kCMIOObjectPropertyName, &cf, sizeof cf);
        if (!cf) continue;
        bool ok = CFStringFind(cf, CFSTR("LifeCam"),
                     kCFCompareCaseInsensitive).location != kCFNotFound;
        CFRelease(cf);
        if (ok) return devs[i];
    }
    return 0;
}

/* White balance temperature control:
 *   Prefer class 'ucwt' (UVC WB Temperature, NativeData, 2-byte uint16 Kelvin)
 *   Fall back to 'temp' with NativeData in Kelvin range                      */
static CMIOObjectID find_wb_control(CMIOObjectID dev)
{
    UInt32 sz = 0;
    if (prop_size(dev, kCMIOObjectPropertyOwnedObjects, &sz) || !sz) return 0;
    int n = sz / sizeof(CMIOObjectID);
    CMIOObjectID ch[n];
    get_prop(dev, kCMIOObjectPropertyOwnedObjects, ch, sz);

    CMIOObjectID best = 0;
    for (int i = 0; i < n; i++) {
        CMIOClassID cls = obj_class(ch[i]);
        if (cls != (CMIOClassID)'ucwt' &&
            cls != kCMIOTemperatureControlClassID) continue;

        /* Validate: NativeData should be 2 bytes with a plausible Kelvin value */
        if (has_prop(ch[i], kCMIOFeatureControlPropertyNativeData)) {
            UInt32 dsz = 0;
            if (!prop_size(ch[i], kCMIOFeatureControlPropertyNativeData, &dsz)
                && dsz >= 2) {
                uint8_t buf[4] = {};
                get_prop(ch[i], kCMIOFeatureControlPropertyNativeData, buf, dsz);
                uint16_t k = (uint16_t)(buf[0] | (buf[1] << 8));
                /* Accept if it's a plausible temp OR it's 'ucwt' (trust the class) */
                if ((k >= 2000 && k <= 10000) || cls == (CMIOClassID)'ucwt') {
                    best = ch[i];
                    if (cls == (CMIOClassID)'ucwt') break; /* best possible match */
                }
            }
        }
    }
    return best;
}

/* ── Public API ─────────────────────────────────────────────────────────── */
int uvc_open(void)
{
    CMIOObjectID dev = find_lifecam_device();
    if (!dev) return -1;
    g_wb_ctrl = find_wb_control(dev);
    return g_wb_ctrl ? 0 : -1;
}

void uvc_close(void)
{
    g_wb_ctrl = 0;
}

int uvc_get_wb_auto(int *out)
{
    if (!g_wb_ctrl || !has_prop(g_wb_ctrl, kCMIOFeatureControlPropertyAutomaticManual))
        return -1;
    UInt32 v = 0;
    if (get_prop(g_wb_ctrl, kCMIOFeatureControlPropertyAutomaticManual, &v, sizeof v))
        return -1;
    *out = (int)v;
    return 0;
}

int uvc_get_wb_temp(uint16_t *out)
{
    if (!g_wb_ctrl) return -1;
    uint8_t buf[4] = {}; UInt32 sz = 0;
    if (prop_size(g_wb_ctrl, kCMIOFeatureControlPropertyNativeData, &sz) || sz < 2) return -1;
    if (get_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeData, buf, sz)) return -1;
    *out = (uint16_t)(buf[0] | (buf[1] << 8));
    return 0;
}

int uvc_get_wb_range(uint16_t *out_min, uint16_t *out_max)
{
    if (!g_wb_ctrl) return -1;
    /* Try NativeDataRange first */
    if (has_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeDataRange)) {
        UInt32 sz = 0;
        if (!prop_size(g_wb_ctrl, kCMIOFeatureControlPropertyNativeDataRange, &sz)
            && sz >= 4) {
            uint8_t buf[32] = {};
            get_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeDataRange, buf, sz);
            *out_min = (uint16_t)(buf[0]      | (buf[1]      << 8));
            *out_max = (uint16_t)(buf[sz/2]   | (buf[sz/2+1] << 8));
            return 0;
        }
    }
    /* Fall back to NativeRange (AudioValueRange = two Float64) */
    if (has_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeRange)) {
        AVRange r = {};
        if (!get_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeRange, &r, sizeof r)) {
            *out_min = (uint16_t)r.mMinimum;
            *out_max = (uint16_t)r.mMaximum;
            return 0;
        }
    }
    *out_min = 2500; *out_max = 10000;
    return 0;
}

int uvc_set_wb_auto(int enable)
{
    if (!g_wb_ctrl || !has_prop(g_wb_ctrl, kCMIOFeatureControlPropertyAutomaticManual))
        return -1;
    UInt32 v = enable ? 1 : 0;
    return set_prop(g_wb_ctrl, kCMIOFeatureControlPropertyAutomaticManual, &v, sizeof v)
           ? -1 : 0;
}

int uvc_set_wb_temp(uint16_t kelvin)
{
    if (!g_wb_ctrl) return -1;
    /* Disable auto first */
    uvc_set_wb_auto(0);
    UInt32 sz = 0;
    if (prop_size(g_wb_ctrl, kCMIOFeatureControlPropertyNativeData, &sz) || sz < 2)
        return -1;
    uint8_t buf[4] = {};
    buf[0] = kelvin & 0xFF;
    buf[1] = (kelvin >> 8) & 0xFF;
    return set_prop(g_wb_ctrl, kCMIOFeatureControlPropertyNativeData, buf, sz)
           ? -1 : 0;
}
