#include <stdint.h>
typedef uint32_t TickType_t;
#define pdMS_TO_TICKS(n) (n)
#define portMAX_DELAY 0xffffffffUL

typedef int BaseType_t;
#define pdFALSE 0
#define portYIELD_FROM_ISR(wake) ((void)(wake))
