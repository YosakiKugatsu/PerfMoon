// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

// IOReport legends, DVFS layout and CLPC identifiers reference MIT-licensed macmon:
// https://github.com/vladkens/macmon/tree/52eb7799fa815cb512de9e4bf4bf801825365e7d/src
// See THIRD_PARTY_NOTICES.txt.
#include "PerfMoonNative.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>
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
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);

enum { ECPU, MCPU, PCPU, GPU, TABLE_COUNT, MAX_STATES = 64 };

typedef struct { double frequency[MAX_STATES]; int count; } FrequencyTable;
typedef struct { double weighted, active, total; bool frequency_valid, uncovered_state; } Residency;

struct PMReport {
    IOReportSubscriptionRef subscription;
    CFMutableDictionaryRef channels, request;
    CFDictionaryRef previous;
    double previous_time, cached_time;
    PMReportValues cached;
    FrequencyTable tables[TABLE_COUNT];
    uint32_t capabilities;
    uint32_t cpu_role[TABLE_COUNT - 1]; // Performance-state kinds -> exported frequency flags.
    int os_major;
    bool aggregate_gpu;
};

static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void text(CFStringRef value, char *out, size_t capacity) {
    if (!value || !CFStringGetCString(value, out, (CFIndex)capacity, kCFStringEncodingUTF8)) out[0] = 0;
}

static CFArrayRef channels_in(CFDictionaryRef report) {
    if (!report) return NULL;
    CFTypeRef value = CFDictionaryGetValue(report, CFSTR("IOReportChannels"));
    return value && CFGetTypeID(value) == CFArrayGetTypeID() ? (CFArrayRef)value : NULL;
}

static CFDataRef registry_data(io_registry_entry_t entry, const char *key) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!name) return NULL;
    CFTypeRef object = IORegistryEntryCreateCFProperty(entry, name, kCFAllocatorDefault, 0);
    CFRelease(name);
    if (object && CFGetTypeID(object) == CFDataGetTypeID()) return (CFDataRef)object;
    if (object) CFRelease(object);
    return NULL;
}

size_t pm_report_decode_frequency_table(const uint8_t *bytes, size_t length, double *values, size_t capacity) {
    if (!bytes || !values || length % 8 != 0) return 0;
    size_t count = 0;
    // Entries are pairs of little-endian 32-bit frequency and voltage. Older CPU
    // and all known GPU tables use Hz; newer CPU tables use kHz.
    for (size_t offset = 0; offset < length; offset += 8) {
        uint32_t raw;
        memcpy(&raw, bytes + offset, sizeof(raw));
        if (!raw && !count) continue; // GPU's initial OFF entry.
        double ghz = raw >= 100000000 ? raw / 1e9 : raw / 1e6;
        if (ghz < 0.1 || ghz > 10 || count >= capacity) return 0;
        // State numbers are positional. M4 GPU slots, for example, include
        // 1.056 GHz immediately followed by 1.053 GHz; preserve both in order.
        values[count++] = ghz;
    }
    return count;
}

static FrequencyTable read_frequencies(io_registry_entry_t pmgr, const char *key) {
    FrequencyTable table = {0};
    CFDataRef data = registry_data(pmgr, key);
    if (!data) return table;
    table.count = (int)pm_report_decode_frequency_table(CFDataGetBytePtr(data),
                                                       (size_t)CFDataGetLength(data),
                                                       table.frequency, MAX_STATES);
    CFRelease(data);
    return table;
}

static void tables_from_node(io_registry_entry_t pmgr, FrequencyTable *tables, FrequencyTable *fallback) {
    if (!tables[GPU].count) tables[GPU] = read_frequencies(pmgr, "voltage-states9");

    // Apple names the table indices in the PMGR acc-clusters property. Match by
    // cluster tier rather than inferring it from the frequency values.
    CFDataRef data = registry_data(pmgr, "acc-clusters");
    if (data) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        CFIndex length = CFDataGetLength(data);
        for (CFIndex offset = 0; length % 8 == 0 && offset + 8 <= length; offset += 8) {
            unsigned type = bytes[offset + 1];
            if (type > 2 || tables[type].count) continue;
            char key[32];
            snprintf(key, sizeof(key), "voltage-states%u-sram", (unsigned)bytes[offset]);
            tables[type] = read_frequencies(pmgr, key);
        }
        CFRelease(data);
    }
    if (fallback) {
        // These are the known ECPU and PCPU table keys. Keep them as separate
        // candidates until we have checked the real states of each channel.
        if (!fallback[ECPU].count) fallback[ECPU] = read_frequencies(pmgr, "voltage-states1-sram");
        if (!fallback[PCPU].count) fallback[PCPU] = read_frequencies(pmgr, "voltage-states5-sram");
    }
}

