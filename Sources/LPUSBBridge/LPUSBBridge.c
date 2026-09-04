#include "LPUSBBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <mach/mach_error.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
} LPUSBHandle;

static CFNumberRef number_for_u16(uint16_t value) {
    int32_t number = (int32_t)value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &number);
}

static uint16_t property_u16(io_service_t service, CFStringRef key) {
    uint16_t result = 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, key, kCFAllocatorDefault, 0
    );
    if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
        int32_t number = 0;
        if (CFNumberGetValue(value, kCFNumberSInt32Type, &number)) {
            result = (uint16_t)number;
        }
    }
    if (value != NULL) {
        CFRelease(value);
    }
    return result;
}

int32_t lp_usb_list(LPUSBDeviceInfo *out_devices, int32_t capacity) {
    if (capacity < 0) {
        return -1;
    }

    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (matching == NULL) {
        return -2;
    }

    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, matching, &iterator
    );
    if (result != KERN_SUCCESS) {
        return (int32_t)result;
    }

    int32_t total = 0;
    io_service_t service = 0;
    while ((service = IOIteratorNext(iterator)) != 0) {
        uint16_t vendor_id = property_u16(service, CFSTR(kUSBVendorID));
        uint16_t product_id = property_u16(service, CFSTR(kUSBProductID));

        if (out_devices != NULL && total < capacity) {
            LPUSBDeviceInfo *info = &out_devices[total];
            info->vendor_id = vendor_id;
            info->product_id = product_id;
        }
        total += 1;
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return total;
}

static void *lp_usb_open_internal(uint16_t vendor_id, uint16_t product_id, bool seize) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (matching == NULL) {
        return NULL;
    }

    CFNumberRef vendor = number_for_u16(vendor_id);
    CFNumberRef product = number_for_u16(product_id);
    if (vendor == NULL || product == NULL) {
        if (vendor != NULL) CFRelease(vendor);
        if (product != NULL) CFRelease(product);
        return NULL;
    }
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vendor);
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), product);
    CFRelease(vendor);
    CFRelease(product);

    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, matching, &iterator
    );
    if (result != KERN_SUCCESS) {
        return NULL;
    }

    LPUSBHandle *handle = NULL;
    io_service_t service = 0;
    while ((service = IOIteratorNext(iterator)) != 0) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kern_return_t plugin_result = IOCreatePlugInInterfaceForService(
            service,
            kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID,
            &plugin,
            &score
        );
        if (plugin_result == KERN_SUCCESS && plugin != NULL) {
            IOUSBDeviceInterface **device = NULL;
            HRESULT query_result = (*plugin)->QueryInterface(
                plugin,
                CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID100),
                (LPVOID *)&device
            );
            (*plugin)->Release(plugin);

            if (query_result == 0 && device != NULL) {
                // The normal W4/W4EX firmware is also exposed to CoreAudio. A
                // regular device open can succeed while the audio driver
                // still owns the interface needed by the ISP hand-off.
                IOReturn open_result = seize
                    ? (*device)->USBDeviceOpenSeize(device)
                    : (*device)->USBDeviceOpen(device);
                if (open_result == kIOReturnSuccess) {
                    handle = (LPUSBHandle *)calloc(1, sizeof(LPUSBHandle));
                    if (handle != NULL) {
                        handle->device = device;
                        if (seize) {
                            IOUSBFindInterfaceRequest request = {
                                kIOUSBFindInterfaceDontCare,
                                kIOUSBFindInterfaceDontCare,
                                kIOUSBFindInterfaceDontCare,
                                0
                            };
                            io_iterator_t interface_iterator = 0;
                            if ((*device)->CreateInterfaceIterator(device, &request, &interface_iterator) == kIOReturnSuccess) {
                                io_service_t interface_service = 0;
                                while ((interface_service = IOIteratorNext(interface_iterator)) != 0) {
                                    IOCFPlugInInterface **interface_plugin = NULL;
                                    SInt32 interface_score = 0;
                                    kern_return_t interface_plugin_result = IOCreatePlugInInterfaceForService(
                                        interface_service,
                                        kIOUSBInterfaceUserClientTypeID,
                                        kIOCFPlugInInterfaceID,
                                        &interface_plugin,
                                        &interface_score
                                    );
                                    if (interface_plugin_result == KERN_SUCCESS && interface_plugin != NULL) {
                                        IOUSBInterfaceInterface **interface = NULL;
                                        HRESULT interface_query_result = (*interface_plugin)->QueryInterface(
                                            interface_plugin,
                                            CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                            (LPVOID *)&interface
                                        );
                                        (*interface_plugin)->Release(interface_plugin);
                                        if (interface_query_result == 0 && interface != NULL) {
                                            IOReturn interface_open_result = (*interface)->USBInterfaceOpenSeize(interface);
                                            if (interface_open_result == kIOReturnSuccess) {
                                                handle->interface = interface;
                                                IOObjectRelease(interface_service);
                                                break;
                                            }
                                            (*interface)->Release(interface);
                                        }
                                    }
                                    IOObjectRelease(interface_service);
                                }
                                IOObjectRelease(interface_iterator);
                            }
                        }
                    } else {
                        (*device)->USBDeviceClose(device);
                        (*device)->Release(device);
                    }
                    IOObjectRelease(service);
                    break;
                }
                (*device)->Release(device);
            }
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return handle;
}

