#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Open the first Microsoft LifeCam found and its UVC VideoControl interface.
 * Returns 0 on success, -1 on failure.
 * Must be called before any other uvc_* function.
 */
int uvc_open(void);
void uvc_close(void);

/* White balance queries — return 0 on success */
int uvc_get_wb_auto(int *out_enabled);
int uvc_get_wb_temp(uint16_t *out_kelvin);
int uvc_get_wb_range(uint16_t *out_min, uint16_t *out_max);

/* White balance commands — return 0 on success */
int uvc_set_wb_auto(int enable);
int uvc_set_wb_temp(uint16_t kelvin);

#ifdef __cplusplus
}
#endif
