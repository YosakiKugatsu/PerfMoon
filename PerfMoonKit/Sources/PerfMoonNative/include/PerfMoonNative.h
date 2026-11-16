// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

#ifndef PERFMOON_NATIVE_H
#define PERFMOON_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct PMSMC PMSMC;
PMSMC *pm_smc_open(void);
void pm_smc_close(PMSMC *context);
uint32_t pm_smc_key_count(PMSMC *context);
bool pm_smc_key_at(PMSMC *context, uint32_t index, char out_key[5]);
bool pm_smc_read(PMSMC *context, const char *key, double *value);

typedef struct PMReport PMReport;
typedef struct {
    double cpu_watts, gpu_watts, ane_watts;
    double e_ghz, s_ghz, p_ghz, gpu_ghz, gpu_percent;
    double elapsed_seconds;
    double cpu_throttle_active;
    double gpu_throttle_active;
    uint32_t valid, unavailable;
} PMReportValues;
enum {
    PM_REPORT_CPU_POWER = 1,
    PM_REPORT_GPU_POWER = 2,
    PM_REPORT_ANE_POWER = 4,
    PM_REPORT_CPU_FREQUENCY_S = 8,
    PM_REPORT_GPU_ACTIVITY = 16,
    PM_REPORT_GPU_THROTTLE = 32,
    PM_REPORT_GPU_FREQUENCY = 64,
    PM_REPORT_CPU_FREQUENCY_P = 128,
    PM_REPORT_CPU_FREQUENCY_E = 256
};
// Pass the frequency flags for CPU tiers independently verified on this Mac.
// An ambiguous topology gets GPU/energy readings, but no guessed frequencies.
PMReport *pm_report_open(uint32_t cpu_frequency_roles);
uint32_t pm_report_capabilities(const PMReport *context);
// Decode PMGR's frequency/voltage pairs in their original state-slot order.
size_t pm_report_decode_frequency_table(const uint8_t *bytes, size_t length, double *values, size_t capacity);
void pm_report_close(PMReport *context);
void pm_report_rebaseline(PMReport *context);
/// -1 = I/O failed, 0 = baseline/too soon, 1 = a new or coalesced sample.
/// Valid metric bits and unsupported states within that window are separate
/// from the transport result.
int pm_report_read(PMReport *context, PMReportValues *values);
bool pm_report_sample(PMReport *context, PMReportValues *values);
#endif
