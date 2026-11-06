#ifndef PERFMOON_NATIVE_H
#define PERFMOON_NATIVE_H
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
    double s_ghz, p_ghz, gpu_ghz, gpu_percent;
    double elapsed_seconds;
    double cpu_throttle_active;
    double gpu_throttle_active;
    uint32_t valid;
} PMReportValues;
enum {
    PM_REPORT_CPU_POWER = 1,
    PM_REPORT_GPU_POWER = 2,
    PM_REPORT_ANE_POWER = 4,
    PM_REPORT_CPU_FREQUENCY = 8,
    PM_REPORT_GPU_ACTIVITY = 16,
    PM_REPORT_GPU_THROTTLE = 32
};
PMReport *pm_report_open(void);
void pm_report_close(PMReport *context);
void pm_report_rebaseline(PMReport *context);
/// -1 = read failed, 0 = baseline/too soon, 1 = a new or coalesced sample.
/// This distinction lets callers retry I/O failures instead of staying stale forever.
int pm_report_read(PMReport *context, PMReportValues *values);
bool pm_report_sample(PMReport *context, PMReportValues *values);
#endif