static void read_tables(FrequencyTable *tables, FrequencyTable *fallback) {
    io_registry_entry_t pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr");
    if (pmgr) {
        tables_from_node(pmgr, tables, fallback);
        IOObjectRelease(pmgr);
    }
    if (tables[ECPU].count && tables[MCPU].count && tables[PCPU].count && tables[GPU].count &&
        (!fallback || (fallback[ECPU].count && fallback[PCPU].count))) return;
    io_iterator_t nodes = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &nodes) != KERN_SUCCESS) return;
    for (io_registry_entry_t node; (node = IOIteratorNext(nodes)) != 0;) {
        io_name_t name;
        if (IORegistryEntryGetName(node, name) == KERN_SUCCESS &&
            (!strcmp(name, "pmgr") || !strcmp(name, "pmgr-child"))) tables_from_node(node, tables, fallback);
        IOObjectRelease(node);
    }
    IOObjectRelease(nodes);
}

typedef struct { const char *bundle; uint32_t key[3]; } CLPCMap;

// Aggregate counters, including both dies on Ultra, as documented in macmon's
// clpc.rs for macOS 27. Opaque IDs are never guessed on an unknown driver/OS.
static const CLPCMap clpc27[] = {
    {"AppleT6000CLPCv3", {0x47479059, 0x4519bf1e, 0x9aaa17f8}},
    {"AppleT6002CLPC",   {0xb501816b, 0x9e2c3e8b, 0x14d5a574}},
    {"AppleT6020CLPC",   {0xe301cd75, 0x8f34cc7a, 0x7415fb0f}},
    {"AppleT6022CLPC",   {0x76f5fd21, 0x90624499, 0x3c097307}},
    {"AppleT6030CLPC",   {0xbe03a01a, 0x472d6c9c, 0xb8990c38}},
    {"AppleT6031CLPC",   {0xd81e0084, 0x1085f98b, 0x313a3be1}},
    {"AppleT6032CLPC",   {0xf4a21308, 0x85e80513, 0x63dc8e25}},
    {"AppleT6041CLPC",   {0x263cf1f0, 0x22e4cf59, 0x7849fb5c}},
    {"AppleT6050CLPC",   {0xd3ab60bb, 0x27cd4ce5, 0x8c0f1c59}},
    {"AppleT6050dCLPC",  {0x18b3010e, 0xedeca11a, 0x188bd883}},
    {"AppleT8103CLPCv3", {0x2cdd31f2, 0x21becf42, 0x0667fb81}},
    {"AppleT8112CLPC",   {0xb5435137, 0x638d9d52, 0xea089c36}},
    {"AppleT8122CLPC",   {0x54b51c99, 0xce2dd9dc, 0x960afe2f}},
    {"AppleT8132CLPC",   {0x4a854d94, 0x3b3e3b79, 0x1ff4a9ec}},
    {"AppleT8140CLPC",   {0x9bf54436, 0xef70589c, 0x569d941b}},
    {"AppleT8142CLPC",   {0x43708744, 0x6a010933, 0xbc5efdf0}},
    {"AppleT8152CLPC",   {0x485d4bfc, 0x11784654, 0x9380c6bb}},
};

static const uint32_t energy_flags[] = {PM_REPORT_CPU_POWER, PM_REPORT_GPU_POWER, PM_REPORT_ANE_POWER};
static const char *energy_names[] = {"CPU Energy", "GPU Energy", "ANE"};
static const char *driver_prefix = "com.apple.driver.";

