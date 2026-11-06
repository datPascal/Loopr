import DataKit
import Foundation

/// The "How this is worked out" row on a metric's detail page (LV-08b integration). It opens the method page the
/// method catalog maps the metric to, so a person reaches the formula, the code and the limits from the number.
enum MetricDetailMethodLink {
    static let title = "How this is worked out"
    static let hint = "Opens the formula, the code and the limits."
    static let identifier = "metric-detail-method-link"

    /// The method page for a metric. Every `MetricKey` has one (`MethodRouteTests` holds that), so the row shows on
    /// every metric page.
    static func methodID(for key: MetricKey) -> MethodID? {
        MethodMetricText.methodID(for: key)
    }
}
