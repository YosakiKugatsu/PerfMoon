// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

// Narrow, read-only IOReport adapter for this M5 Pro / macOS 27 configuration.
// CLPC identifiers and report legend conventions are based on MIT-licensed macmon.
// https://github.com/vladkens/macmon -- see THIRD_PARTY_NOTICES.
#include "PerfMoonNative.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

typedef const void *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);

struct PMReport {
    IOReportSubscriptionRef subscription;
    CFMutableDictionaryRef channels, request;
    CFDictionaryRef previous;
    double previous_time, cached_time;
    PMReportValues cached;
    double s_frequencies[64], p_frequencies[64], gpu_frequencies[64];
    int s_count, p_count, gpu_count;
};

static double now_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    return (double)t.tv_sec+(double)t.tv_nsec/1e9;
}
static void text(CFStringRef value, char *out, size_t capacity) {
    out[0]=0;
    if (value) CFStringGetCString(value,out,(CFIndex)capacity,kCFStringEncodingUTF8);
}
static CFNumberRef number(int64_t value) { return CFNumberCreate(NULL,kCFNumberSInt64Type,&value); }
static void put_number(CFMutableDictionaryRef d,CFStringRef key,int64_t value) {
    CFNumberRef n=number(value); CFDictionarySetValue(d,key,n); CFRelease(n);
}
static CFMutableDictionaryRef energy_channel(uint64_t driver,uint64_t id,const char *name) {
    CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    put_number(d,CFSTR("DriverID"),(int64_t)driver);
    CFDictionarySetValue(d,CFSTR("DriverName"),CFSTR("AppleCLPC"));
    CFDictionarySetValue(d,CFSTR("IOReportGroupName"),CFSTR("CLPC"));
    CFDictionarySetValue(d,CFSTR("IOReportSubGroupName"),CFSTR("Energy Counters"));
    CFMutableDictionaryRef info=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    put_number(info,CFSTR("IOReportChannelUnit"),(3LL<<56)|(118LL<<32));
    CFDictionarySetValue(d,CFSTR("IOReportChannelInfo"),info); CFRelease(info);
    CFNumberRef channelID=number((int64_t)id),type=number(1LL|(2LL<<16)|(1LL<<32));
    CFStringRef label=CFStringCreateWithCString(NULL,name,kCFStringEncodingUTF8);
    const void *items[]={channelID,type,label};
    CFArrayRef legend=CFArrayCreate(NULL,items,3,&kCFTypeArrayCallBacks);
    CFDictionarySetValue(d,CFSTR("LegendChannel"),legend);
    CFRelease(legend); CFRelease(channelID); CFRelease(type); CFRelease(label);
    return d;
}
static int read_frequencies(io_registry_entry_t pmgr,const char *key,double *out,double divisor,bool skip_zero) {
    CFStringRef name=CFStringCreateWithCString(NULL,key,kCFStringEncodingUTF8);
    CFTypeRef object=IORegistryEntryCreateCFProperty(pmgr,name,kCFAllocatorDefault,0); CFRelease(name);
    if (!object || CFGetTypeID(object)!=CFDataGetTypeID()) { if(object)CFRelease(object); return 0; }
    CFDataRef data=(CFDataRef)object; const uint8_t *bytes=CFDataGetBytePtr(data); int count=0;
    for(CFIndex i=0;i+8<=CFDataGetLength(data) && count<64;i+=8) {
        uint32_t raw; memcpy(&raw,bytes+i,4);
        if (!raw && skip_zero) continue;
        out[count++]=(double)raw/divisor;
    }
    CFRelease(object); return count;
}
PMReport *pm_report_open(void) {
    char version[32]={0}; size_t length=sizeof(version);
    if(sysctlbyname("kern.osproductversion",version,&length,NULL,0) || atoi(version)!=27) return NULL;
    PMReport *c=calloc(1,sizeof(*c));
    io_registry_entry_t pmgr=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/arm-io/pmgr");
    if(pmgr) {
        c->s_count=read_frequencies(pmgr,"voltage-states5-sram",c->s_frequencies,1e6,true);
        c->p_count=read_frequencies(pmgr,"voltage-states23-sram",c->p_frequencies,1e6,true);
        c->gpu_count=read_frequencies(pmgr,"voltage-states9",c->gpu_frequencies,1e9,true);
        IOObjectRelease(pmgr);
    }
    CFMutableArrayRef selected=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    const CFStringRef groups[]={CFSTR("CPU Stats"),CFSTR("GPU Stats"),CFSTR("SoC Stats")};
    const CFStringRef subgroups[]={CFSTR("CPU Core Performance States"),CFSTR("GPU Performance States"),CFSTR("Events")};
    for(int g=0;g<3;g++) {
      CFDictionaryRef subset=IOReportCopyChannelsInGroup(groups[g],subgroups[g],0,0,0);
      if(!subset)continue;
      if(!c->request)c->request=CFDictionaryCreateMutableCopy(NULL,0,subset);
      CFArrayRef list=CFDictionaryGetValue(subset,CFSTR("IOReportChannels"));
      for(CFIndex i=0;list && i<CFArrayGetCount(list);i++) {
        CFDictionaryRef item=CFArrayGetValueAtIndex(list,i);
        char group[128],subgroup[128],name[160];
        text(IOReportChannelGetGroup(item),group,sizeof(group));
        text(IOReportChannelGetSubGroup(item),subgroup,sizeof(subgroup));
        text(IOReportChannelGetChannelName(item),name,sizeof(name));
        bool cpu=!strcmp(group,"CPU Stats") && !strcmp(subgroup,"CPU Core Performance States");
        bool gpu=!strcmp(group,"GPU Stats") && !strcmp(subgroup,"GPU Performance States") && !strcmp(name,"GPUPH");
        bool throttle=!strcmp(group,"SoC Stats") && !strcmp(subgroup,"Events") &&
            (!strncmp(name,"MCPU0_",6)||!strncmp(name,"MCPU1_",6)||!strncmp(name,"PCPU_",5)||!strncmp(name,"MGPU",4)) &&
            (strstr(name,"THROTTLE_HW_TRIG")||strstr(name,"THROTTLE_SW_TRIG"));
        if(cpu||gpu||throttle) CFArrayAppendValue(selected,item);
      }
      CFRelease(subset);
    }
    io_service_t clpc=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleCLPC"));
    if(clpc) {
        CFTypeRef bundle=IORegistryEntryCreateCFProperty(clpc,CFSTR("CFBundleIdentifier"),kCFAllocatorDefault,0);
        uint64_t driver=0;
        if(bundle && CFEqual(bundle,CFSTR("com.apple.driver.AppleT6050CLPC")) && IORegistryEntryGetRegistryEntryID(clpc,&driver)==KERN_SUCCESS) {
            const uint64_t ids[]={ (16ULL<<32)|0xd3ab60bbULL,(25ULL<<32)|0x27cd4ce5ULL,(24ULL<<32)|0x8c0f1c59ULL };
            const char *names[]={"CPU Energy","GPU Energy","ANE"};
            for(int i=0;i<3;i++) {
                CFMutableDictionaryRef item=energy_channel(driver,ids[i],names[i]);
                CFArrayAppendValue(selected,item); CFRelease(item);
            }
        }
        if(bundle)CFRelease(bundle); IOObjectRelease(clpc);
    }
    if(!c->request)c->request=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(c->request,CFSTR("IOReportChannels"),selected);
    c->subscription=IOReportCreateSubscription(NULL,c->request,&c->channels,0,NULL);
    CFRelease(selected);
    if(!c->subscription || !c->channels) { pm_report_close(c); return NULL; }
    pm_report_rebaseline(c);
    return c;
}
void pm_report_close(PMReport *c) {
    if(!c)return;
    if(c->previous)CFRelease(c->previous);
    if(c->subscription)CFRelease(c->subscription);
    if(c->channels)CFRelease(c->channels);
    if(c->request)CFRelease(c->request);
    free(c);
}
void pm_report_rebaseline(PMReport *c) {
    if(!c)return;
    if(c->previous)CFRelease(c->previous);
    c->previous=IOReportCreateSamples(c->subscription,c->channels,NULL);
    c->previous_time=now_seconds(); c->cached_time=0;
    memset(&c->cached,0,sizeof(c->cached));
}
static void states(CFDictionaryRef item,const double *frequencies,int n,double *weighted,double *active,double *total) {
    int index=0;
    for(int i=0;i<IOReportStateGetCount(item);i++) {
        int64_t raw=IOReportStateGetResidency(item,i);
        char name[80]; text(IOReportStateGetNameForIndex(item,i),name,sizeof(name));
        if(raw>=0)*total+=(double)raw;
        if(!strcmp(name,"IDLE")||!strcmp(name,"DOWN")||!strcmp(name,"OFF"))continue;
        // A reset/invalid counter must not shift the frequency-state lookup.
        if(raw>=0 && index<n) { *weighted+=(double)raw*frequencies[index]; *active+=(double)raw; }
        index++;
    }
}
int pm_report_read(PMReport *c,PMReportValues *out) {
    if(!c||!out)return -1;
    double now=now_seconds();
    if(c->cached_time && now-c->cached_time<0.15) { *out=c->cached; return c->cached.valid?1:-1; }
    if(!c->previous) { pm_report_rebaseline(c); return c->previous?0:-1; }
    CFDictionaryRef current=IOReportCreateSamples(c->subscription,c->channels,NULL);
    if(!current)return -1;
    double elapsed=now-c->previous_time;
    if(elapsed<0.01) { CFRelease(current); return 0; }
    CFDictionaryRef delta=IOReportCreateSamplesDelta(c->previous,current,NULL);
    CFRelease(c->previous); c->previous=current; c->previous_time=now;
    if(!delta)return -1;
    PMReportValues result={0}; result.elapsed_seconds=elapsed;
    double sw=0,sa=0,st=0,pw=0,pa=0,pt=0,gw=0,ga=0,gt=0;
    CFArrayRef list=CFDictionaryGetValue(delta,CFSTR("IOReportChannels"));
    for(CFIndex i=0;list && i<CFArrayGetCount(list);i++) {
        CFDictionaryRef item=CFArrayGetValueAtIndex(list,i);
        char group[128],name[160]; text(IOReportChannelGetGroup(item),group,sizeof(group)); text(IOReportChannelGetChannelName(item),name,sizeof(name));
        if(!strcmp(group,"CLPC")) {
            int64_t energy=IOReportSimpleGetIntegerValue(item,0);
            if(energy<0)continue;
            double watts=(double)energy/1e9/elapsed;
            if(!isfinite(watts)||watts>500)continue;
            if(!strcmp(name,"CPU Energy")) {result.cpu_watts=watts;result.valid|=PM_REPORT_CPU_POWER;}
            else if(!strcmp(name,"GPU Energy")) {result.gpu_watts=watts;result.valid|=PM_REPORT_GPU_POWER;}
            else if(!strcmp(name,"ANE")) {result.ane_watts=watts;result.valid|=PM_REPORT_ANE_POWER;}
        } else if(!strcmp(group,"CPU Stats")) {
            if(!strncmp(name,"MCPU",4))states(item,c->p_frequencies,c->p_count,&pw,&pa,&pt);
            else if(!strncmp(name,"PCPU",4))states(item,c->s_frequencies,c->s_count,&sw,&sa,&st);
        } else if(!strcmp(group,"GPU Stats")) {
            states(item,c->gpu_frequencies,c->gpu_count,&gw,&ga,&gt);
        } else if(!strcmp(group,"SoC Stats")) {
            // These are state-residency channels (INACT/ACT), not simple counters.
            // Reading them with IOReportSimpleGetIntegerValue returns its invalid sentinel.
            for(int state=0;state<IOReportStateGetCount(item);state++) {
                char label[32];text(IOReportStateGetNameForIndex(item,state),label,sizeof(label));
                if(strcmp(label,"ACT"))continue;
                int64_t residency=IOReportStateGetResidency(item,state);
                if(residency<0)continue;
                if(!strncmp(name,"MGPU",4)) {
                    result.valid|=PM_REPORT_GPU_THROTTLE;
                    if(residency>0)result.gpu_throttle_active=1;
                } else if(residency>0)result.cpu_throttle_active=1;
            }
        }
    }
    if(c->s_count && c->p_count && st>0 && pt>0) {
        result.s_ghz=sa>0?sw/sa:0;result.p_ghz=pa>0?pw/pa:0;result.valid|=PM_REPORT_CPU_FREQUENCY;
    }
    if(c->gpu_count && gt>0) {
        result.gpu_ghz=ga>0?gw/ga:0;result.gpu_percent=fmin(100,fmax(0,ga/gt*100));result.valid|=PM_REPORT_GPU_ACTIVITY;
    }
    CFRelease(delta); c->cached=result;c->cached_time=now;*out=result;
    return result.valid?1:-1;
}
bool pm_report_sample(PMReport *c,PMReportValues *out) { return pm_report_read(c,out)>0; }
