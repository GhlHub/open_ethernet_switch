#include <stddef.h>
typedef void *Socket_t;
#define FREERTOS_INVALID_SOCKET ((void *)-1)
#define FREERTOS_AF_INET 2
#define FREERTOS_SOCK_STREAM 1
#define FREERTOS_IPPROTO_TCP 6
#define FREERTOS_SHUT_RDWR 2
#define FREERTOS_SO_RCVTIMEO 1
#define FREERTOS_SO_SNDTIMEO 2
struct freertos_sockaddr {int sin_family,sin_port;};
Socket_t FreeRTOS_socket(int,int,int);
int FreeRTOS_bind(Socket_t,const struct freertos_sockaddr *,size_t);
int FreeRTOS_listen(Socket_t,int);
Socket_t FreeRTOS_accept(Socket_t,void *,void *);
int FreeRTOS_setsockopt(Socket_t,int,int,const void *,size_t);
int FreeRTOS_closesocket(Socket_t);
int FreeRTOS_recv(Socket_t,void *,size_t,int);
int FreeRTOS_send(Socket_t,const void *,size_t,int);
int FreeRTOS_shutdown(Socket_t,int);
