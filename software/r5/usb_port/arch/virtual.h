#pragma once
#include <stdint.h>
#define virt_to_phys(p) ((uintptr_t)(p))
#define phys_to_virt(p) ((void *)(uintptr_t)(p))
