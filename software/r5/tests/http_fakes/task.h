TickType_t xTaskGetTickCount(void);
void vTaskDelay(TickType_t);
BaseType_t xTaskCreate(void (*)(void *),const char *,unsigned,void *,unsigned,void *);