static CFNumberRef number(int64_t value) { return CFNumberCreate(NULL, kCFNumberSInt64Type, &value); }
static void put_number(CFMutableDictionaryRef d, CFStringRef key, int64_t value) {
    CFNumberRef n = number(value);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static CFMutableDictionaryRef energy_channel(uint64_t driver, uint64_t id, const char *name) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    put_number(d, CFSTR("DriverID"), (int64_t)driver);
    CFDictionarySetValue(d, CFSTR("DriverName"), CFSTR("AppleCLPC"));
    CFDictionarySetValue(d, CFSTR("IOReportGroupName"), CFSTR("CLPC"));
    CFDictionarySetValue(d, CFSTR("IOReportSubGroupName"), CFSTR("Energy Counters"));
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    put_number(info, CFSTR("IOReportChannelUnit"), (3LL << 56) | (118LL << 32)); // nJ
    CFDictionarySetValue(d, CFSTR("IOReportChannelInfo"), info);
    CFRelease(info);
    CFNumberRef channelID = number((int64_t)id), type = number(1LL | (2LL << 16) | (1LL << 32));
    CFStringRef label = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    const void *items[] = {channelID, type, label};
    CFArrayRef legend = CFArrayCreate(NULL, items, 3, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(d, CFSTR("LegendChannel"), legend);
    CFRelease(legend);
    CFRelease(channelID);
    CFRelease(type);
    CFRelease(label);
    return d;
}

static void append_clpc27(CFMutableArrayRef selected) {
    io_iterator_t services = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &services) != KERN_SUCCESS) return;
    for (io_service_t service; (service = IOIteratorNext(services)) != 0;) {
        CFTypeRef bundle = IORegistryEntryCreateCFProperty(service, CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0);
        char identifier[128] = {0};
        if (bundle && CFGetTypeID(bundle) == CFStringGetTypeID()) text((CFStringRef)bundle, identifier, sizeof(identifier));
        if (bundle) CFRelease(bundle);
        uint64_t driver = 0;
        kern_return_t status = IORegistryEntryGetRegistryEntryID(service, &driver);
        IOObjectRelease(service);
        if (status != KERN_SUCCESS || strncmp(identifier, driver_prefix, strlen(driver_prefix))) continue;
        for (size_t i = 0; i < sizeof(clpc27) / sizeof(*clpc27); i++) {
            if (strcmp(identifier + strlen(driver_prefix), clpc27[i].bundle)) continue;
            const uint64_t indices[] = {16, 25, 24};
            for (int counter = 0; counter < 3; counter++) {
                uint64_t id = (indices[counter] << 32) | clpc27[i].key[counter];
                CFMutableDictionaryRef item = energy_channel(driver, id, energy_names[counter]);
                CFArrayAppendValue(selected, item);
                CFRelease(item);
            }
            IOObjectRelease(services);
            return; // These are aggregate counters, do not sum duplicate reports.
        }
    }
    IOObjectRelease(services);
}

static bool suffix(const char *name, const char *end) {
    size_t n = strlen(name), e = strlen(end);
    return n >= e && !strcmp(name + n - e, end);
}

static int cpu_kind(const char *name) {
    if (strstr(name, "ECPU")) return ECPU;
    if (strstr(name, "MCPU")) return MCPU;
    if (strstr(name, "PCPU")) return PCPU;
    return -1;
}

static bool gpu_residency(const char *name) {
    return !strcmp(name, "GPUPH") || (!strncmp(name, "DIE_", 4) && suffix(name, "_GPUPH"));
}

static bool throttle_event(const char *name) {
    return (strstr(name, "MCPU") || strstr(name, "PCPU") || strstr(name, "MGPU")) &&
        (strstr(name, "THROTTLE_HW_TRIG") || strstr(name, "THROTTLE_SW_TRIG"));
}

static bool idle_state(const char *name) {
    return !strcmp(name, "IDLE") || !strcmp(name, "DOWN") || !strcmp(name, "OFF");
}

