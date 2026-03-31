//
//  ContentView.swift
//  CrowdFuel
//
//  Created by bob on 10/3/25.
//

import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject var firebaseService: FirebaseService
    @State private var isInitializing = true
    
    var body: some View {
        Group {
            // Use && / ! instead of || so Swift doesn’t mis-infer @State vs @EnvironmentObject (Binding vs Bool).
            if !isInitializing && !firebaseService.isLoadingBand {
                if firebaseService.isAuthenticated {
                    if firebaseService.currentBand != nil {
                        MainTabView()
                    } else {
                        BandSetupView()
                    }
                } else {
                    AuthenticationView()
                }
            } else {
                // Loading screen during initial authentication check or band loading
                LoadingView()
            }
        }
        .animation(.easeInOut, value: firebaseService.isAuthenticated)
        .onAppear {
            // Give Firebase time to check authentication state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isInitializing = false
            }
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            // App icon or logo
            Image("cficon")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            Text("CrowdFuel")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Loading...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    ContentView()
        .environmentObject(FirebaseService.shared)
}
