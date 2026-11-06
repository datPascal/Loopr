# Private database audits

The normal test target uses repository fixtures. Eight additional tests audit copies of private device databases. These copies are not distributed with the open-source project, and some assertions refer to a particular historical capture.

Compile with `LOOPR_PRIVATE_DATABASE_AUDITS` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to register those tests. Preserve the existing `DEBUG` condition. Run them through the simulator fleet wrapper with the corresponding environment variables passed to the test host. An enabled audit fails when its input is missing.

| Test class and method | Required local input |
|---|---|
| AnalyticsHotSpotProfileTests.testPrimitiveTimings | LOOPR_REAL_DB |
| CanonicalDailyAnalyticsBenchmarkTests.testRealDatabaseReadTimings | LOOPR_REAL_HISTORY_DB |
| CoachProductionDatabaseTests.testExportedDeviceDatabaseLoadsTodayAndCoach | LOOPR_COACH_DEVICE_SNAPSHOT, an Application Support folder |
| MetricHistoryTests.testRealDatabaseCopyProducesSeries | LOOPR_REAL_DB |
| RealDatabaseMetricAuditTests.testRealDatabaseDayProducesSaneMetrics | LOOPR_REAL_DB |
| RealDatabaseMetricAuditTests.testMissingBodyMeasurementsYieldTheDesignedEmptyState | LOOPR_REAL_DB |
| RealNightSleepAuditTests.testEveryRealNightHasPlausibleStagesAndMetrics | LOOPR_REAL_NIGHT_DB |
| SleepNightDetailsTests.testTheRealNightCarriesTimesStagesAndAHeartLine | LOOPR_REAL_NIGHT_DB |

Set `LOOPR_REAL_DB_ZONE` to the capture's time zone where the audit accepts it. Use disposable copies and keep the captures and resulting health-value attachments out of version control. The source comments describe the expected recording dates and values.

A green normal fast lane does not verify these eight private capture audits. Report them separately as external checks until matching captures are available. Synthetic tests in the same files remain part of the normal lane, including the coach schema, metric history, sleep details and suggested alarm tests.