// Baseline samples contain state names even when their deltas are zero. A table
// can cover a prefix of the states (e.g. 13 defined GPU clocks on M5 Pro with
// 15 firmware slots). Samples with nonzero residency outside it omit frequency.
static size_t available_frequency_states(CFDictionaryRef sample) {
    size_t active_states = 0;
    bool idle = false;
    for (int i = 0; i < IOReportStateGetCount(sample); i++) {
        char name[80];
        text(IOReportStateGetNameForIndex(sample, i), name, sizeof(name));
        if (!name[0]) return 0;
        if (idle_state(name)) idle = true;
        else active_states++;
    }
    return idle ? active_states : 0;
}

static bool frequency_table_fits(const FrequencyTable *table, size_t available_active_states) {
    return table->count > 0 && (size_t)table->count <= available_active_states;
}

static int energy_kind(const char *name) {
    bool die = !strncmp(name, "DIE_", 4);
    if (!strcmp(name, "CPU Energy") || (die && suffix(name, "_CPU Energy"))) return 0;
    if (!strcmp(name, "GPU Energy") || (die && suffix(name, "_GPU Energy"))) return 1;
    if (!strncmp(name, "ANE", 3)) {
        // Legacy exports ANE, ANE0, or per-die names such as ANE0_0.
        for (const char *c = name + 3; *c; c++)
            if ((*c < '0' || *c > '9') && *c != '_') return -1;
        return 2;
    }
    return -1;
}

static double joules_per_unit(CFDictionaryRef channel) {
    char unit[24];
    text(IOReportChannelGetUnitLabel(channel), unit, sizeof(unit));
    if (!strcmp(unit, "J")) return 1;
    if (!strcmp(unit, "mJ")) return 1e-3;
    if (!strcmp(unit, "uJ") || !strcmp(unit, "µJ") || !strcmp(unit, "μJ")) return 1e-6;
    if (!strcmp(unit, "nJ")) return 1e-9;
    if (!strcmp(unit, "pJ")) return 1e-12;
    return 0;
}

