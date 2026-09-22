#ifndef FREERTOS_IP_CONFIG_H
#define FREERTOS_IP_CONFIG_H
#include <stdint.h>
void network_dhcp_result(int leased);
#define ipconfigBYTE_ORDER pdFREERTOS_LITTLE_ENDIAN
#define ipconfigUSE_IPv4 1
#define ipconfigUSE_IPv6 0
#define ipconfigUDP_MAX_RX_PACKETS 8
#define ipconfigUSE_TCP 1
#define ipconfigUSE_DHCP 1
#define ipconfigUSE_DHCP_HOOK 0
#define ipconfigDHCP_REGISTER_HOSTNAME 1
#define ipconfigMAXIMUM_DISCOVER_TX_PERIOD pdMS_TO_TICKS(8000)
#define ipconfigUSE_NETWORK_EVENT_HOOK 1
#define ipconfigNETWORK_MTU 1500
#define ipconfigNUM_NETWORK_BUFFER_DESCRIPTORS 32
#define ipconfigEVENT_QUEUE_LENGTH 40
#define ipconfigIP_TASK_PRIORITY 4
#define ipconfigIP_TASK_STACK_SIZE_WORDS 2048
#define ipconfigETHERNET_DRIVER_FILTERS_FRAME_TYPES 1
#define ipconfigDRIVER_INCLUDED_RX_IP_CHECKSUM 0
#define ipconfigDRIVER_INCLUDED_TX_IP_CHECKSUM 0
#define ipconfigZERO_COPY_RX_DRIVER 0
#define ipconfigZERO_COPY_TX_DRIVER 0
#define ipconfigUSE_LLMNR 0
#define ipconfigUSE_MDNS 0
#define ipconfigUSE_NBNS 0
#define ipconfigUSE_DNS 1
#define ipconfigUSE_DNS_CACHE 1
#define ipconfigUSE_DNS_CALLBACKS 0
#define ipconfigUSE_TCP_WIN 0
#define ipconfigTCP_TX_BUFFER_LENGTH (4 * 1460)
#define ipconfigTCP_RX_BUFFER_LENGTH (4 * 1460)
#define iptraceDHCP_SUCCEEDED(ip) network_dhcp_result(1)
#define iptraceDHCP_REQUESTS_FAILED_USING_DEFAULT_IP_ADDRESS(ip) network_dhcp_result(0)
#endif
