import XCTest
@testable import CameraApp

/// Pure-logic coverage for the framework-free permission status mapping.
/// No hardware / OS authorization APIs are touched in CI.
final class PermissionMappingTests: XCTestCase {

    func testAuthorizedMapsToGranted() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(
                mapPermissionStatus(.authorized, for: permission),
                .granted,
                "authorized should grant \(permission)"
            )
        }
    }

    func testLimitedMapsToGranted() {
        // `.limited` (photo-library add) is treated as usable in v1.
        for permission in AppPermission.allCases {
            XCTAssertEqual(
                mapPermissionStatus(.limited, for: permission),
                .granted,
                "limited should grant \(permission)"
            )
        }
    }

    func testNotDeterminedMapsToNotDetermined() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(
                mapPermissionStatus(.notDetermined, for: permission),
                .notDetermined,
                "notDetermined should stay notDetermined for \(permission)"
            )
        }
    }

    func testDeniedMapsToDenied() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(mapPermissionStatus(.denied, for: permission), .denied)
        }
    }

    func testRestrictedMapsToDenied() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(mapPermissionStatus(.restricted, for: permission), .denied)
        }
    }

    func testUnknownMapsToDeniedNeverCrashes() {
        for permission in AppPermission.allCases {
            XCTAssertEqual(mapPermissionStatus(.unknown, for: permission), .denied)
        }
    }

    func testEveryRawStatusMapsToAKnownPermissionStatus() {
        let valid: [PermissionStatus] = [.notDetermined, .granted, .denied]
        for raw in PermissionRawStatus.allCases {
            for permission in AppPermission.allCases {
                let mapped = mapPermissionStatus(raw, for: permission)
                XCTAssertTrue(
                    valid.contains(mapped),
                    "raw \(raw) for \(permission) mapped to unexpected \(mapped)"
                )
            }
        }
    }

    func testRawStatusCaseCoverage() {
        XCTAssertEqual(PermissionRawStatus.allCases.count, 6)
    }
}
