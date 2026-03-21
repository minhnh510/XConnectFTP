//
//  TransferProgressModel.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Combine
import Foundation

@MainActor
final class TransferProgressModel: ObservableObject {
    @Published var snapshot: TransferSnapshot?

    func update(_ snapshot: TransferSnapshot?) {
        guard self.snapshot != snapshot else {
            return
        }
        self.snapshot = snapshot
    }

    func clear() {
        snapshot = nil
    }
}
