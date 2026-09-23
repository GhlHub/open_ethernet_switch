#ifndef TEST_SEMPHR_H
#define TEST_SEMPHR_H
typedef void *SemaphoreHandle_t;
static inline SemaphoreHandle_t xSemaphoreCreateMutex(void) { return (void *)1; }
static inline int xSemaphoreTake(SemaphoreHandle_t h, unsigned long timeout) { (void)h; (void)timeout; return 1; }
static inline int xSemaphoreGive(SemaphoreHandle_t h) { (void)h; return 1; }
#endif
