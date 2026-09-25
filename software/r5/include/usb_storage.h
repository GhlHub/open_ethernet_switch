#ifndef USB_STORAGE_H
#define USB_STORAGE_H
#include <stdbool.h>
#include <stdint.h>
/* Single owner: settings startup, subsequently HTTP task. */
bool usb_storage_probe(void);
bool usb_storage_ready(void);
bool usb_storage_blocks(uint32_t lba,unsigned count,void *data,bool write);
bool usb_storage_sync(void);
uint32_t usb_storage_sectors(void);
#endif
