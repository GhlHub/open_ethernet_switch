#include "policy.h"
#include <assert.h>
#include <stdio.h>
int main(void)
{
    struct network_link_policy link={0};
    assert(!network_link_ready(&link,false,0,1000));
    assert(!network_link_ready(&link,true,250,1000));
    assert(!network_link_ready(&link,true,1249,1000));
    assert(network_link_ready(&link,true,1250,1000));
    assert(network_link_ready(&link,true,1500,1000));
    assert(network_link_ready(&link,true,250,1000)); /* ready stays latched across full timer wrap */
    assert(!network_link_ready(&link,false,1501,1000));
    assert(!network_link_ready(&link,true,1600,1000));
    assert(!network_link_ready(&link,false,1800,1000));
    assert(!network_link_ready(&link,true,2000,1000));
    assert(!network_link_ready(&link,true,2999,1000));
    assert(network_link_ready(&link,true,3000,1000));
    link.physical=false;
    assert(!network_link_ready(&link,true,UINT32_MAX-499,1000));
    assert(!network_link_ready(&link,true,499,1000));
    assert(network_link_ready(&link,true,500,1000));
    link.physical=false;
    assert(network_link_ready(&link,true,600,0)); /* static IP unchanged */
    struct link_policy s={0,0};
    struct link_action a=link_update(&s,0x1f,false,249); assert(!a.set);
    a=link_update(&s,0x1f,false,250); assert(a.set==0x1f && !a.clear);
    a=link_update(&s,0x1b,false,500); assert(a.clear==4 && !a.set);
    a=link_update(&s,0x1f,false,501); assert(!a.set); /* busy CDC latency */
    a=link_update(&s,0x1f,true,750); assert(!a.set);
    a=link_update(&s,0x1f,false,1000); assert(a.set==4);
    a=link_update(&s,0x1f,false,1250); assert(!a.set && !a.clear);
    a=link_update(&s,0,false,1500); assert(a.clear==0x1f);
    a=link_update(&s,0,false,1750); assert(!a.clear); /* no repeated toggle */
    s.last_clear_ms=UINT32_MAX-100; a=link_update(&s,1,false,150); assert(a.set==1);
    struct dhcp_policy d={0}; assert(!dhcp_retry(&d,true,60000));
    dhcp_result(&d,false,1000); assert(!dhcp_retry(&d,true,60999));
    assert(!dhcp_retry(&d,false,61000)); assert(dhcp_retry(&d,true,61000));
    assert(!dhcp_retry(&d,true,62000)); /* no overlapping attempt */
    dhcp_result(&d,true,62000); assert(!dhcp_retry(&d,true,200000));
    dhcp_result(&d,false,UINT32_MAX-100); assert(!dhcp_retry(&d,true,59898));
    assert(dhcp_retry(&d,true,59899));
    puts("PASS: link admission/flush sequencing, DHCP retry and timer wrap");
}
