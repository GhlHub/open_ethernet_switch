#include "policy.h"
struct link_action link_update(struct link_policy *s, uint8_t desired, bool busy, uint32_t now)
{
    struct link_action a={0,0}; desired &= 0x1f;
    a.clear=s->enabled & (uint8_t)~desired;
    s->enabled &= desired;
    if (a.clear) s->last_clear_ms=now;
    /* Allow a full polling interval for CDC before accepting busy=0. */
    if (!busy && (uint32_t)(now-s->last_clear_ms)>=250u) {
        a.set=desired & (uint8_t)~s->enabled; s->enabled |= a.set;
    }
    return a;
}
void dhcp_result(struct dhcp_policy *s, bool leased, uint32_t now)
{ s->leased=leased; s->retry_wait=!leased; s->failed_ms=now; }
bool dhcp_retry(struct dhcp_policy *s, bool link, uint32_t now)
{
    if (!s->leased && s->retry_wait && link && (uint32_t)(now-s->failed_ms)>=60000u) {
        s->retry_wait=false; return true;
    }
    return false;
}
