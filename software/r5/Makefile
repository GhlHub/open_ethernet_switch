.DEFAULT_GOAL := all
ROOT := $(abspath ../..)
XILINX ?= /tools/Xilinx/2026.1
BSP ?= $(ROOT)/build/r5/workspace/kr260_r5/psu_cortexr5_0/r5_bsp/bsp
CC := $(XILINX)/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-gcc
NM := $(XILINX)/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-nm
SIZE := $(XILINX)/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-size
KERNEL := $(ROOT)/third_party/FreeRTOS-LTS/FreeRTOS/FreeRTOS-Kernel
TCP := $(ROOT)/third_party/FreeRTOS-LTS/FreeRTOS/FreeRTOS-Plus-TCP/source
PORT := $(KERNEL)/portable/GCC/ARM_CR5
STATS_DDR ?= 0
STATS_DEBUG ?= 0
ifneq ($(filter-out 0 1,$(STATS_DDR) $(STATS_DEBUG)),)
$(error STATS_DDR and STATS_DEBUG must be 0 or 1)
endif
CFLAGS := -mcpu=cortex-r5 -mfloat-abi=hard -mfpu=vfpv3-d16 -marm -O2 -g3 -ffunction-sections -fdata-sections -Wall -Wextra -DSDT -DARMR5 -D__FREERTOS__
CPPFLAGS := -DSTATS_DDR=$(STATS_DDR) -DSTATS_DEBUG=$(STATS_DEBUG) -Iinclude -I$(BSP)/include -I$(KERNEL)/include -I$(PORT) -I$(TCP)/include -I$(TCP)/portable/Compiler/GCC
APP := $(wildcard src/*.c) src/vectors.S
LIBSRC := $(KERNEL)/tasks.c $(KERNEL)/queue.c $(KERNEL)/list.c $(KERNEL)/timers.c $(KERNEL)/event_groups.c $(KERNEL)/stream_buffer.c $(KERNEL)/portable/MemMang/heap_4.c $(PORT)/port.c $(PORT)/portASM.S $(wildcard $(TCP)/*.c) $(TCP)/portable/BufferManagement/BufferAllocation_2.c
# Flatten unique upstream basenames; fail if a future addition creates a collision.
SOURCES := $(APP) $(LIBSRC)
OBJECTS := $(addprefix out/,$(addsuffix .o,$(notdir $(SOURCES))))
ifneq ($(words $(OBJECTS)),$(words $(sort $(OBJECTS))))
$(error duplicate source basename)
endif
.PHONY: all test test-snmp clean FORCE
FORCE:
out/stats_config: FORCE | out
	@printf '%s\n' 'STATS_DDR=$(STATS_DDR) STATS_DEBUG=$(STATS_DEBUG)' > out/stats_config.tmp
	@cmp -s out/stats_config.tmp $@ || cp out/stats_config.tmp $@
$(OBJECTS): out/stats_config
all: out/kr260_r5.elf
out:
	mkdir -p $@
define compile
out/$(notdir $(1)).o: $(1) | out
	$$(CC) $$(CFLAGS) $$(CPPFLAGS) -MMD -MP -c $$< -o $$@
endef
$(foreach s,$(SOURCES),$(eval $(call compile,$(s))))
out/kr260_r5.elf: $(OBJECTS) linker.ld verify_elf.py $(BSP)/lib/libxil.a $(BSP)/lib/libxilstandalone.a $(BSP)/lib/libxiltimer.a
	$(CC) $(CFLAGS) -nostartfiles -Wl,--gc-sections,--wrap=outbyte,-Map,out/kr260_r5.map -Wl,-T,linker.ld $(OBJECTS) -L$(BSP)/lib -Wl,--start-group -lxil -lxilstandalone -lxiltimer -lc -lm -lgcc -Wl,--end-group -o $@
	$(SIZE) $@
	python3 verify_elf.py $@ $(NM)
test: test-snmp | out
	cc -std=c11 -Wall -Wextra -Werror -Iinclude src/policy.c tests/test_policy.c -o out/test_policy
	./out/test_policy
	cc -std=c11 -Wall -Wextra -Werror -fno-pie -no-pie -Itests/fakes src/fabric_dma.c tests/test_dma.c -o out/test_dma
	./out/test_dma
	./out/test_dma 1
	./out/test_dma 2
	cc -std=c11 -Wall -Wextra -Werror -DSTATS_DDR=1 -DSTATS_DEBUG=1 -Itests/stats_fakes -Iinclude src/statistics.c tests/test_statistics.c -o out/test_statistics
	./out/test_statistics
	./out/test_statistics 1
	./out/test_statistics 2
	./out/test_statistics 3
test-snmp: | out
	@set -e; for ddr in 0 1; do for debug in 0 1; do \
	  cc -shared -fPIC -std=c11 -Wall -Wextra -Werror -DSTATS_DDR=$$ddr -DSTATS_DEBUG=$$debug -Iinclude src/snmp_protocol.c src/snmp_mib.c tests/snmp_fixture.c -o out/test_snmp_$$ddr$$debug.so; \
	  python3 tests/test_snmp.py out/test_snmp_$$ddr$$debug.so $$((1 + 2*ddr + 4*debug)); \
	done; done
clean:
	$(RM) out/*.o out/*.d out/*.elf out/*.map out/test_policy out/test_dma out/test_statistics out/test_snmp*.so
-include $(OBJECTS:.o=.d)