PMReport *pm_report_open(uint32_t cpu_frequency_roles) {
    PMReport *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    char version[32] = {0};
    size_t length = sizeof(version);
    if (!sysctlbyname("kern.osproductversion", version, &length, NULL, 0)) c->os_major = atoi(version);
    FrequencyTable fallback[3] = {0};
    read_tables(c->tables, cpu_frequency_roles ? fallback : NULL);

    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    const CFStringRef groups[] = {CFSTR("CPU Stats"), CFSTR("GPU Stats"), CFSTR("SoC Stats"), CFSTR("Energy Model")};
    const CFStringRef subgroups[] = {CFSTR("CPU Core Performance States"), CFSTR("GPU Performance States"), CFSTR("Events"), NULL};
    for (int g = 0; g < 4; g++) {
        if (g == 0 && !cpu_frequency_roles) continue;
        CFDictionaryRef subset = IOReportCopyChannelsInGroup(groups[g], subgroups[g], 0, 0, 0);
        if (!subset) continue;
        if (!c->request) c->request = CFDictionaryCreateMutableCopy(NULL, 0, subset);
        CFArrayRef list = channels_in(subset);
        for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(list, i);
            char name[160];
            text(IOReportChannelGetChannelName(item), name, sizeof(name));
            int energy = g == 3 ? energy_kind(name) : -1;
            // Without Apple's entitlement, macOS 27+ may expose CPU/ANE Energy
            // Model channels that freeze and later catch up. Do not publish them.
            if ((g == 0 && cpu_kind(name) >= 0) ||
                (g == 1 && gpu_residency(name)) ||
                (g == 2 && throttle_event(name)) ||
                (energy >= 0 && ((c->os_major > 0 && c->os_major < 27) || energy == 1) && joules_per_unit(item) > 0))
                CFArrayAppendValue(selected, item);
        }
        CFRelease(subset);
    }
    if (c->os_major == 27) append_clpc27(selected);

    if (CFArrayGetCount(selected) > 0) {
        if (!c->request) c->request = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(c->request, CFSTR("IOReportChannels"), selected);
        c->subscription = IOReportCreateSubscription(NULL, c->request, &c->channels, 0, NULL);
        if (!c->subscription || !c->channels) {
            CFRelease(selected);
            pm_report_close(c);
            return NULL;
        }
    }
    CFRelease(selected);

    bool cpu[3] = {false};
    CFArrayRef subscribed = channels_in(c->channels);
    for (CFIndex i = 0; subscribed && i < CFArrayGetCount(subscribed); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(subscribed, i);
        char group[128], name[160];
        text(IOReportChannelGetGroup(item), group, sizeof(group));
        text(IOReportChannelGetChannelName(item), name, sizeof(name));
        if (!strcmp(group, "CPU Stats")) {
            int kind = cpu_kind(name);
            if (kind >= 0) cpu[kind] = true;
        } else if (!strcmp(group, "GPU Stats") && gpu_residency(name)) {
            if (!strcmp(name, "GPUPH")) c->aggregate_gpu = true;
            c->capabilities |= PM_REPORT_GPU_ACTIVITY;
            if (c->tables[GPU].count) c->capabilities |= PM_REPORT_GPU_FREQUENCY;
        } else if (!strcmp(group, "Energy Model") || !strcmp(group, "CLPC")) {
            int kind = energy_kind(name);
            if (kind >= 0) c->capabilities |= energy_flags[kind];
        }
    }
    if (cpu_frequency_roles & PM_REPORT_CPU_FREQUENCY_E) c->cpu_role[ECPU] = PM_REPORT_CPU_FREQUENCY_E;
    if (cpu_frequency_roles & PM_REPORT_CPU_FREQUENCY_S) {
        // When a Super tier exists, PCPU is its historical report name;
        // the separate Performance tier (if any) uses MCPU.
        c->cpu_role[PCPU] = PM_REPORT_CPU_FREQUENCY_S;
        if (cpu_frequency_roles & PM_REPORT_CPU_FREQUENCY_P) c->cpu_role[MCPU] = PM_REPORT_CPU_FREQUENCY_P;
    } else if (cpu_frequency_roles & PM_REPORT_CPU_FREQUENCY_P) {
        c->cpu_role[PCPU] = PM_REPORT_CPU_FREQUENCY_P;
    }
    pm_report_rebaseline(c);
    CFArrayRef baseline = channels_in(c->previous);
    if (c->subscription && !baseline) {
        // A missing baseline is a transient read failure, not a missing feature.
        pm_report_close(c);
        return NULL;
    }
    size_t cpu_state_limit[3] = {SIZE_MAX, SIZE_MAX, SIZE_MAX};
    bool cpu_baseline_seen[3] = {false};
    for (CFIndex i = 0; baseline && i < CFArrayGetCount(baseline); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(baseline, i);
        char group[128], name[160];
        text(IOReportChannelGetGroup(item), group, sizeof(group));
        text(IOReportChannelGetChannelName(item), name, sizeof(name));
        if (!strcmp(group, "CPU Stats")) {
            int kind = cpu_kind(name);
            if (kind >= 0 && c->cpu_role[kind]) {
                size_t available = available_frequency_states(item);
                if (available < cpu_state_limit[kind]) cpu_state_limit[kind] = available;
                cpu_baseline_seen[kind] = true;
            }
        } else if (!strcmp(group, "GPU Stats") && gpu_residency(name) &&
                   (!c->aggregate_gpu || !strcmp(name, "GPUPH")) &&
                   !frequency_table_fits(&c->tables[GPU], available_frequency_states(item))) {
            c->capabilities &= ~PM_REPORT_GPU_FREQUENCY;
        }
    }
    for (int kind = ECPU; kind <= PCPU; kind++) {
        if (!cpu_baseline_seen[kind]) continue;
        size_t available = cpu_state_limit[kind];
        if (!frequency_table_fits(&c->tables[kind], available)) {
            // Firmware can put its sole fast group in type 1 while IOReport
            // calls it PCPU. Reuse that mapping only when there is no separate
            // MCPU channel or role, so P and S never borrow each other's table.
            if (kind == PCPU && !cpu[MCPU] && !c->cpu_role[MCPU] &&
                frequency_table_fits(&c->tables[MCPU], available)) {
                c->tables[kind] = c->tables[MCPU];
            } else if (frequency_table_fits(&fallback[kind], available)) {
                c->tables[kind] = fallback[kind];
            } else {
                continue;
            }
        }
        c->capabilities |= c->cpu_role[kind];
    }
    return c;
}

