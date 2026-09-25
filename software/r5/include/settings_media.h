#ifndef SETTINGS_MEDIA_H
#define SETTINGS_MEDIA_H
#include <stdbool.h>
#include <stddef.h>
/* SD filesystem provider contract; one caller (startup, then HTTP task).
 * Slot 0: KR260A.CFG; slot 1: KR260B.CFG, root of an existing FAT volume.
 * No formatting or writes outside the mounted filesystem. present must verify mounted removable
 * media. Reads of missing files/short EOF pad with 0xff; other IO errors fail.
 * Unknown/oversized files must fail rather than silently overwrite them.
 * truncate affects only the named slot file. Each successful write must sync
 * durable file data/metadata and close before returning. Removal fails saves.
 * FAT/card power-loss behavior still limits guarantees of redundant records. */
bool settings_media_present(void);
bool settings_media_read(unsigned slot,unsigned offset,void *data,size_t size);
bool settings_media_truncate(unsigned slot);
bool settings_media_write(unsigned slot,unsigned offset,const void *data,size_t size);
const char *settings_media_status(void);
#endif
