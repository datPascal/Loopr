/// DomainKit owns the read seams used by feature packages.  The associated
/// value keeps DomainKit independent of AnalyticsKit while still giving each
/// feature one canonical, typed repository method.
public protocol CanonicalAgeResultRepository: Sendable {
    associatedtype Value: Sendable
    func readLatestAgeResult() async throws -> Value?
}

public protocol CanonicalBatteryForecastRepository: Sendable {
    associatedtype Value: Sendable
    func readLatestBatteryForecast() async throws -> Value?
}

/// The single DomainKit read seam for ANA-02 persisted derivations.  DomainKit
/// intentionally owns no AnalyticsKit types: each feature supplies its typed
/// value through an associated type, while callers still have one canonical
/// repository protocol and one read method per persisted output family.
public protocol CanonicalAnalyticsRepository: Sendable {
    associatedtype RRQualityValue: Sendable
    associatedtype HRVValue: Sendable
    associatedtype NocturnalRHRValue: Sendable
    associatedtype RespirationValue: Sendable

    func readLatestRRQuality() async throws -> RRQualityValue?
    func readLatestHRV() async throws -> HRVValue?
    func readLatestNocturnalRHR() async throws -> NocturnalRHRValue?
    func readLatestRespiration() async throws -> RespirationValue?
}

/// The one canonical read seam for ANA-03's shared sleep derivation.  The
/// associated value is intentionally a feature-owned composite containing the
/// segmentation, staging, accounting, and hypnogram outputs from the same
/// source session.  Keeping this as one read method prevents consumers from
/// reconstructing a second, independently segmented sleep path.
public protocol CanonicalSleepAnalyticsRepository: Sendable {
    associatedtype Value: Sendable
    func readLatestSleepDerivation() async throws -> Value?
}