uint32_t pm_report_capabilities(const PMReport *c) { return c ? c->capabilities : 0; }

void pm_report_close(PMReport *c) {
    if (!c) return;
    if (c->previous) CFRelease(c->previous);
    if (c->subscription) CFRelease(c->subscription);
    if (c->channels) CFRelease(c->channels);
    if (c->request) CFRelease(c->request);
    free(c);
}

void pm_report_rebaseline(PMReport *c) {
    if (!c || !c->subscription) return;
    if (c->previous) CFRelease(c->previous);
    c->previous = IOReportCreateSamples(c->subscription, c->channels, NULL);
    c->previous_time = now_seconds();
    c->cached_time = 0;
}

static bool states(CFDictionaryRef item, const FrequencyTable *table, Residency *total) {
    Residency sample = {.frequency_valid = table->count > 0};
    int active_states = 0, count = IOReportStateGetCount(item);
    bool has_idle_state = false;
    for (int i = 0; i < count; i++) {
        int64_t raw = IOReportStateGetResidency(item, i);
        if (raw < 0) return false; // Counter reset or invalid slot.
        char name[80];
        text(IOReportStateGetNameForIndex(item, i), name, sizeof(name));
        if (!name[0]) return false;
        sample.total += (double)raw;
        if (idle_state(name)) {
            has_idle_state = true;
            continue;
        }
        sample.active += (double)raw;
        if (active_states < table->count) sample.weighted += (double)raw * table->frequency[active_states];
        else if (raw > 0) {
            sample.frequency_valid = false;
            sample.uncovered_state = true;
        }
        active_states++;
    }
    if (!has_idle_state || !active_states || sample.total <= 0) return false;
    if (active_states < table->count) sample.frequency_valid = false;
    total->frequency_valid = total->total > 0 ? total->frequency_valid && sample.frequency_valid : sample.frequency_valid;
    total->uncovered_state |= sample.uncovered_state;
    total->active += sample.active;
    total->total += sample.total;
    total->weighted += sample.weighted;
    return true;
}

