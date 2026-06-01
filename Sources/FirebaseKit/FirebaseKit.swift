//  FirebaseKit.swift
//  firebase-shell
//
//  Created by Natan Rolnik on 01-06-2026.

// Re-export the Firebase modules the app consumes. Depending on `FirebaseKit`
// and writing `import FirebaseKit` gives callers the full surface while linking
// a single dynamic framework that carries the statically-linked, vendor-signed
// Firebase xcframeworks. The remaining binary targets (FirebaseCoreInternal,
// FirebaseSessions, GoogleAppMeasurement, GoogleUtilities, nanopb, the Promises
// pair, etc.) are link-time-only dependencies and need no re-export.
@_exported import FirebaseCore
@_exported import FirebaseAnalytics
@_exported import FirebaseCrashlytics
@_exported import FirebaseMessaging
