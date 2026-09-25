#pragma once
#define wmb() __asm volatile("dmb sy" ::: "memory")
#define rmb() __asm volatile("dmb sy" ::: "memory")
