// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

// Read-only AppleSMC adapter. Protocol layout follows the MIT-licensed Stats project.
// https://github.com/exelban/stats (Serhiy Mytrovtsiy and contributors).
#include "PerfMoonNative.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimits limits;
    SMCInfo info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} SMCData;
_Static_assert(sizeof(SMCData) == 80, "AppleSMC wire layout");
_Static_assert(offsetof(SMCData, bytes) == 48, "AppleSMC payload offset");
typedef struct { uint32_t key; SMCInfo info; } CacheItem;
struct PMSMC { io_connect_t connection; CacheItem cache[512]; unsigned used; };

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3];
}
static bool call(PMSMC *c, SMCData *in, SMCData *out) {
    size_t size = sizeof(*out);
    memset(out, 0, size);
    return IOConnectCallStructMethod(c->connection, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS && out->result == 0;
}
PMSMC *pm_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    PMSMC *c = calloc(1, sizeof(*c));
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &c->connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) { free(c); return NULL; }
    return c;
}
void pm_smc_close(PMSMC *c) { if (c) { IOServiceClose(c->connection); free(c); } }
bool pm_smc_read(PMSMC *c, const char *key, double *value) {
    if (!c || !key || strlen(key) != 4 || !value) return false;
    uint32_t code = fourcc(key);
    SMCInfo info = {0};
    for (unsigned i=0;i<c->used;i++) if (c->cache[i].key==code) { info=c->cache[i].info; break; }
    SMCData in = {0}, out = {0};
    if (!info.size) {
        in.key=code; in.command=9;
        if (!call(c,&in,&out) || !out.info.size || out.info.size>32) return false;
        info=out.info;
        if (c->used<512) c->cache[c->used++]=(CacheItem){code,info};
    }
    memset(&in,0,sizeof(in)); in.key=code; in.info.size=info.size; in.command=5;
    if (!call(c,&in,&out)) return false;
    char type[5]={(char)(info.type>>24),(char)(info.type>>16),(char)(info.type>>8),(char)info.type,0};
    const uint8_t *b=out.bytes;
    double v;
    if (!strcmp(type,"flt ") && info.size==4) { float f; memcpy(&f,b,4); v=f; }
    else if (!strcmp(type,"ui8 ") && info.size==1) v=b[0];
    else if (!strcmp(type,"ui16") && info.size==2) v=((uint16_t)b[0]<<8)|b[1];
    else if (!strcmp(type,"ui32") && info.size==4) v=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];
    else if ((type[0]=='s'||type[0]=='f') && type[1]=='p' && info.size==2) {
        char f[2]={type[3],0}; unsigned bits=(unsigned)strtoul(f,NULL,16);
        uint16_t raw=((uint16_t)b[0]<<8)|b[1];
        v=(type[0]=='s'?(double)(int16_t)raw:(double)raw)/(double)(1u<<bits);
    } else return false;
    if (!isfinite(v)) return false;
    *value=v; return true;
}
uint32_t pm_smc_key_count(PMSMC *c) {
    double value=0;
    if (!pm_smc_read(c,"#KEY",&value) || value<0 || value>32768) return 0;
    return (uint32_t)value;
}
bool pm_smc_key_at(PMSMC *c,uint32_t index,char out_key[5]) {
    if (!c || !out_key) return false;
    SMCData in={0},out={0}; in.command=8; in.data=index;
    if (!call(c,&in,&out)) return false;
    for (int i=0;i<4;i++) out_key[i]=(char)(out.key>>(24-8*i));
    out_key[4]=0; return true;
}
