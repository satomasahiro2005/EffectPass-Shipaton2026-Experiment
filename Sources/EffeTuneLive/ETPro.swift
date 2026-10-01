//  ETPro.swift
//  EffectPass Pro（RevenueCat）。本体だけが建てる。単体テストは RevenueCat を引かない。
//
//  **鍵が無ければ何もしない。**Info.plist の RevenueCatAPIKey（Config/Secrets.xcconfig 由来）が
//  空か展開されていないときは Purchases を設定せず、Pro は開いたままにして、設定の Pro 節も隠す。
//  ソースから自分で建てた人は全部使える。
//
//  **Release で test_ の鍵は使わない。**Test Store の鍵で Release を起動すると
//  RevenueCat が fatalError() で落とす。Debug だけで使う。

import Foundation
import RevenueCat
import RevenueCatUI
import SwiftUI

@MainActor
final class ETPro: ObservableObject {
    static let shared = ETPro()
    static let entitlement = "pro"
    static let proCategories: Set<String> = ["lofi", "saturation", "modulation", "spatial", "resonator"]
    private(set) var configured = false
    @Published private(set) var isActive = false

    func configure() {
        let key = ((Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        #if DEBUG
        let usable = !key.isEmpty && !key.hasPrefix("$(")
        Purchases.logLevel = .debug
        #else
        let usable = !key.isEmpty && !key.hasPrefix("$(") && !key.hasPrefix("test_") // Test Store key fatalErrors in Release
        #endif
        guard usable else { isActive = true; return }
        Purchases.configure(withAPIKey: key)
        configured = true
        Task { @MainActor in
            for await info in Purchases.shared.customerInfoStream { self.apply(info) }
        }
    }

    func apply(_ info: CustomerInfo) { isActive = info.entitlements[Self.entitlement]?.isActive == true }

    func restore() async {
        guard configured, let info = try? await Purchases.shared.restorePurchases() else { return }
        apply(info)
    }

    func locks(_ effect: ETEffect) -> Bool { !isActive && Self.proCategories.contains(effect.category) }
}

/// 課金の画面。鍵の掛かった行（EffectPickerView）と設定の Pro 節の両方から出す。
/// **買えた・戻せたら、ここで isActive を直してから閉じる。**customerInfoStream を待つと、
/// 閉じた直後の一覧に鍵が一瞬残る。
struct ETProPaywall: View {
    @Binding var shown: Bool

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { info in
                ETPro.shared.apply(info)
                shown = false
            }
            .onRestoreCompleted { info in
                ETPro.shared.apply(info)
                if ETPro.shared.isActive { shown = false }
            }
    }
}
