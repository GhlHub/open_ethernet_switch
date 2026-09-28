#ifndef TEST_SEMPHR_H
#define TEST_SEMPHR_H
typedef void *SemaphoreHandle_t;
SemaphoreHandle_t xSemaphoreCreateMutex(void);
int xSemaphoreTake(SemaphoreHandle_t h, unsigned long timeout);
int xSemaphoreGive(SemaphoreHandle_t h);
SemaphoreHandle_t xSemaphoreCreateBinary(void);
int xSemaphoreGiveFromISR(SemaphoreHandle_t h, int *wake);
#endif
