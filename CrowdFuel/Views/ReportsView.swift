//
//  ReportsView.swift
//  CrowdFuel
//
//  Created by bob on 10/3/25.
//

import SwiftUI
import FirebaseFirestore

struct ReportsView: View {
    @EnvironmentObject var firebaseService: FirebaseService
    @State private var reports: [GigReport] = []
    @State private var selectedTimeRange: TimeRange = .thisMonth
    @State private var isLoading = false
    @State private var csvURL: URL?
    @State private var showingShareSheet = false
    @State private var isPreparingCSV = false
    @State private var showingNoDataAlert = false
    @State private var showingTopRequests = false
    @State private var showingNoContactsAlert = false
    
    var body: some View {
        NavigationView {
            VStack {
                // Time Range Picker
                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                
                if isLoading {
                    Spacer()
                    ProgressView("Loading reports...")
                    Spacer()
                } else if reports.isEmpty {
                    EmptyStateView(
                        icon: "chart.bar.fill",
                        title: "No reports yet",
                        subtitle: "Complete some gigs to see your analytics"
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Summary Cards
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 16) {
                                SummaryCard(
                                    title: "Total Earnings",
                                    value: totalEarnings,
                                    icon: "dollarsign.circle.fill",
                                    color: .green
                                )
                                
                                SummaryCard(
                                    title: "Total Requests",
                                    value: "\(totalRequests)",
                                    icon: "music.note.list",
                                    color: .blue
                                )
                                
                                SummaryCard(
                                    title: "Avg Per Show",
                                    value: averagePerShow,
                                    icon: "chart.line.uptrend.xyaxis",
                                    color: .orange
                                )
                                
                                Button(action: {
                                    showingTopRequests = true
                                }) {
                                    SummaryCard(
                                        title: "Top Song",
                                        value: topSong ?? "N/A",
                                        icon: "star.fill",
                                        color: .purple
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(topSong == nil)
                                
                                Button(action: {
                                    exportContactsCSV()
                                }) {
                                    SummaryCard(
                                        title: "Export Contacts",
                                        value: "CSV",
                                        icon: "person.crop.circle.badge.arrow.down",
                                        color: .teal
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal)
                            
                            // Detailed Reports
                            VStack(spacing: 16) {
                                Text("Gig Reports")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                
                                ForEach(reports) { report in
                                    GigReportCard(report: report)
                                        .padding(.horizontal)
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Export CSV") {
                        exportCSV()
                    }
                    .disabled(reports.isEmpty)
                }
            }
            .onChange(of: selectedTimeRange) {
                Task {
                    await loadReports()
                }
            }
            .task {
                await loadReports()
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheetView(csvURL: $csvURL)
            }
            .alert("No Data to Export", isPresented: $showingNoDataAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Complete some gigs first to generate reports. Go to a gig and tap 'Mark as Complete' to create report data.")
            }
            .alert("No Contacts Found", isPresented: $showingNoContactsAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("No requests in this time range include an email address or phone number.")
            }
            .sheet(isPresented: $showingTopRequests) {
                TopRequestsView()
                    .environmentObject(firebaseService)
            }
        }
    }
    
    private var totalEarnings: String {
        let total = reports.reduce(0) { $0 + $1.totalEarningsCents }
        return formatCurrency(total)
    }
    
    private var totalRequests: Int {
        reports.reduce(0) { $0 + $1.totalRequests }
    }
    
    private var averagePerShow: String {
        guard !reports.isEmpty else { return "$0.00" }
        let total = reports.reduce(0) { $0 + $1.totalEarningsCents }
        let average = total / reports.count
        return formatCurrency(average)
    }
    
    private var topSong: String? {
        let songCounts = reports.flatMap { $0.songStats }
            .filter { $0.songTitle != "Tip Only" } // Exclude tip-only requests from top song calculation
            .reduce(into: [String: Int]()) { counts, stat in
                counts[stat.songTitle, default: 0] += stat.requestCount
            }
        return songCounts.max(by: { $0.value < $1.value })?.key
    }
    
    private func formatCurrency(_ cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }
    
    private func loadReports() async {
        isLoading = true
        print("Loading reports from Firestore...")
        
        guard let bandId = firebaseService.currentBand?.id else {
            await MainActor.run {
                reports = []
                isLoading = false
            }
            return
        }
        
        do {
            let db = firebaseService.db
            
            // Calculate date range
            let dateRange = getDateRange(for: selectedTimeRange)
            
            // Load completed gigs
            let gigsSnapshot = try await db.collection("gigs")
                .whereField("bandId", isEqualTo: bandId)
                .whereField("status", isEqualTo: Gig.GigStatus.done.rawValue)
                .getDocuments()
            
            var loadedReports: [GigReport] = []
            
            for gigDoc in gigsSnapshot.documents {
                guard let gig = try? gigDoc.data(as: Gig.self) else { continue }
                
                // Filter by date range
                if let startDate = dateRange.start, gig.startAt < startDate { continue }
                if let endDate = dateRange.end, gig.startAt > endDate { continue }
                
                // Load requests for this gig
                let requestsSnapshot = try await db.collection("gigs")
                    .document(gigDoc.documentID)
                    .collection("requests")
                    .getDocuments()
                
                var totalEarningsCents = 0
                var songStatsDict: [String: (count: Int, totalCents: Int)] = [:]
                var nonRefundedRequestCount = 0
                var requestDetails: [RequestDetail] = []
                
                for requestDoc in requestsSnapshot.documents {
                    guard let request = try? requestDoc.data(as: RequestItem.self) else { continue }
                    
                    // Store all request details (including refunded ones)
                    let detail = RequestDetail(
                        id: requestDoc.documentID,
                        songTitle: request.songTitle ?? "Unknown Song",
                        fanName: request.fanName,
                        fanEmail: request.fanEmail,
                        fanPhone: request.fanPhone,
                        note: request.note,
                        tipCents: request.tipCents,
                        status: request.status
                    )
                    requestDetails.append(detail)
                    
                    // Exclude refunded requests from earnings and stats calculations
                    if request.status == .refunded {
                        continue
                    }
                    
                    totalEarningsCents += request.tipCents
                    nonRefundedRequestCount += 1
                    
                    let songTitle = request.songTitle ?? "Unknown Song"
                    let current = songStatsDict[songTitle] ?? (count: 0, totalCents: 0)
                    songStatsDict[songTitle] = (count: current.count + 1, totalCents: current.totalCents + request.tipCents)
                }
                
                // Sort request details: non-refunded first, then refunded, both by tip amount descending
                requestDetails.sort { lhs, rhs in
                    if lhs.isRefunded != rhs.isRefunded {
                        return !lhs.isRefunded // Non-refunded first
                    }
                    return lhs.tipCents > rhs.tipCents
                }
                
                let songStats = songStatsDict.map { title, stats in
                    SongStat(songTitle: title, requestCount: stats.count, totalTipsCents: stats.totalCents)
                }.sorted { $0.totalTipsCents > $1.totalTipsCents }
                
                let report = GigReport(
                    gigId: gigDoc.documentID,
                    gigTitle: gig.title,
                    venueName: gig.venueName,
                    date: gig.startAt,
                    totalEarningsCents: totalEarningsCents,
                    totalRequests: nonRefundedRequestCount,
                    songStats: songStats,
                    requestDetails: requestDetails
                )
                
                loadedReports.append(report)
            }
            
            // Sort by date, most recent first
            loadedReports.sort { $0.date > $1.date }
            
            await MainActor.run {
                self.reports = loadedReports
                self.isLoading = false
            }
            
        } catch {
            await MainActor.run {
                reports = []
                isLoading = false
            }
        }
    }
    
    private func getDateRange(for timeRange: TimeRange) -> (start: Date?, end: Date?) {
        let calendar = Calendar.current
        let now = Date()
        
        switch timeRange {
        case .thisWeek:
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
            return (start: startOfWeek, end: nil)
            
        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            return (start: startOfMonth, end: nil)
            
        case .lastMonth:
            let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)
            return (start: startOfLastMonth, end: startOfThisMonth)
            
        case .last3Months:
            let startOf3MonthsAgo = calendar.date(byAdding: .month, value: -3, to: now)
            return (start: startOf3MonthsAgo, end: nil)
            
        case .allTime:
            return (start: nil, end: nil)
        }
    }
    
    private func exportCSV() {
        guard !reports.isEmpty else {
            showingNoDataAlert = true
            return
        }
        
        // Set preparing state - don't show sheet yet
        isPreparingCSV = true
        csvURL = nil
        showingShareSheet = false
        
        // Generate CSV content with detailed request information
        var csvText = "Gig Title,Venue,Date,Total Earnings,Total Requests,Avg Tip,Top Song\n"
        
        // First, add summary rows for each gig
        for report in reports {
            let title = report.gigTitle.replacingOccurrences(of: ",", with: ";")
            let venue = report.venueName.replacingOccurrences(of: ",", with: ";")
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            let date = dateFormatter.string(from: report.date)
            let earnings = report.totalEarnings
            let requests = "\(report.totalRequests)"
            let avgTip = report.averageTip
            
            // Get top song from songStats (exclude "Tip Only")
            let topSongTitle = report.songStats
                .filter { $0.songTitle != "Tip Only" } // Exclude tip-only requests from top song calculation
                .max(by: { $0.requestCount < $1.requestCount })?.songTitle ?? "N/A"
            let topSong = topSongTitle.replacingOccurrences(of: ",", with: ";")
            
            csvText += "\(title),\(venue),\(date),\(earnings),\(requests),\(avgTip),\(topSong)\n"
        }
        
        // Add separator and detailed request information
        csvText += "\n\n=== DETAILED REQUEST INFORMATION ===\n\n"
        csvText += "Gig Title,Venue,Date,Song Title,Fan Name,Email,Phone,Comment/Note,Tip Amount,Status\n"
        
        for report in reports {
            let title = report.gigTitle.replacingOccurrences(of: ",", with: ";")
            let venue = report.venueName.replacingOccurrences(of: ",", with: ";")
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            let date = dateFormatter.string(from: report.date)
            
            // Add all request details for this gig
            for detail in report.requestDetails {
                let songTitle = detail.songTitle.replacingOccurrences(of: ",", with: ";")
                let fanName = (detail.fanName ?? "").replacingOccurrences(of: ",", with: ";")
                let fanEmail = (detail.fanEmail ?? "").replacingOccurrences(of: ",", with: ";")
                let fanPhone = (detail.fanPhone ?? "").replacingOccurrences(of: ",", with: ";")
                let note = (detail.note ?? "").replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
                let tipAmount = detail.tipAmount
                let status = detail.isRefunded ? "Refunded" : "Completed"
                
                csvText += "\(title),\(venue),\(date),\(songTitle),\(fanName),\(fanEmail),\(fanPhone),\(note),\(tipAmount),\(status)\n"
            }
        }
        
        // Create temporary file
        let fileName = "CrowdFuel_Reports_\(selectedTimeRange.displayName.replacingOccurrences(of: " ", with: "_")).csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try csvText.write(to: path, atomically: true, encoding: .utf8)
            
            // Ensure file exists and is readable
            guard FileManager.default.fileExists(atPath: path.path) else {
                isPreparingCSV = false
                return
            }
            
            // Update state on main thread
            Task { @MainActor in
                guard FileManager.default.fileExists(atPath: path.path) else {
                    self.isPreparingCSV = false
                    return
                }
                
                self.csvURL = path
                self.isPreparingCSV = false
                
                // Wait for SwiftUI to process the state change
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                guard let currentURL = self.csvURL,
                      currentURL == path,
                      FileManager.default.fileExists(atPath: path.path) else {
                    return
                }
                
                self.showingShareSheet = true
            }
        } catch {
            isPreparingCSV = false
        }
    }
    
    private func exportContactsCSV() {
        guard !reports.isEmpty else {
            showingNoDataAlert = true
            return
        }
        
        // Set preparing state - don't show sheet yet
        isPreparingCSV = true
        csvURL = nil
        showingShareSheet = false
        
        // Build deduped contact list across all loaded request details.
        // Dedupe key is normalized email + normalized phone; if one is missing, the other still contributes.
        struct ContactRow: Hashable {
            let name: String
            let email: String
            let phone: String
            let venue: String
        }
        
        func normalizeEmail(_ email: String) -> String {
            email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        
        func normalizePhone(_ phone: String) -> String {
            let digits = phone.filter { $0.isNumber }
            return digits
        }
        
        func csvSafe(_ value: String) -> String {
            // Keep consistent with the existing report CSV approach.
            value
                .replacingOccurrences(of: ",", with: ";")
                .replacingOccurrences(of: "\n", with: " ")
        }
        
        var seenKeys = Set<String>()
        var contacts: [ContactRow] = []
        
        for report in reports {
            let venue = report.venueName
            
            for detail in report.requestDetails {
                let rawEmail = (detail.fanEmail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawPhone = (detail.fanPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                
                let emailNorm = normalizeEmail(rawEmail)
                let phoneNorm = normalizePhone(rawPhone)
                
                // Require at least one contact method.
                if emailNorm.isEmpty && phoneNorm.isEmpty {
                    continue
                }
                
                let dedupeKey = "\(emailNorm)|\(phoneNorm)"
                if seenKeys.contains(dedupeKey) {
                    continue
                }
                seenKeys.insert(dedupeKey)
                
                let name = (detail.fanName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                contacts.append(ContactRow(
                    name: name,
                    email: rawEmail,
                    phone: rawPhone,
                    venue: venue
                ))
            }
        }
        
        guard !contacts.isEmpty else {
            isPreparingCSV = false
            showingNoContactsAlert = true
            return
        }
        
        // Optional: stable ordering for nicer exports
        contacts.sort { lhs, rhs in
            let l = lhs.email.lowercased() + "|" + lhs.phone
            let r = rhs.email.lowercased() + "|" + rhs.phone
            return l < r
        }
        
        var csvText = "Name,Email,Phone,Venue\n"
        for c in contacts {
            csvText += "\(csvSafe(c.name)),\(csvSafe(c.email)),\(csvSafe(c.phone)),\(csvSafe(c.venue))\n"
        }
        
        let fileName = "CrowdFuel_Contacts_\(selectedTimeRange.displayName.replacingOccurrences(of: " ", with: "_"))_Deduped.csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try csvText.write(to: path, atomically: true, encoding: .utf8)
            
            guard FileManager.default.fileExists(atPath: path.path) else {
                isPreparingCSV = false
                return
            }
            
            Task { @MainActor in
                guard FileManager.default.fileExists(atPath: path.path) else {
                    self.isPreparingCSV = false
                    return
                }
                
                self.csvURL = path
                self.isPreparingCSV = false
                
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                guard let currentURL = self.csvURL,
                      currentURL == path,
                      FileManager.default.fileExists(atPath: path.path) else {
                    return
                }
                
                self.showingShareSheet = true
            }
        } catch {
            isPreparingCSV = false
        }
    }
}


enum TimeRange: CaseIterable {
    case thisWeek
    case thisMonth
    case lastMonth
    case last3Months
    case allTime
    
    var displayName: String {
        switch self {
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .last3Months: return "Last 3 Months"
        case .allTime: return "All Time"
        }
    }
}

struct GigReport: Identifiable {
    let id: String
    let gigId: String
    let gigTitle: String
    let venueName: String
    let date: Date
    let totalEarningsCents: Int
    let totalRequests: Int
    let songStats: [SongStat]
    let requestDetails: [RequestDetail] // Individual request details
    
    init(gigId: String, gigTitle: String, venueName: String, date: Date, totalEarningsCents: Int, totalRequests: Int, songStats: [SongStat], requestDetails: [RequestDetail] = []) {
        self.id = gigId
        self.gigId = gigId
        self.gigTitle = gigTitle
        self.venueName = venueName
        self.date = date
        self.totalEarningsCents = totalEarningsCents
        self.totalRequests = totalRequests
        self.songStats = songStats
        self.requestDetails = requestDetails
    }
    
    var totalEarnings: String {
        let dollars = Double(totalEarningsCents) / 100.0
        return String(format: "$%.2f", dollars)
    }
    
    var averageTip: String {
        guard totalRequests > 0 else { return "$0.00" }
        let average = totalEarningsCents / totalRequests
        let dollars = Double(average) / 100.0
        return String(format: "$%.2f", dollars)
    }
}

struct SongStat: Identifiable {
    let id = UUID()
    let songTitle: String
    let requestCount: Int
    let totalTipsCents: Int
    
    var averageTip: String {
        guard requestCount > 0 else { return "$0.00" }
        let average = totalTipsCents / requestCount
        let dollars = Double(average) / 100.0
        return String(format: "$%.2f", dollars)
    }
    
    var totalTips: String {
        let dollars = Double(totalTipsCents) / 100.0
        return String(format: "$%.2f", dollars)
    }
}

struct RequestDetail: Identifiable {
    let id: String
    let songTitle: String
    let fanName: String?
    let fanEmail: String?
    let fanPhone: String?
    let note: String?
    let tipCents: Int
    let status: RequestItem.RequestStatus
    
    var tipAmount: String {
        let dollars = Double(tipCents) / 100.0
        return String(format: "$%.2f", dollars)
    }
    
    var isRefunded: Bool {
        status == .refunded
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct GigReportCard: View {
    let report: GigReport
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.gigTitle)
                        .font(.headline)
                    
                    Text(report.venueName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(report.date, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(report.totalEarnings)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                    
                    Text("\(report.totalRequests) requests")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(isExpanded ? "Less" : "Details") {
                        withAnimation {
                            isExpanded.toggle()
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
            
            // Expanded Details
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Song Breakdown Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Song Breakdown")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        ForEach(report.songStats) { stat in
                            HStack {
                                Text(stat.songTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Text("\(stat.requestCount) × \(stat.averageTip)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(stat.totalTips)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    
                    // Individual Requests Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Requests")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        // Non-refunded requests
                        ForEach(report.requestDetails.filter { !$0.isRefunded }) { detail in
                            RequestDetailRow(detail: detail)
                        }
                        
                        // Refunded requests section
                        let refundedRequests = report.requestDetails.filter { $0.isRefunded }
                        if !refundedRequests.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                            
                            Text("Refunded")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            
                            ForEach(refundedRequests) { detail in
                                RequestDetailRow(detail: detail, isRefunded: true)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

struct RequestDetailRow: View {
    let detail: RequestDetail
    let isRefunded: Bool
    
    init(detail: RequestDetail, isRefunded: Bool = false) {
        self.detail = detail
        self.isRefunded = isRefunded
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(detail.songTitle)
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        if isRefunded {
                            Text("(Refunded)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    
                    if let fanName = detail.fanName, !fanName.isEmpty {
                        Text("from \(fanName)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if let fanEmail = detail.fanEmail, !fanEmail.isEmpty {
                        Text(fanEmail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if let fanPhone = detail.fanPhone, !fanPhone.isEmpty {
                        Text(fanPhone)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if let note = detail.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Text(detail.tipAmount)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(isRefunded ? .red : .green)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ShareSheetView: View {
    @Binding var csvURL: URL?
    
    var body: some View {
        Group {
            if let csvURL = csvURL, FileManager.default.fileExists(atPath: csvURL.path) {
                ShareSheet(activityItems: [csvURL])
            } else {
                VStack(spacing: 16) {
                    Text("Preparing CSV file...")
                        .font(.headline)
                    ProgressView()
                }
                .padding()
            }
        }
    }
}

#Preview {
    ReportsView()
        .environmentObject(FirebaseService.shared)
}
