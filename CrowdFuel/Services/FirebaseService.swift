//
//  FirebaseService.swift
//  CrowdFuel
//
//  Created by bob on 10/3/25.
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseAnalytics
import AuthenticationServices
import CryptoKit

@MainActor
class FirebaseService: NSObject, ObservableObject {
    static let shared = FirebaseService()
    
    @Published var currentUser: User?
    @Published var currentBand: Band?
    @Published var isAuthenticated = false
    @Published var isLoadingBand = false
    @Published var currentNonce: String?
    
    let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let backendURL = "https://crowdfuel-backend.onrender.com"
    
    override init() {
        super.init()
        setupAuthStateListener()
        debugConfiguration()
    }
    
    private func debugConfiguration() {
        print("=== CrowdFuel Debug Configuration ===")
        print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        print("App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "Unknown")")
        print("Build Number: \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "Unknown")")
        
        if #available(iOS 13.0, *) {
            print("Sign In with Apple is available on this device")
        } else {
            print("Sign In with Apple requires iOS 13.0+")
        }
        print("=====================================")
    }
    
    private func setupAuthStateListener() {
        _ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.currentUser = user
                self?.isAuthenticated = user != nil
                if let user = user {
                    self?.isLoadingBand = true
                    Task {
                        await self?.loadCurrentBand(uid: user.uid)
                        await MainActor.run {
                            self?.isLoadingBand = false
                        }
                    }
                } else {
                    self?.currentBand = nil
                    self?.isLoadingBand = false
                }
            }
        }
    }
    
    /// Legacy Apple sign-in entry point that relies on `currentNonce`.
    /// Kept for compatibility with any older flows that might still call it.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {
        guard let nonce = currentNonce else {
            print("Error: Current nonce is nil")
            throw AuthError.invalidNonce
        }
        try await signInWithApple(credential: credential, rawNonce: nonce)
    }
    
    /// Preferred Apple sign-in entry point where the caller provides the raw nonce.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential, rawNonce nonce: String) async throws {
        guard let appleIDToken = credential.identityToken else {
            print("Error: Unable to fetch identity token")
            throw AuthError.invalidToken
        }
        
        guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            print("Error: Unable to serialize token string from data")
            throw AuthError.invalidToken
        }
        
        print("Successfully received Apple ID token")
        print("Nonce for verification: \(nonce)")
        
        // Create Firebase credential
        let firebaseCredential = OAuthProvider.credential(
            providerID: AuthProviderID.apple,
            idToken: idTokenString,
            rawNonce: nonce
        )
        
        // Sign in with Firebase
        do {
            let result = try await Auth.auth().signIn(with: firebaseCredential)
            print("Successfully signed in with Apple: \(result.user.uid)")
            
            // Update display name if this is a new user and we have the name
            if let fullName = credential.fullName,
               let givenName = fullName.givenName,
               let familyName = fullName.familyName {
                let displayName = "\(givenName) \(familyName)"
                let changeRequest = result.user.createProfileChangeRequest()
                changeRequest.displayName = displayName
                try await changeRequest.commitChanges()
                print("Updated user display name to: \(displayName)")
            }
            
            // Clear the nonce after successful authentication
            await MainActor.run {
                self.currentNonce = nil
            }
        } catch {
            print("Firebase sign-in error: \(error)")
            throw error
        }
    }
    
    func startSignInWithAppleFlow() {
        print("Starting Apple Sign-In flow...")
        
        // Check if Apple Sign-In is available
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        // Note: Availability check removed as it's not available in current API
        
        let nonce = randomNonceString()
        currentNonce = nonce
        print("Generated nonce: \(nonce)")
        
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        
        // Only set nonce if available in iOS 13+
        if #available(iOS 13.0, *) {
            let hashedNonce = sha256(nonce)
            request.nonce = hashedNonce
            print("Hashed nonce: \(hashedNonce)")
        }
        
        print("Creating authorization controller...")
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        authorizationController.delegate = self
        authorizationController.presentationContextProvider = self
        
        print("Performing authorization request...")
        authorizationController.performRequests()
    }
    
    func signOut() async throws {
        try Auth.auth().signOut()
    }
    
    /// Permanently delete the current user's CrowdFuel account and all associated data.
    /// This removes the band document, its songs, all gigs for the band (and their requests),
    /// then deletes the Firebase Auth user.
    func deleteAccountAndData() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.noCurrentUser
        }
        
        let uid = user.uid
        
        // Ensure we have the latest band for this user
        if currentBand == nil {
            await loadCurrentBand(uid: uid)
        }
        
        if let band = currentBand, let bandId = band.id {
            // Best-effort Firestore cleanup; ignore permission errors so account deletion can still proceed
            do {
                // Delete all gigs for this band and their requests
                let gigsSnapshot = try await db.collection("gigs")
                    .whereField("bandId", isEqualTo: bandId)
                    .getDocuments()
                
                for gigDoc in gigsSnapshot.documents {
                    // Delete all requests under this gig (may be restricted by rules)
                    do {
                        let requestsSnapshot = try await gigDoc.reference
                            .collection("requests")
                            .getDocuments()
                        
                        for requestDoc in requestsSnapshot.documents {
                            try await requestDoc.reference.delete()
                        }
                    } catch {
                        print("⚠️ Error deleting requests for gig \(gigDoc.documentID): \(error)")
                    }
                    
                    // Delete the gig document itself
                    do {
                        try await gigDoc.reference.delete()
                    } catch {
                        print("⚠️ Error deleting gig \(gigDoc.documentID): \(error)")
                    }
                }
                
                // Delete all songs for this band
                do {
                    let songsSnapshot = try await db.collection("bands")
                        .document(bandId)
                        .collection("songs")
                        .getDocuments()
                    
                    for songDoc in songsSnapshot.documents {
                        try await songDoc.reference.delete()
                    }
                } catch {
                    print("⚠️ Error deleting songs for band \(bandId): \(error)")
                }
                
                // Delete the band document
                do {
                    try await db.collection("bands").document(bandId).delete()
                } catch {
                    print("⚠️ Error deleting band document \(bandId): \(error)")
                }
            } catch {
                print("⚠️ Error during Firestore cleanup for account deletion: \(error)")
            }
        }
        
        // Finally, delete the Firebase Auth user
        do {
            try await user.delete()
        } catch {
            // Propagate error so UI can show a friendly message (e.g. requires recent login)
            throw error
        }
        
        // Local cleanup; auth state listener will also clear these
        currentUser = nil
        currentBand = nil
        isAuthenticated = false
    }
    
    // MARK: - Email/Password Authentication
    
    func signUpWithEmail(email: String, password: String, displayName: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        
        // Update display name
        let changeRequest = result.user.createProfileChangeRequest()
        changeRequest.displayName = displayName
        try await changeRequest.commitChanges()
        
        print("Successfully created user with email: \(email)")
    }
    
    func signInWithEmail(email: String, password: String) async throws {
        _ = try await Auth.auth().signIn(withEmail: email, password: password)
        print("Successfully signed in with email: \(email)")
    }
    
    func resetPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
        print("Password reset email sent to: \(email)")
    }
    
    func linkEmailPassword(email: String, password: String) async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.noCurrentUser
        }
        
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        
        do {
            _ = try await user.link(with: credential)
            print("✅ Linked email/password to user: \(user.uid)")
        } catch {
            if let authError = error as NSError? {
                switch AuthErrorCode(rawValue: authError.code) {
                case .credentialAlreadyInUse, .emailAlreadyInUse, .providerAlreadyLinked:
                    throw AuthError.emailAlreadyInUse
                default:
                    break
                }
            }
            throw error
        }
    }
    
    // MARK: - Band Management
    
    func updateBandSlug() async throws {
        guard let band = currentBand, let bandId = band.id else {
            throw AuthError.noCurrentUser
        }
        
        // Generate slug from band name
        let slug = Band.generateSlug(from: band.name)
        
        // Update in Firestore
        try await db.collection("bands").document(bandId).updateData([
            "slug": slug
        ])
        
        print("✅ Updated band slug to: \(slug)")
        
        // Reload band to get updated data
        if let uid = currentUser?.uid {
            await loadCurrentBand(uid: uid)
        }
    }
    
    // MARK: - Stripe Account Validation
    
    func canAcceptPayments() -> (canAccept: Bool, message: String?) {
        guard let band = currentBand else {
            return (false, "No band found")
        }
        
        guard let stripeAccountId = band.stripeAccountId, !stripeAccountId.isEmpty else {
            return (false, "Please set up your bank account before going live. Tap 'Payouts' to connect your account.")
        }
        
        // Optional: Could add more checks here for account status if needed
        // For now, just checking if stripeAccountId exists
        
        return (true, nil)
    }
    
    func loadCurrentBand(uid: String) async {
        do {
            let query = db.collection("bands").whereField("ownerUid", isEqualTo: uid).limit(to: 1)
            let snapshot = try await query.getDocuments()
            
            if let document = snapshot.documents.first {
                self.currentBand = try document.data(as: Band.self)
            }
        } catch {
            print("Error loading current band: \(error)")
        }
    }
    
    func createBand(_ band: Band) async throws -> String {
        let slug = band.slug ?? Band.generateSlug(from: band.name)
        guard !slug.isEmpty else {
            throw AuthError.bandNameInvalid
        }
        
        let trimmedName = band.name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Slug must be unique: fan site and promos resolve bands by slug; duplicates break live gig lookup.
        let slugMatch = try await db.collection("bands")
            .whereField("slug", isEqualTo: slug)
            .limit(to: 1)
            .getDocuments()
        if !slugMatch.documents.isEmpty {
            throw AuthError.bandNameAlreadyTaken
        }
        
        // Exact display name must be unique: some flows look up bands by name.
        let nameMatch = try await db.collection("bands")
            .whereField("name", isEqualTo: trimmedName)
            .limit(to: 1)
            .getDocuments()
        if !nameMatch.documents.isEmpty {
            throw AuthError.bandNameAlreadyTaken
        }
        
        let docRef = try db.collection("bands").addDocument(from: band)
        return docRef.documentID
    }
    
    func createGig(_ gig: Gig) async throws -> String {
        let docRef = try db.collection("gigs").addDocument(from: gig)
        return docRef.documentID
    }
    
    func listenToGigRequests(gigId: String, completion: @escaping ([RequestItem]) -> Void) {
        print("Setting up listener for gig \(gigId) requests...")
        db.collection("gigs").document(gigId).collection("requests")
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("Error listening to requests: \(error)")
                    return
                }
                
                guard let documents = snapshot?.documents else {
                    print("No documents in snapshot")
                    completion([])
                    return
                }
                
                print("Firestore listener received \(documents.count) documents")
                
                let requests = documents.compactMap { doc -> RequestItem? in
                    do {
                        let request = try doc.data(as: RequestItem.self)
                        print("Successfully parsed request: \(request.fanName ?? "Unknown")")
                        return request
                    } catch {
                        print("Failed to parse request \(doc.documentID): \(error)")
                        return nil
                    }
                }
                
                // Sort to match fan-facing queue: highest tip first, then earliest request
                let sortedRequests = requests.sorted { lhs, rhs in
                    if lhs.tipCents != rhs.tipCents {
                        return lhs.tipCents > rhs.tipCents
                    }
                    return lhs.createdAt < rhs.createdAt
                }
                
                print("Sending \(sortedRequests.count) parsed requests to completion")
                completion(sortedRequests)
            }
    }
    
    func updateRequestStatus(requestId: String, gigId: String, status: RequestItem.RequestStatus) async throws {
        if status == .refunded {
            // First attempt to issue Stripe refund via HTTPS function
            do {
                try await refundRequest(gigId: gigId, requestId: requestId)
            } catch {
                // Log but still mark as refunded to avoid blocking UI
                print("⚠️ Refund endpoint call failed: \(error.localizedDescription)")
            }
        }

        try await db.collection("gigs").document(gigId)
            .collection("requests").document(requestId)
            .updateData(["status": status.rawValue])
    }

    // MARK: - Refund via HTTPS Cloud Function
    private func refundRequest(gigId: String, requestId: String) async throws {
        guard let url = URL(string: "https://us-central1-crowdfuel-86c2b.cloudfunctions.net/refundPaymentHttp") else {
            throw URLError(.badURL)
        }

        let requestPath = "gigs/\(gigId)/requests/\(requestId)"
        let payload: [String: Any] = ["requestPath": requestPath]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
    }
    
    func updateGigStatus(gigId: String, status: Gig.GigStatus) async throws {
        try await db.collection("gigs").document(gigId)
            .updateData(["status": status.rawValue])
    }
    
    // MARK: - Apple Sign-In Helper Methods
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(nonce)
    }
    
    @available(iOS 13, *)
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            return String(format: "%02x", $0)
        }.joined()
        
        return hashString
    }
}