int pm_report_read(PMReport *c, PMReportValues *out) {
    if (!c || !out || !c->subscription) return -1;
    double now = now_seconds();
    if (c->cached_time && now - c->cached_time < 0.15) {
        *out = c->cached;
        return 1;
    }
    if (!c->previous) {
        pm_report_rebaseline(c);
        return c->previous ? 0 : -1;
    }
    double elapsed = now - c->previous_time;
    if (elapsed < 0.01) return 0;
    CFDictionaryRef current = IOReportCreateSamples(c->subscription, c->channels, NULL);
    if (!current) return -1;
    CFDictionaryRef delta = IOReportCreateSamplesDelta(c->previous, current, NULL);
    CFRelease(c->previous);
    c->previous = current;
    c->previous_time = now;
    if (!delta) return -1;

    PMReportValues result = {.elapsed_seconds = elapsed};
    Residency cpu[3] = {0}, gpu = {0};
    double clpc[] = {-1, -1, -1}, named[] = {-1, -1, -1}, per_die[] = {-1, -1, -1};
    CFArrayRef list = channels_in(delta);
    if (!list) {
        CFRelease(delta);
        return -1;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(list, i);
        char group[128], name[160];
        text(IOReportChannelGetGroup(item), group, sizeof(group));
        text(IOReportChannelGetChannelName(item), name, sizeof(name));
        bool is_clpc = !strcmp(group, "CLPC");
        if (is_clpc || !strcmp(group, "Energy Model")) {
            int kind = energy_kind(name);
            if (kind < 0) continue;
            int64_t energy = IOReportSimpleGetIntegerValue(item, 0);
            double unit = is_clpc ? 1e-9 : joules_per_unit(item);
            if (energy < 0 || unit == 0) continue;
            double watts = (double)energy * unit / elapsed;
            if (!isfinite(watts) || watts > 1000) continue;
            if (is_clpc) clpc[kind] = watts;
            else if (!strncmp(name, "DIE_", 4) || (kind == 2 && strchr(name, '_')))
                per_die[kind] = fmax(0, per_die[kind]) + watts;
            else named[kind] = fmax(0, named[kind]) + watts;
        } else if (!strcmp(group, "CPU Stats")) {
            int kind = cpu_kind(name);
            if (kind >= 0) states(item, &c->tables[kind], &cpu[kind]);
        } else if (!strcmp(group, "GPU Stats") && gpu_residency(name) &&
                   (!c->aggregate_gpu || !strcmp(name, "GPUPH"))) {
            states(item, &c->tables[GPU], &gpu);
        } else if (!strcmp(group, "SoC Stats") && throttle_event(name)) {
            // These are state residencies, not simple counters.
            for (int state = 0; state < IOReportStateGetCount(item); state++) {
                char label[32];
                text(IOReportStateGetNameForIndex(item, state), label, sizeof(label));
                if (strcmp(label, "ACT")) continue;
                int64_t residency = IOReportStateGetResidency(item, state);
                if (residency < 0) continue;
                if (strstr(name, "MGPU")) {
                    result.valid |= PM_REPORT_GPU_THROTTLE;
                    if (residency > 0) result.gpu_throttle_active = 1;
                } else if (residency > 0) result.cpu_throttle_active = 1;
            }
        }
    }
    double *watts[] = {&result.cpu_watts, &result.gpu_watts, &result.ane_watts};
    for (int kind = 0; kind < 3; kind++) {
        double value = clpc[kind] >= 0 ? clpc[kind] : (named[kind] >= 0 ? named[kind] : per_die[kind]);
        if (value >= 0 && value <= 1000) {
            *watts[kind] = value;
            result.valid |= energy_flags[kind];
        }
    }
    for (int kind = ECPU; kind <= PCPU; kind++) {
        uint32_t flag = c->cpu_role[kind];
        if (!(c->capabilities & flag)) continue;
        if (cpu[kind].uncovered_state) result.unavailable |= flag;
        if (!cpu[kind].frequency_valid) continue;
        double ghz = cpu[kind].active > 0 ? cpu[kind].weighted / cpu[kind].active : 0;
        if (flag == PM_REPORT_CPU_FREQUENCY_E) result.e_ghz = ghz;
        if (flag == PM_REPORT_CPU_FREQUENCY_S) result.s_ghz = ghz;
        if (flag == PM_REPORT_CPU_FREQUENCY_P) result.p_ghz = ghz;
        result.valid |= flag;
    }
    if (gpu.total > 0) {
        result.gpu_percent = fmin(100, fmax(0, gpu.active / gpu.total * 100));
        result.valid |= PM_REPORT_GPU_ACTIVITY;
        if (gpu.frequency_valid && (c->capabilities & PM_REPORT_GPU_FREQUENCY)) {
            result.gpu_ghz = gpu.active > 0 ? gpu.weighted / gpu.active : 0;
            result.valid |= PM_REPORT_GPU_FREQUENCY;
        }
        if (gpu.uncovered_state) result.unavailable |= PM_REPORT_GPU_FREQUENCY;
    }
    CFRelease(delta);
    c->cached = result;
    c->cached_time = now;
    *out = result;
    // The transport succeeded even if this snapshot has no usable counter.
    return 1;
}

bool pm_report_sample(PMReport *c, PMReportValues *out) { return pm_report_read(c, out) > 0 && out->valid != 0; }

// Per-core Energy Model counters are refreshed by Apple's privileged sampler.
// Subscribe only to individually identified cores and the reference CPU counter.
struct PMCoreEnergy {
    IOReportSubscriptionRef subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    CFMutableDictionaryRef indices;
    double *joules;
    double previous_time;
};

