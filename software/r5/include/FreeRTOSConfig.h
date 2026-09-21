#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H
#include <stdint.h>
#include "xparameters.h"
void board_tick_setup(void);
void board_tick_clear(void);
void board_assert(const char *, unsigned);
#define configUSE_PREEMPTION 1
#define configUSE_TIME_SLICING 1
#define configCPU_CLOCK_HZ XPAR_CPU_CORE_CLOCK_FREQ_HZ
#define configTICK_RATE_HZ 1000
#define configMAX_PRIORITIES 7
#define configMINIMAL_STACK_SIZE 512
#define configTOTAL_HEAP_SIZE (512 * 1024)
#define configMAX_TASK_NAME_LEN 16
#define configUSE_16_BIT_TICKS 0
#define configUSE_MUTEXES 1
#define configUSE_COUNTING_SEMAPHORES 1
#define configUSE_TASK_NOTIFICATIONS 1
#define configUSE_TIMERS 1
#define configTIMER_TASK_PRIORITY 3
#define configTIMER_QUEUE_LENGTH 16
#define configTIMER_TASK_STACK_DEPTH 1024
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configSUPPORT_STATIC_ALLOCATION 0
#define configCHECK_FOR_STACK_OVERFLOW 2
#define configUSE_MALLOC_FAILED_HOOK 1
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0
#define configUSE_TASK_FPU_SUPPORT 2
#define configUNIQUE_INTERRUPT_PRIORITIES 32
#define configMAX_API_CALL_INTERRUPT_PRIORITY 18
#define configINTERRUPT_CONTROLLER_BASE_ADDRESS 0xF9000000UL
#define configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET 0x1000UL
#define configSETUP_TICK_INTERRUPT() board_tick_setup()
#define configCLEAR_TICK_INTERRUPT() board_tick_clear()
#define configASSERT(x) do { if (!(x)) board_assert(__FILE__, __LINE__); } while (0)
#define INCLUDE_vTaskDelay 1
#define INCLUDE_xTaskDelayUntil 1
#define INCLUDE_vTaskDelete 1
#define INCLUDE_xTaskGetCurrentTaskHandle 1
#define INCLUDE_xTaskGetSchedulerState 1
#endif
