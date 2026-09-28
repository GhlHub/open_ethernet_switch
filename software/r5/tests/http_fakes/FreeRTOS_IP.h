#define FreeRTOS_htons(x) (x)

#include <stdint.h>
char *FreeRTOS_inet_ntoa(uint32_t address,char *out);