void *lp_usb_open(uint16_t vendor_id, uint16_t product_id) {
    return lp_usb_open_internal(vendor_id, product_id, false);
}

void *lp_usb_open_seize(uint16_t vendor_id, uint16_t product_id) {
    return lp_usb_open_internal(vendor_id, product_id, true);
}

void lp_usb_close(void *opaque_handle) {
    LPUSBHandle *handle = (LPUSBHandle *)opaque_handle;
    if (handle == NULL) {
        return;
    }
    if (handle->device != NULL) {
        if (handle->interface != NULL) {
            (*handle->interface)->USBInterfaceClose(handle->interface);
            (*handle->interface)->Release(handle->interface);
        }
        (*handle->device)->USBDeviceClose(handle->device);
        (*handle->device)->Release(handle->device);
    }
    free(handle);
}

static int32_t control_request(
    LPUSBHandle *handle,
    uint8_t request_type,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    void *data,
    uint16_t length
) {
    static uint32_t trace_read_count = 0;
    if (handle == NULL || handle->device == NULL) {
        return (int32_t)kIOReturnNotOpen;
    }

    IOUSBDevRequest request_block;
    memset(&request_block, 0, sizeof(request_block));
    request_block.bmRequestType = request_type;
    request_block.bRequest = request;
    request_block.wValue = value;
    request_block.wIndex = index;
    request_block.wLength = length;
    request_block.pData = data;
    request_block.wLenDone = 0;
    // DeviceRequest is the closest macOS equivalent of the Windows driver's
    // vendor-control path.  Keep the interface path as an opt-in diagnostic
    // fallback because AppleUSBAudio may otherwise alter the transfer context.
    IOReturn result;
    if (handle->interface != NULL && getenv("LP_USB_USE_INTERFACE") != NULL) {
        result = (*handle->interface)->ControlRequest(handle->interface, 0, &request_block);
    } else {
        result = (*handle->device)->DeviceRequest(handle->device, &request_block);
    }
    if (getenv("LP_USB_TRACE") != NULL && request == 0x80 && index == 1 && length == 0x100) {
        fprintf(stderr, "LP_USB_TRACE request=0x80 index=1 length=0x100 result=0x%X done=%u\n",
                result, request_block.wLenDone);
    }
    if (getenv("LP_USB_TRACE") != NULL && request == 0x82 && length == 0x40 &&
        (trace_read_count++ < 4 || request_block.wLenDone != length)) {
        fprintf(stderr, "LP_USB_TRACE request=0x82 length=0x40 result=0x%X done=%u\n",
                result, request_block.wLenDone);
    }
    if (result == kIOReturnSuccess && (request_type & 0x80) != 0 &&
        request_block.wLenDone != length) {
        fprintf(stderr, "LP_USB short IN transfer request=0x%02X expected=%u done=%u\n",
                request, length, request_block.wLenDone);
        return (int32_t)kIOReturnUnderrun;
    }
    return (int32_t)result;
}

int32_t lp_usb_control_out(
    void *opaque_handle,
    uint8_t request_type,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    const uint8_t *data,
    uint16_t length
) {
    return control_request((LPUSBHandle *)opaque_handle, request_type, request,
                           value, index, (void *)data, length);
}

int32_t lp_usb_control_in(
    void *opaque_handle,
    uint8_t request_type,
    uint8_t request,
    uint16_t value,
    uint16_t index,
    uint8_t *data,
    uint16_t length
) {
    return control_request((LPUSBHandle *)opaque_handle, request_type, request,
                           value, index, data, length);
}

const char *lp_usb_error_string(int32_t return_code) {
    const char *message = mach_error_string((kern_return_t)return_code);
    return message != NULL ? message : "unknown IOKit error";
}
