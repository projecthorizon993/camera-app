import Foundation

// Pure-Foundation permission models.

/// Runtime permissions the app may need.
enum AppPermission: String, Sendable, CaseIterable { case camera, microphone, photoLibraryAdd, location }

/// Simplified three-state permission status (collapsed from system states).
enum PermissionStatus: String, Sendable { case notDetermined, granted, denied }
