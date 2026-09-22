#include <stdint.h>
#include <assert.h>
typedef uint32_t TickType_t;
#define taskENTER_CRITICAL() ((void)0)
#define taskEXIT_CRITICAL() ((void)0)
#define configASSERT(x) assert(x)
#define pdMS_TO_TICKS(x) (x)
#define portTICK_PERIOD_MS 1
