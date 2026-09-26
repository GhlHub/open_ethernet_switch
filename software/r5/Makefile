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
CONFIG_RECOVERY ?= 0
ifneq ($(filter-out 0 1,$(STATS_DDR) $(STATS_DEBUG) $(CONFIG_RECOVERY)),)
$(error STATS_DDR, STATS_DEBUG and CONFIG_RECOVERY must be 0 or 1)
endif
CFLAGS := -mcpu=cortex-r5 -mfloat-abi=hard -mfpu=vfpv3-d16 -marm -O2 -g3 -ffunction-sections -fdata-sections -Wall -Wextra -DSDT -DARMR5 -D__FREERTOS__
CPPFLAGS := -DCONFIG_RECOVERY=$(CONFIG_RECOVERY) -DSTATS_DDR=$(STATS_DDR) -DSTATS_DEBUG=$(STATS_DEBUG) -Iinclude -I$(ROOT)/third_party/sha256 -Iout -I$(BSP)/include -I$(KERNEL)/include -I$(PORT) -I$(TCP)/include -I$(TCP)/portable/Compiler/GCC
USB := $(ROOT)/third_party/libpayload_usb
CPPFLAGS += -Iusb_port -I$(USB)/include -I$(USB)/drivers -I$(ROOT)/third_party/fatfs
APP := $(wildcard src/*.c) src/vectors.S $(ROOT)/third_party/sha256/sha256.c
LIBSRC := $(KERNEL)/tasks.c $(KERNEL)/queue.c $(KERNEL)/list.c $(KERNEL)/timers.c $(KERNEL)/event_groups.c $(KERNEL)/stream_buffer.c $(KERNEL)/portable/MemMang/heap_4.c $(PORT)/port.c $(PORT)/portASM.S $(wildcard $(TCP)/*.c) $(TCP)/portable/BufferManagement/BufferAllocation_2.c
# Flatten unique upstream basenames; fail if a future addition creates a collision.
SOURCES := $(APP) $(LIBSRC) $(wildcard $(USB)/drivers/*.c) $(ROOT)/third_party/fatfs/ff.c
OBJECTS := $(addprefix out/,$(addsuffix .o,$(notdir $(SOURCES))))
ifneq ($(words $(OBJECTS)),$(words $(sort $(OBJECTS))))
$(error duplicate source basename)
endif
.PHONY: all test test-snmp clean FORCE
FORCE:
out/stats_config: FORCE | out
	@printf '%s\n' 'STATS_DDR=$(STATS_DDR) STATS_DEBUG=$(STATS_DEBUG) CONFIG_RECOVERY=$(CONFIG_RECOVERY)' > out/stats_config.tmp
	@cmp -s out/stats_config.tmp $@ || cp out/stats_config.tmp $@
$(OBJECTS): out/stats_config
out/web_page.h: web/index.html web/embed.py | out
	python3 web/embed.py $< $@
out/web_task.c.o: out/web_page.h
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
test: test-snmp test-web test-links test-pstate test-stp | out
	cc -std=c11 -Wall -Wextra -Werror -Iinclude src/policy.c tests/test_policy.c -o out/test_policy
	./out/test_policy
	cc -std=c11 -Wall -Wextra -Werror -pthread -fno-pie -no-pie -Itests/fakes src/fabric_dma.c tests/test_dma.c -o out/test_dma
	./out/test_dma
	./out/test_dma 1
	./out/test_dma 2
	./out/test_dma 3
	cc -std=c11 -Wall -Wextra -Werror -DSTATS_DDR=1 -DSTATS_DEBUG=1 -Itests/stats_fakes -Iinclude src/statistics.c tests/test_statistics.c -o out/test_statistics
	./out/test_statistics
	./out/test_statistics 1
	./out/test_statistics 2
	./out/test_statistics 3
	./out/test_statistics 4
test-snmp: | out
	@set -e; for ddr in 0 1; do for debug in 0 1; do \
	  cc -shared -fPIC -std=c11 -Wall -Wextra -Werror -DSTATS_DDR=$$ddr -DSTATS_DEBUG=$$debug -Iinclude src/snmp_protocol.c src/snmp_mib.c tests/snmp_fixture.c -o out/test_snmp_$$ddr$$debug.so; \
	  python3 tests/test_snmp.py out/test_snmp_$$ddr$$debug.so $$((1 + 2*ddr + 4*debug)); \
	done; done
clean:
	$(RM) out/*.o out/*.d out/*.elf out/*.map out/test_policy out/test_dma out/test_statistics out/test_snmp*.so out/test_web out/test_links out/test_pstate out/test_stp out/test_config out/test_settings out/test_web.json out/web_page.h
-include $(OBJECTS:.o=.d)

.PHONY: test-web
test-web: | out
	@set -e; for ddr in 0 1; do for debug in 0 1; do \
	  cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -DSTATS_DDR=$$ddr -DSTATS_DEBUG=$$debug -Iinclude src/web_protocol.c src/config.c src/config_web.c tests/test_web.c -o out/test_web; \
	  ./out/test_web > out/test_web.json; \
	  python3 -c 'import json; s=json.load(open("out/test_web.json")); assert s["ports"][0][0]=="18446744073709551615"; assert len(s["timeouts"])==208; assert ("ddr" in s)==bool('$$ddr'); assert ("debug" in s)==bool('$$debug')'; \
	done; done

.PHONY: test-links
test-links: | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Itests/link_fakes -Iinclude src/policy.c src/port_policy.c tests/test_links.c -o out/test_links
	./out/test_links

.PHONY: test-pstate
test-pstate: | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Itests/link_fakes -Iinclude tests/test_pstate.c -o out/test_pstate
	./out/test_pstate

.PHONY: test-stp
test-stp: | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Iinclude tests/test_stp.c -o out/test_stp
	./out/test_stp

.PHONY: test-config
test: test-config
test-config: | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Iinclude src/config.c src/config_web.c tests/test_config.c -o out/test_config
	./out/test_config

test-config: test-settings
.PHONY: test-settings
test-settings: | out
	@set -e; for recovery in 0 1; do \
	  cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -DCONFIG_RECOVERY=$$recovery -Itests/link_fakes -Iinclude src/config.c tests/test_settings.c -o out/test_settings; \
	  ./out/test_settings; \
	done

test-config: test-config-password
.PHONY: test-config-password
test-config-password: | out
	cc -shared -fPIC -std=c11 -Wall -Wextra -Werror -Iinclude src/config.c -o out/test_config.so
	python3 tests/test_config_password.py out/test_config.so

test-config: test-configure-helper
.PHONY: test-configure-helper
test-configure-helper:
	python3 tests/test_configure_switch.py

test: test-auth
.PHONY: test-auth
test-auth: | out
	cc -shared -fPIC -std=c11 -Wall -Wextra -Werror -Iinclude -I$(ROOT)/third_party/sha256 src/auth.c src/config.c $(ROOT)/third_party/sha256/sha256.c -o out/test_auth.so
	python3 tests/test_auth.py out/test_auth.so

test-auth: test-http-auth
.PHONY: test-http-auth
test-http-auth: out/web_page.h | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Itests/http_fakes -Itests/link_fakes -Iinclude -Iout -I$(ROOT)/third_party/sha256 src/auth.c src/config.c src/config_web.c src/web_protocol.c $(ROOT)/third_party/sha256/sha256.c tests/test_http_auth.c -o out/test_http_auth
	./out/test_http_auth

.PHONY: test-sd
test: test-sd
test-sd: | out
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Iinclude -I$(ROOT)/third_party/fatfs src/config.c src/settings_media.c src/usb_diskio.c $(ROOT)/third_party/fatfs/ff.c tests/test_sd_media.c -o out/test_sd_media
	./out/test_sd_media
	cc -std=c11 -Wall -Wextra -Werror -fsanitize=undefined src/usb_memory.c tests/test_usb_memory.c -o out/test_usb_memory
	./out/test_usb_memory
	cc -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -ffunction-sections -fdata-sections -Wl,--gc-sections -Iusb_port -I$(USB)/include tests/test_usb_msc.c -o out/test_usb_msc
	./out/test_usb_msc