PMCoreEnergy *pm_core_energy_open(const PMCoreLocation *locations, size_t count) {
    if (!locations || !count) return NULL;
    CFDictionaryRef group = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFArrayRef all = channels_in(group);
    if (!all) { if (group) CFRelease(group); return NULL; }
    PMCoreEnergy *c = calloc(1, sizeof(*c));
    if (!c) { CFRelease(group); return NULL; }
    c->joules = calloc(count, sizeof(*c->joules));
    if (!c->joules) { CFRelease(group); free(c); return NULL; }
    c->indices = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (size_t core = 0; core < count; core++) {
        PMCoreLocation loc = locations[core];
        if (!loc.tier) continue;
        bool only_cluster = true;
        for (size_t j = 0; j < count; j++) {
            if (locations[j].tier == loc.tier && locations[j].cluster != loc.cluster) only_cluster = false;
        }
        char numbered[48], single[48];
        snprintf(numbered, sizeof(numbered), "%cCPU%u_%u", loc.tier, loc.cluster, loc.slot);
        snprintf(single, sizeof(single), "%cACC_%u", loc.tier, loc.slot);
        CFDictionaryRef match = NULL;
        for (CFIndex j = 0; j < CFArrayGetCount(all); j++) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(all, j);
            char label[80];
            text(IOReportChannelGetChannelName(item), label, sizeof(label));
            if (strcmp(label, numbered) && (!only_cluster || strcmp(label, single))) continue;
            if (match) { match = NULL; break; }  // Ambiguous across drivers or dies.
            if (joules_per_unit(item) > 0) match = item;
        }
        if (match) {
            CFStringRef name = IOReportChannelGetChannelName(match);
            c->joules[core] = joules_per_unit(match);
            put_number(c->indices, name, (int64_t)core);
            CFArrayAppendValue(selected, match);
        }
    }
    bool reference = false;
    for (CFIndex j = 0; j < CFArrayGetCount(all); j++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(all, j);
        CFStringRef name = IOReportChannelGetChannelName(item);
        if (name && CFEqual(name, CFSTR("CPU Energy")) && joules_per_unit(item) > 0) {
            if (reference) { reference = false; break; }
            CFArrayAppendValue(selected, item);
            reference = true;
        }
    }
    if (reference && CFDictionaryGetCount(c->indices) > 0) {
        CFMutableDictionaryRef request = CFDictionaryCreateMutableCopy(NULL, 0, group);
        CFDictionarySetValue(request, CFSTR("IOReportChannels"), selected);
        c->subscription = IOReportCreateSubscription(NULL, request, &c->channels, 0, NULL);
        CFRelease(request);
    }
    CFRelease(selected);
    CFRelease(group);
    if (!c->subscription || !c->channels) { pm_core_energy_close(c); return NULL; }
    return c;
}

void pm_core_energy_close(PMCoreEnergy *c) {
    if (!c) return;
    if (c->previous) CFRelease(c->previous);
    if (c->subscription) CFRelease(c->subscription);
    if (c->channels) CFRelease(c->channels);
    if (c->indices) CFRelease(c->indices);
    free(c->joules);
    free(c);
}

bool pm_core_energy_read(PMCoreEnergy *c, double *watts, size_t count, double *elapsed) {
    if (!c || !watts || !elapsed) return false;
    CFDictionaryRef current = IOReportCreateSamples(c->subscription, c->channels, NULL);
    if (!current) return false;
    double now = now_seconds();
    *elapsed = now - c->previous_time;
    CFDictionaryRef delta = c->previous ? IOReportCreateSamplesDelta(c->previous, current, NULL) : NULL;
    if (c->previous) CFRelease(c->previous);
    c->previous = current;
    c->previous_time = now;
    if (!delta) return false;
    CFArrayRef list = channels_in(delta);
    bool advancing = false;
    for (size_t i = 0; i < count; i++) watts[i] = NAN;
    for (CFIndex i = 0; list && *elapsed > 0 && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(list, i);
        CFStringRef name = IOReportChannelGetChannelName(item);
        if (!name) continue;
        int64_t value = IOReportSimpleGetIntegerValue(item, 0);
        if (CFEqual(name, CFSTR("CPU Energy"))) { advancing = value > 0; continue; }
        CFNumberRef index = CFDictionaryGetValue(c->indices, name);
        int n = -1;
        if (value >= 0 && index && CFNumberGetValue(index, kCFNumberIntType, &n) && n >= 0 && (size_t)n < count) {
            watts[n] = (double)value * c->joules[n] / *elapsed;
        }
    }
    CFRelease(delta);
    return advancing;
}