// MARK: - AuthError Enum

enum AuthError: LocalizedError {
    case invalidNonce
    case invalidToken
    case noCurrentUser
    case needFirebaseSetup
    case emailAlreadyInUse
    case bandNameAlreadyTaken
    case bandNameInvalid
    
    var errorDescription: String? {
        switch self {
        case .invalidNonce:
            return "Invalid nonce for Apple Sign-In"
        case .invalidToken:
            return "Invalid token from Apple Sign-In"
        case .noCurrentUser:
            return "No current user found. Please sign in again."
        case .needFirebaseSetup:
            return "Firebase SDK needs to be properly configured for Apple Sign-In"
        case .emailAlreadyInUse:
            return "That email is already linked to another CrowdFuel account."
        case .bandNameAlreadyTaken:
            return "That band name is already taken. Choose a different name."
        case .bandNameInvalid:
            return "Please choose a band name that includes letters or numbers."
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension FirebaseService: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        print("Apple Sign-In authorization completed successfully")
        
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            print("Received Apple ID credential")
            print("User ID: \(appleIDCredential.user)")
            
            Task { @MainActor in
                do {
                    print("Current nonce before sign-in: \(self.currentNonce ?? "nil")")
                    try await signInWithApple(credential: appleIDCredential)
                } catch {
                    print("Apple Sign-In failed: \(error.localizedDescription)")
                }
            }
        } else {
            print("Unexpected credential type: \(type(of: authorization.credential))")
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("Apple Sign-In error: \(error)")
        
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                print("User canceled Apple Sign-In")
            case .failed:
                print("Apple Sign-In failed")
            case .invalidResponse:
                print("Invalid response from Apple Sign-In")
            case .notHandled:
                print("Apple Sign-In not handled")
            case .unknown:
                print("Unknown Apple Sign-In error - check configuration")
            case .notInteractive:
                print("Apple Sign-In not interactive")
            case .matchedExcludedCredential:
                print("Matched excluded credential")
            case .credentialImport:
                print("Credential import error")
            case .credentialExport:
                print("Credential export error")
            case .preferSignInWithApple:
                print("Prefer Sign In with Apple")
            case .deviceNotConfiguredForPasskeyCreation:
                print("Device not configured for passkey creation")
            @unknown default:
                print("Unknown Apple Sign-In error code: \(authError.code.rawValue)")
            }
        } else {
            print("Non-ASAuthorizationError: \(error)")
        }
    }
    
    // MARK: - Backend API
    
    func callFunction(name: String, data: [String: Any]) async throws -> [String: Any] {
        // Map function names to backend endpoints
        let endpoint: String
        switch name {
        case "createConnectAccount":
            endpoint = "create-connect-account"
        case "getConnectAccountStatus":
            endpoint = "connect-account-status"
        case "createPaymentIntent":
            endpoint = "create-payment-intent"
        case "getPayoutDashboardLink":
            endpoint = "payout-dashboard-link"
        default:
            endpoint = name
        }
        
        let url = URL(string: "\(backendURL)/\(endpoint)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: data)
        request.timeoutInterval = 30
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "FirebaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "FirebaseService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Backend error: \(errorMessage)"])
        }
        
        guard let resultData = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "FirebaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from backend"])
        }
        
        return resultData
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension FirebaseService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            fatalError("No window available")
        }
        return window
    }
}
