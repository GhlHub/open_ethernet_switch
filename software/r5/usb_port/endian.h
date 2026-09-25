#pragma once
#include <stdint.h>
#define htonl(x) __builtin_bswap32((uint32_t)(x))
#define ntohl(x) htonl(x)
#define htonw(x) __builtin_bswap16((uint16_t)(x))
#define ntohw(x) htonw(x)
