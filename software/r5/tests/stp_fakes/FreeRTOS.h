#ifndef TEST_STP_FREERTOS_H
#define TEST_STP_FREERTOS_H
#include <stdint.h>
#include <assert.h>
typedef uint32_t TickType_t;
#define pdMS_TO_TICKS(n) (n)
#define portTICK_PERIOD_MS 1
#define configASSERT(x) assert(x)
#define pdPASS 1
#define taskENTER_CRITICAL() ((void)0)
#define taskEXIT_CRITICAL() ((void)0)
#endif
