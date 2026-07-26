import SwiftUI

struct DebloatView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: DebloatManager
    var isEmbedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var expandedCategory: String?
    @State private var searchText: String = ""
    @State private var pendingTweak: DebloatTweak?
    @State private var pendingCategory: DebloatCategory?

    private let sipEnabled = SIPChecker.isSIPEnabled()

    var body: some View {
        VStack(spacing: 0) {
            if !isEmbedded {
                header
                Divider().opacity(0.3)
            } else {
                embeddedHeader
                Divider().opacity(0.3)
            }
            content
            Divider().opacity(0.3)
            footer
        }
        .frame(width: isEmbedded ? nil : 360, height: isEmbedded ? nil : 520)
        .background {
            if !isEmbedded {
                VisualEffectBlur()
            }
        }
        .overlay(alignment: .top) {
            if manager.showingToast {
                Text(manager.toastMessage)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 50)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.showingToast)
        .alert("Apply this tuning change?", isPresented: Binding(
            get: { pendingTweak != nil },
            set: { if !$0 { pendingTweak = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingTweak = nil }
            Button("Apply", role: .destructive) {
                guard let tweak = pendingTweak else { return }
                pendingTweak = nil
                manager.toggle(tweak)
            }
        } message: {
            Text(pendingTweak.map {
                "\($0.name) is marked \($0.risk.rawValue). Its effect can be reverted from this screen."
            } ?? "Review this change before applying it.")
        }
        .alert("Apply all changes in this category?", isPresented: Binding(
            get: { pendingCategory != nil },
            set: { if !$0 { pendingCategory = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingCategory = nil }
            Button("Apply All", role: .destructive) {
                guard let category = pendingCategory else { return }
                pendingCategory = nil
                manager.applyAll(in: category)
            }
        } message: {
            Text(pendingCategory.map {
                "This applies every available change in \($0.name). Review each risk label first; all changes have a revert action."
            } ?? "Review these changes before applying them.")
        }
        .onChange(of: searchText) { newValue in
            // Auto-expand first matching category when searching
            if !newValue.isEmpty {
                if let first = filteredCategories.first {
                    expandedCategory = first.id
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: {
                    dismiss()
                }, label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                })
                .buttonStyle(.plain)

                Spacer()

                Text("System Tuning")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Button(action: {
                    manager.refreshAll()
                }, label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                })
                .buttonStyle(.plain)
                .help("Re-detect all tweak states")
            }

            // Stats bar
            HStack(spacing: 6) {
                let applied = manager.appliedCount
                let total = manager.totalCount

                HStack(spacing: 3) {
                    Text("\(applied)")
                        .foregroundStyle(applied > 0 ? .green : .secondary)
                        .fontWeight(.semibold)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text("\(total) applied")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))

                Spacer()

                Button("Restart UI") { manager.restartUI() }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Restart Finder, Dock & SystemUIServer to apply visual changes")
            }

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search tweaks\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    })
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
        .padding(12)
    }

    // MARK: - Embedded Header (for windowed mode)

    private var embeddedHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                let applied = manager.appliedCount
                let total = manager.totalCount

                HStack(spacing: 3) {
                    Text("\(applied)")
                        .foregroundStyle(applied > 0 ? .green : .secondary)
                        .fontWeight(.semibold)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text("\(total) applied")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))

                Button("Revert to Stock Settings") {
                    manager.revertAllTweaks()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .help("Revert all applied tweaks to macOS defaults")

                Spacer()

                Button { manager.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-detect all tweak states")

                Button("Restart UI") { manager.restartUI() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Restart Finder, Dock & SystemUIServer to apply visual changes")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search tweaks\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    })
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if filteredCategories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No tweaks match \"\(searchText)\"")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredCategories) { category in
                        categoryCard(category)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if sipEnabled {
                Label("SIP enabled \u{2014} some tweaks locked", systemImage: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else {
                Label("SIP disabled \u{2014} all tweaks available", systemImage: "lock.open.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
            Spacer()

            // Risk legend
            HStack(spacing: 6) {
                riskDot(.green, "Safe")
                riskDot(.yellow, "Moderate")
                riskDot(.red, "Risky")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func riskDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Category Card

    @ViewBuilder
    private func categoryCard(_ category: DebloatCategory) -> some View {
        let isExpanded = expandedCategory == category.id || !searchText.isEmpty
        let disabled = category.requiresSIP && sipEnabled

        VStack(spacing: 0) {
            // Category header row
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedCategory = isExpanded ? nil : category.id
                }
            }, label: {
                HStack(spacing: 8) {
                    Image(systemName: category.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(disabled ? .tertiary : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(disabled ? .tertiary : .primary)
                        Text(category.description)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Applied count badge
                    let applied = appliedCountFor(category)
                    let total = filteredTweaks(in: category).count
                    if applied > 0 {
                        Text("\(applied)/\(total)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }

                    if searchText.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            })
            .buttonStyle(.plain)
            .disabled(disabled && searchText.isEmpty)

            if isExpanded {
                Divider().opacity(0.2).padding(.horizontal, 10)

                // Category action buttons
                if !disabled {
                    categoryActions(category)
                }

                VStack(spacing: 0) {
                    ForEach(filteredTweaks(in: category)) { tweak in
                        tweakRow(tweak, disabled: disabled)
                        if tweak.id != filteredTweaks(in: category).last?.id {
                            Divider().opacity(0.1).padding(.leading, 36)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .opacity(disabled ? 0.5 : 1.0)
    }

    // MARK: - Category Actions

    private func categoryActions(_ category: DebloatCategory) -> some View {
        let applied = appliedCountFor(category)
        let total = category.tweaks.count
        let hasBusy = category.tweaks.contains { manager.busyTweaks.contains($0.id) }

        return HStack(spacing: 6) {
            if applied < total {
                Button {
                    if category.tweaks.contains(where: { $0.risk != .safe }) {
                        pendingCategory = category
                    } else {
                        manager.applyAll(in: category)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle")
                        Text("Apply All")
                    }
                    .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.green)
                .disabled(hasBusy)
            }

            if applied > 0 {
                Button {
                    manager.revertAll(in: category)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Revert All")
                    }
                    .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
                .disabled(hasBusy)
            }

            Spacer()

            if category.tweaks.contains(where: { $0.needsRestart }) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Needs Restart UI")
                }
                .font(.system(size: 8))
                .foregroundStyle(.orange.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Tweak Row

    private func tweakRow(_ tweak: DebloatTweak, disabled: Bool) -> some View {
        let isOn = manager.tweakStates[tweak.id] ?? false
        let isBusy = manager.busyTweaks.contains(tweak.id)

        return HStack(spacing: 8) {
            // Risk indicator dot
            Circle()
                .fill(riskColor(tweak.risk))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tweak.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(disabled ? .tertiary : .primary)

                    if tweak.needsRestart {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 7))
                            .foregroundStyle(.orange.opacity(0.6))
                            .help("Needs Finder/Dock restart to take effect")
                    }
                }

                Text(tweak.description)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { _ in
                        if !isOn, tweak.risk != .safe {
                            pendingTweak = tweak
                        } else {
                            manager.toggle(tweak)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(disabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func riskColor(_ risk: TweakRisk) -> Color {
        switch risk {
        case .safe: return .green
        case .moderate: return .yellow
        case .aggressive: return .red
        }
    }

    // MARK: - Filtering

    private var filteredCategories: [DebloatCategory] {
        if searchText.isEmpty { return manager.categories }
        return manager.categories.filter { cat in
            cat.name.localizedCaseInsensitiveContains(searchText) ||
            cat.tweaks.contains { tweak in
                tweak.name.localizedCaseInsensitiveContains(searchText) ||
                tweak.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func filteredTweaks(in category: DebloatCategory) -> [DebloatTweak] {
        if searchText.isEmpty { return category.tweaks }
        return category.tweaks.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func appliedCountFor(_ category: DebloatCategory) -> Int {
        category.tweaks.filter { manager.tweakStates[$0.id] ?? false }.count
    }
}
