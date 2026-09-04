#ifndef LP_USB_BRIDGE_H
#define LP_USB_BRIDGE_H

#include <stdint.h>

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
} LPUSBDeviceInfo;

// Returns the number of matching USB devices copied to out_devices.
int32_t lp_usb_list(LPUSBDeviceInfo *out_devices, int32_t capacity);

// Opens the first USB device with the given VID/PID. The returned pointer is
// opaque and must be closed with lp_usb_close().
void *lp_usb_open(uint16_t vendor_id, uint16_t product_id);
void *lp_usb_open_seize(uint16_t vendor_id, uint16_t product_id);
void lp_usb_close(void *handle);

int32_t lp_usb_control_out(
    void *handle,
    uint8_t request_type,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    const uint8_t *data,
    uint16_t length
);

int32_t lp_usb_control_in(
    void *handle,
    uint8_t request_type,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    uint8_t *data,
    uint16_t length
);

const char *lp_usb_error_string(int32_t return_code);

#endif
