#include "output.h"

#include <stdio.h>
#include "sdkconfig.h"

void output_emit(const probe_observation_t *obs, bool fresh, bool whitelisted)
{
#if CONFIG_PRINTBACK_JSON_OUTPUT
    printf("{\"t\":%lld,\"fp\":\"%s\",\"mac\":\"%02x%02x%02x%02x%02x%02x\","
           "\"rssi\":%d,\"ch\":%u,\"ies\":%u,\"new\":%s,\"wl\":%s}\n",
           (long long)obs->timestamp_us,
           obs->fp.hex,
           obs->src_mac[0], obs->src_mac[1], obs->src_mac[2],
           obs->src_mac[3], obs->src_mac[4], obs->src_mac[5],
           obs->rssi, obs->channel, obs->fp.ie_count,
           fresh       ? "true" : "false",
           whitelisted ? "true" : "false");
#else
    (void)obs; (void)fresh; (void)whitelisted;
#endif
}
