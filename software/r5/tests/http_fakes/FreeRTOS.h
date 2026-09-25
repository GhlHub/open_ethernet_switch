#include <stdint.h>
#include <assert.h>
typedef uint32_t TickType_t;
typedef int BaseType_t;
#define pdMS_TO_TICKS(n) (n)
#define pdPASS 1
#define configASSERT(x) assert(x)
#define pdTRUE 1
#define portMAX_DELAY UINT32_MAX
